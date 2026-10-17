#Requires -Version 7.3
[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$ToOfficial,
  [switch]$ToRelay,
  [switch]$OfficialPreflight,
  [switch]$LaunchOfficial,
  [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude/settings.json'),
  [string]$VariantPath = (Join-Path $PSScriptRoot 'settings.official-anthropic.json'),
  [string]$JournalPath = (Join-Path $PSScriptRoot 'machine-journal.md'),
  [string]$RelayVariant = '',
  [string]$RollbackBackup = '',
  [string]$ExpectedCurrentHash = ''
)
$ErrorActionPreference = 'Stop'
if (@(@($ToOfficial,$ToRelay,$OfficialPreflight,$LaunchOfficial,[bool]$RollbackBackup) | Where-Object { $_ }).Count -gt 1) {
  throw 'Choose one action: ToOfficial, ToRelay, OfficialPreflight, LaunchOfficial, or RollbackBackup.'
}
if (($OfficialPreflight -or $LaunchOfficial) -and ($Apply -or $ExpectedCurrentHash -or $RelayVariant)) {
  throw 'Official process actions cannot be combined with file-write or rollback options.'
}
if (-not [string]::IsNullOrWhiteSpace($RelayVariant) -and -not $ToRelay) { throw 'RelayVariant requires ToRelay.' }
$legacyOfficialTemplateHashes = @(
  '7670e3ce0a27aea327f17d4ccf3f0293ba578d75ed783eb3dfd2d93bbaa355af',
  'd1d81170b3b5b0edd1769084dd3cc75dba01145736eb25e2b344a04a75591b8f'
)

function Test-OfficialOverride([string]$Name) {
  # Beyond the ANTHROPIC_ prefix, these documented model/request overrides must
  # not leak from a relay environment into an official-lane child process.
  return $Name -imatch '^ANTHROPIC_|^CLAUDE_CODE_OAUTH_|^(CLAUDE_CONFIG_DIR|CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_VERTEX|CLAUDE_CODE_USE_FOUNDRY|CLAUDE_CODE_USE_ANTHROPIC_AWS|CLAUDE_CODE_USE_MANTLE|CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST|CLAUDE_CODE_SUBAGENT_MODEL|CLAUDE_CODE_ATTRIBUTION_HEADER|CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK|CLAUDE_CODE_MAX_OUTPUT_TOKENS|CLAUDE_CODE_EFFORT_LEVEL|CLAUDE_CODE_EXTRA_BODY|MAX_THINKING_TOKENS|MAX_MCP_OUTPUT_TOKENS|DISABLE_(LOGIN|LOGOUT|UPGRADE|EXTRA_USAGE)_COMMAND|NODE_TLS_REJECT_UNAUTHORIZED)$'
}

function Get-Hash([byte[]]$Bytes) {
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Get-HostTag {
  # Journal entries travel with the repo, so they must never carry the real
  # hostname. A stable pseudonym keeps one machine distinguishable across appends.
  $name = [Environment]::MachineName
  if ([string]::IsNullOrWhiteSpace($name)) { $name = 'unknown' }
  $digest = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($name.Trim().ToLowerInvariant()))
  return '<HOST-' + [Convert]::ToHexString($digest[0..3]).ToLowerInvariant() + '>'
}
function Get-JournalBackupPath([string]$Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd([char[]]@('\','/'))
    $standardBackup = Join-Path $profileRoot '.claude/settings.json.bak-claude-lane-'
    if ($fullPath.StartsWith($standardBackup, [StringComparison]::OrdinalIgnoreCase) -and
        $fullPath.Substring($standardBackup.Length) -match '^[a-f0-9]{32}$') {
      return '%USERPROFILE%' + $fullPath.Substring($profileRoot.Length)
    }
  }
  $suffix = [regex]::Match([IO.Path]::GetFileName($fullPath), '\.bak-claude-lane-[a-f0-9]{32}$', 'IgnoreCase')
  if ($suffix.Success) { return '<SETTINGS-DIR>\<SETTINGS-FILE>' + $suffix.Value }
  return '<SETTINGS-BACKUP>'
}
function Read-Json([byte[]]$Bytes) {
  try {
    $text = [Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xfeff)
    $value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100
    if ($value -isnot [Collections.IDictionary]) { throw 'root' }
    return $value
  } catch { throw 'Input must be a valid JSON object; no changes made.' }
}
function Get-ProjectedVariantBytes([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw '%USERPROFILE% is not set; cannot project the official variant.' }
  $profilePath = [IO.Path]::GetFullPath($env:USERPROFILE).Replace('\', '/')
  $variantText = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path)).Replace('%USERPROFILE%', $profilePath)
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($variantText)
  $null = Read-Json $bytes
  return ,$bytes
}
function Test-RelayLane($Json) {
  $envKeys = @($Json.Keys | Where-Object { [string]$_ -ieq 'env' })
  if ($envKeys.Count -ne 1 -or $Json[$envKeys[0]] -isnot [Collections.IDictionary]) { return $false }
  return (@($Json[$envKeys[0]].Keys | Where-Object { [string]$_ -ieq 'ANTHROPIC_BASE_URL' })).Count -gt 0
}
function Test-KeyPresent($Json, [string]$Name) {
  return (@($Json.Keys | Where-Object { [string]$_ -ieq $Name }).Count) -gt 0
}
function Test-LegacyOfficialTemplate([byte[]]$Bytes) {
  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $false }
  try {
    $text = [Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xfeff)
    $profilePath = [IO.Path]::GetFullPath($env:USERPROFILE).Replace('\', '/')
    $normalized = $text.Replace($profilePath, '%USERPROFILE%').Replace("`r`n", "`n").Replace("`r", "`n")
    $normalizedBytes = [Text.UTF8Encoding]::new($false).GetBytes($normalized)
    return (Get-Hash $normalizedBytes) -in $legacyOfficialTemplateHashes
  } catch { return $false }
}
function Assert-EntryTarget([string]$Path, [string]$What) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$What file missing." }
  if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing a $What symlink." }
}
function Get-PhysicalPath([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path)
  $current = [IO.Path]::GetPathRoot($full)
  foreach ($part in $full.Substring($current.Length).Split([char[]]@('\','/'), [StringSplitOptions]::RemoveEmptyEntries)) {
    $item = Get-Item -LiteralPath (Join-Path $current $part) -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      $item = $item.ResolveLinkTarget($true)
      if ($null -eq $item) { throw 'Cannot resolve relay source location; no replacement.' }
    }
    $current = $item.FullName
  }
  return $current
}
function Assert-ExternalRelaySource([string]$Path) {
  $repo = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([char[]]@('\','/'))
  $source = [IO.Path]::GetFullPath($Path)
  $physicalRepo = (Get-PhysicalPath $repo).TrimEnd([char[]]@('\','/'))
  $physicalSource = Get-PhysicalPath $source
  if ($source.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
      $physicalSource.StartsWith($physicalRepo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Relay source must be outside this repository, including directory-link targets; no replacement.'
  }
}
function Assert-RelayCredential($Json) {
  $map = $Json['env']
  $urlKeys = @($map.Keys | Where-Object { [string]$_ -ieq 'ANTHROPIC_BASE_URL' })
  $uri = $null
  if ($urlKeys.Count -ne 1 -or $map[$urlKeys[0]] -isnot [string] -or
      [string]::IsNullOrWhiteSpace($map[$urlKeys[0]]) -or
      -not [uri]::TryCreate($map[$urlKeys[0]], [UriKind]::Absolute, [ref]$uri) -or
      $uri.Scheme -notin @('http','https') -or -not $uri.Host -or $uri.UserInfo -or $uri.Fragment) {
    throw 'Relay endpoint must be an absolute HTTP/HTTPS URL without embedded credentials or fragments; no replacement.'
  }
  $hostIp = $null
  $loopback = $uri.Host -ieq 'localhost' -or
    ([Net.IPAddress]::TryParse($uri.Host.Trim([char[]]@('[',']')), [ref]$hostIp) -and [Net.IPAddress]::IsLoopback($hostIp))
  if ($uri.Scheme -eq 'http' -and -not $loopback) { throw 'Remote relay endpoints require HTTPS; HTTP is allowed only for literal loopback addresses or localhost.' }
  $conflicts = @($map.Keys | Where-Object {
    [string]$_ -imatch '^CLAUDE_CODE_OAUTH_|^(CLAUDE_CONFIG_DIR|CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST|CLAUDE_CODE_USE_(BEDROCK|VERTEX|FOUNDRY|ANTHROPIC_AWS|MANTLE))$'
  })
  if ($conflicts.Count) { throw 'Relay source contains conflicting authentication or provider overrides; no replacement.' }
  $tokenKeys = @($map.Keys | Where-Object { [string]$_ -ieq 'ANTHROPIC_AUTH_TOKEN' })
  # Bearer auth takes precedence immediately. API-key-only configurations need an
  # interactive approval and cannot provide this switcher's no-OAuth-fallback boundary.
  if ($tokenKeys.Count -ne 1 -or $map[$tokenKeys[0]] -isnot [string] -or
      [string]::IsNullOrWhiteSpace($map[$tokenKeys[0]])) {
    throw 'Relay source requires an explicit independent ANTHROPIC_AUTH_TOKEN; API-key-only and subscription fallback are not supported.'
  }
  if (@($map.Keys | Where-Object { [string]$_ -imatch '^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)$' }).Count -or
      $map[$tokenKeys[0]].Trim() -like 'sk-ant-oat*') {
    throw 'Relay source must not mix API-key or subscription OAuth credentials with gateway bearer auth.'
  }
}

if ($OfficialPreflight -or $LaunchOfficial) {
  if (Get-Process -Name 'cc-switch' -ErrorAction SilentlyContinue) { throw 'cc-switch is running; close it before preparing an official process.' }
  Assert-EntryTarget ([IO.Path]::GetFullPath($SettingsPath)) 'Settings'
  Assert-EntryTarget ([IO.Path]::GetFullPath($VariantPath)) 'Variant'
  $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($SettingsPath))
  $projected = Get-ProjectedVariantBytes $VariantPath
  if ((Get-Hash $bytes) -ne (Get-Hash $projected)) { throw 'Settings must match the official variant; preview ToOfficial first.' }
  $officialJson = Read-Json $bytes
  if ($null -ne $officialJson['env'] -and $officialJson['env'] -isnot [Collections.IDictionary]) {
    throw 'Official variant env must be a JSON object; no process started.'
  }
  if ($officialJson['apiKeyHelper'] -or @($officialJson['env'].Keys | Where-Object { Test-OfficialOverride ([string]$_) }).Count) {
    throw 'Official variant contains a credential helper or routing override; no process started.'
  }
  $info = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
  $info.UseShellExecute = $false
  $info.WorkingDirectory = $env:USERPROFILE
  $removed = @($info.Environment.Keys | Where-Object { Test-OfficialOverride ([string]$_) })
  foreach ($name in $removed) { $null = $info.Environment.Remove($name) }
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.ArgumentList.Add('-NoProfile')
  if ($LaunchOfficial) {
    if ([IO.Path]::GetFullPath($SettingsPath) -ine [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claude/settings.json'))) {
      throw 'LaunchOfficial uses the default user settings path only.'
    }
    # A bounded bootstrap opens a separate interactive console; returning a child
    # on the caller's console would let two shells compete for the same input.
    $interactiveCode = 'Write-Host "Check actual region eligibility before signing in. Proxy route remains unverified."; claude --setting-sources user'
    $encodedInteractive = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($interactiveCode))
    $bootstrap = 'Start-Process -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -ArgumentList @(''-NoProfile'',''-NoExit'',''-EncodedCommand'',''' + $encodedInteractive + ''') -WorkingDirectory $env:USERPROFILE -WindowStyle Normal -ErrorAction Stop | Out-Null'
    $info.ArgumentList.Add('-EncodedCommand')
    $info.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap)))
  } else {
    foreach ($arg in @('-File',(Join-Path $PSScriptRoot 'prep-registration.ps1'),'-SettingsPath',[IO.Path]::GetFullPath($SettingsPath))) { $info.ArgumentList.Add($arg) }
  }
  $proc = [Diagnostics.Process]::new()
  $proc.StartInfo = $info
  try {
    $null = $proc.Start()
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(15000)) { $proc.Kill($true); throw 'Official preflight timed out.' }
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),3000)) { throw 'Official preflight output timed out.' }
    Write-Output ('OFFICIAL_CHILD_REMOVED_NAMES=' + ($removed -join ','))
    if ($stdout.Result) { Write-Output $stdout.Result.TrimEnd() }
    if ($stderr.Result) { [Console]::Error.WriteLine($stderr.Result.TrimEnd()) }
    if ($LaunchOfficial -and $proc.ExitCode -eq 0) { Write-Output 'OFFICIAL_PROCESS=started; user settings only; eligibility, managed settings and actual route remain unverified.' }
    exit $proc.ExitCode
  } finally { $proc.Dispose() }
}

# Default invocation is a read-only status report.
if (-not $ToOfficial -and -not $ToRelay -and -not $RollbackBackup) {
  $lane = 'missing'
  $settingsBytes = $null
  if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
    $settingsBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SettingsPath).Path)
    try {
      $settingsJson = Read-Json $settingsBytes
      $lane = if (Test-RelayLane $settingsJson) { 'relay' } else { 'custom' }
    } catch {
      # Status classifies every on-disk state; write paths stay fail-closed via Read-Json.
      $lane = 'invalid'
    }
  }
  $variantReady = $false
  if (Test-Path -LiteralPath $VariantPath -PathType Leaf) {
    try {
      $null = Read-Json ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $VariantPath).Path))
      $variantReady = $true
      if ($null -ne $settingsBytes -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $projectedBytes = Get-ProjectedVariantBytes $VariantPath
        if ((Get-Hash $settingsBytes) -eq (Get-Hash $projectedBytes)) { $lane = 'official' }
      }
    } catch { $variantReady = $false }
  }
  [pscustomobject]@{
    current_lane      = $lane
    variant_ready     = $variantReady
    cc_switch_running = [bool](Get-Process -Name 'cc-switch' -ErrorAction SilentlyContinue)
    process_overrides_present = @([Environment]::GetEnvironmentVariables('Process').Keys | Where-Object { Test-OfficialOverride ([string]$_) } | Sort-Object)
    route_verified = $false
  } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
  exit 0
}

$settings = [IO.Path]::GetFullPath($SettingsPath)
if ($RollbackBackup) {
  if ($ToOfficial) { throw 'Rollback cannot be combined with ToOfficial.' }
  if (Get-Process -Name 'cc-switch' -ErrorAction SilentlyContinue) { throw 'cc-switch is running and rewrites settings.json; close it before switching lanes.' }
  Assert-EntryTarget $settings 'Settings'
  $beforeBytes = [IO.File]::ReadAllBytes($settings)
  $beforeHash = Get-Hash $beforeBytes
  if ($ExpectedCurrentHash -notmatch '^[a-fA-F0-9]{64}$' -or $beforeHash -ine $ExpectedCurrentHash) { throw 'Rollback refused: current hash differs or is missing; preserve newer changes.' }
  $backupPath = [IO.Path]::GetFullPath($RollbackBackup)
  if ([IO.Path]::GetDirectoryName($backupPath) -ine [IO.Path]::GetDirectoryName($settings) -or
      -not [IO.Path]::GetFileName($backupPath).StartsWith(([IO.Path]::GetFileName($settings) + '.bak-claude-lane-'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Rollback requires a lane backup created beside this settings file by this tool.'
  }
  Assert-EntryTarget $backupPath 'Backup'
  $afterBytes = [IO.File]::ReadAllBytes($backupPath)
  $null = Read-Json $afterBytes
  $actions = @('restore-lane-backup')
} else {
  if ($ExpectedCurrentHash) { throw 'ExpectedCurrentHash requires RollbackBackup.' }
  if ($ToRelay -and [string]::IsNullOrWhiteSpace($RelayVariant)) {
    throw 'ToRelay requires -RelayVariant, the caller-supplied relay settings file kept outside this repository.'
  }
  if (Get-Process -Name 'cc-switch' -ErrorAction SilentlyContinue) { throw 'cc-switch is running and rewrites settings.json; close it before switching lanes.' }
  Assert-EntryTarget $settings 'Settings'
  Assert-EntryTarget ([IO.Path]::GetFullPath($VariantPath)) 'Variant'
  $beforeBytes = [IO.File]::ReadAllBytes($settings)
  $beforeHash = Get-Hash $beforeBytes
  $beforeJson = Read-Json $beforeBytes
  if ($ToRelay) {
    # The relay source lives outside the repository: this tool never stores a
    # gateway credential, and it never prints or journals a value from the file.
    Assert-EntryTarget ([IO.Path]::GetFullPath($RelayVariant)) 'Relay variant'
    Assert-ExternalRelaySource $RelayVariant
    # Projection keeps the caller's file portable and validates it as JSON.
    $afterBytes = Get-ProjectedVariantBytes $RelayVariant
    $afterHash = Get-Hash $afterBytes
    $relayJson = Read-Json $afterBytes
    if (-not (Test-RelayLane $relayJson)) { throw 'Relay variant must declare env.ANTHROPIC_BASE_URL; no replacement.' }
    Assert-RelayCredential $relayJson
    if ($relayJson['apiKeyHelper']) { throw 'Relay variant contains a credential helper; no replacement.' }
    if (Test-KeyPresent $relayJson 'hooks') { throw 'Relay variant declares hooks; this repository does not register automatic hooks.' }
    if ($afterHash -eq $beforeHash) { Write-Output 'NO_CHANGE (settings already match the relay variant)'; exit 0 }
    $officialBytes = Get-ProjectedVariantBytes $VariantPath
    # Symmetric with ToOfficial: whole-file replacement only from the official
    # lane, or from an already identified relay form when re-pointing it.
    if ((Get-Hash $officialBytes) -ne $beforeHash -and -not (Test-RelayLane $beforeJson)) {
      throw 'Current settings are neither the official variant nor the relay form; refresh to the official lane first, then switch.'
    }
    $actions = @('switch-lane-to-relay')
  } else {
    # The in-repo variant stays portable: it carries %USERPROFILE% instead of a real
    # user path, so it is correct on any machine and the repo never stores a username.
    $afterBytes = Get-ProjectedVariantBytes $VariantPath
    $afterHash = Get-Hash $afterBytes
    if ($afterHash -eq $beforeHash) { Write-Output 'NO_CHANGE (settings already match the official variant)'; exit 0 }
    # Whole-file replacement is only offered from an identified relay form or the
    # exact previous repository template; other settings require manual review.
    if (Test-RelayLane $beforeJson) {
      $actions = @('switch-lane-to-official')
    } elseif (Test-LegacyOfficialTemplate $beforeBytes) {
      $actions = @('refresh-known-official-template')
    } else {
      throw 'Current settings are neither the relay form nor the exact previous repository template; no whole-file replacement.'
    }
  }
}
$afterHash = Get-Hash $afterBytes
if ($afterHash -eq $beforeHash) { Write-Output 'NO_CHANGE'; exit 0 }
if (-not $Apply) {
  if ($RollbackBackup) {
    Write-Output ('PREVIEW actions=' + ($actions -join ',') + '; scope=restore-backup-file; backup-bytes=restored; current-file=replaced; add -Apply to write')
  } else {
    Write-Output ('PREVIEW actions=' + ($actions -join ',') + '; full-file-replacement=true; extra-settings=not-preserved; add -Apply to write')
  }
  exit 0
}

$journal = [IO.Path]::GetFullPath($JournalPath)
if ($journal -ieq $settings -or -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($journal)) -PathType Container)) { throw 'Invalid journal destination.' }
if ((Test-Path -LiteralPath $journal) -and ((Get-Item -LiteralPath $journal).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing a journal symlink.' }
$stamp = [guid]::NewGuid().ToString('N')
$backup = "$settings.bak-claude-lane-$stamp"
$journalBackup = Get-JournalBackupPath $backup
$stage = "$settings.tmp-claude-lane-$stamp"
$published = $false
try {
  [IO.File]::WriteAllBytes($stage, $afterBytes)
  $null = Read-Json ([IO.File]::ReadAllBytes($stage))
  if ((Get-Hash ([IO.File]::ReadAllBytes($settings))) -ne $beforeHash) { throw 'Settings changed during planning; no replacement performed.' }
  $entry = @('', "## $(Get-Date -Format o) | $(Get-HostTag)", '- phase: prepared',
    "- actions: $($actions -join ',')", "- backup: $journalBackup",
    "- before_sha256: $beforeHash", "- after_sha256: $afterHash") -join [Environment]::NewLine
  Add-Content -LiteralPath $journal -Encoding utf8 -Value $entry
  # Atomic publication creates a backup of the actual replaced file.
  [IO.File]::Replace($stage, $settings, $backup)
  $published = $true
  if ((Get-Hash ([IO.File]::ReadAllBytes($backup))) -ne $beforeHash) { throw 'Concurrent replacement detected; preserve backup and inspect journal.' }
  if ((Get-Hash ([IO.File]::ReadAllBytes($settings))) -ne $afterHash) { throw 'Readback differs; preserve backup and newer settings.' }
  Add-Content -LiteralPath $journal -Encoding utf8 -Value '- phase: applied-readback-verified'
  Write-Output "APPLIED backup=$backup after_sha256=$afterHash"
} catch {
  if ($published) { [Console]::Error.WriteLine('Replacement occurred; backup and journal are retained. Do not overwrite newer settings.') }
  throw
} finally {
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage }
}
