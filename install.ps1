#Requires -Version 7.3
[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$RemoveLegacyHook,
  [switch]$ConfigureProxy,
  [switch]$RepairPermissions,
  [string]$Proxy = '',
  [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude/settings.json'),
  [string]$JournalPath = (Join-Path $PSScriptRoot 'machine-journal.md'),
  [string]$RollbackBackup = '',
  [string]$ExpectedCurrentHash = ''
)
$ErrorActionPreference = 'Stop'
if (@(Get-Process -Name 'cc-switch' -ErrorAction SilentlyContinue).Count -gt 0) {
  throw 'cc-switch is running and rewrites settings.json; close it before running this installer.'
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
    $profilePrefix = $profileRoot + [IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($profilePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      return '%USERPROFILE%' + $fullPath.Substring($profileRoot.Length)
    }
  }
  $suffix = [regex]::Match([IO.Path]::GetFileName($fullPath), '\.bak-claude-env-[a-f0-9]{32}$', 'IgnoreCase')
  if ($suffix.Success) { return '<SETTINGS-DIR>\<SETTINGS-FILE>' + $suffix.Value }
  return '<SETTINGS-BACKUP>'
}
function Read-Settings([byte[]]$Bytes) {
  try {
    $text = [Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xfeff)
    $value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100
    if ($value -isnot [Collections.IDictionary]) { throw 'root' }
    return $value
  } catch { throw 'Settings must be a valid JSON object; no changes made.' }
}
function Test-LegacyHook($Hook) {
  if ($Hook -isnot [Collections.IDictionary] -or $Hook['type'] -ne 'command') { return $false }
  # Unknown wrappers or arguments are preserved rather than removed by substring.
  $pattern = '^\s*pwsh(?:\.exe)?\s+-NoProfile(?:\s+-ExecutionPolicy\s+Bypass)?\s+-File\s+(?:"(?<quoted>[^"]+)"|(?<bare>\S+))\s*$'
  $m = [regex]::Match([string]$Hook['command'], $pattern, 'IgnoreCase')
  if (-not $m.Success) { return $false }
  $path = if ($m.Groups['quoted'].Success) { $m.Groups['quoted'].Value } else { $m.Groups['bare'].Value }
  # Relative commands belong to the client's working directory, not this installer.
  if (-not [IO.Path]::IsPathFullyQualified($path)) { return $false }
  try {
    return [IO.Path]::GetFullPath($path) -ieq [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'hooks/check-exit-ip.ps1'))
  } catch { return $false }
}

$settings = [IO.Path]::GetFullPath($SettingsPath)
if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) { throw 'Settings file missing; initialize the official client first.' }
if ((Get-Item -LiteralPath $settings).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing a settings symlink.' }
$beforeBytes = [IO.File]::ReadAllBytes($settings)
$beforeHash = Get-Hash $beforeBytes
$json = Read-Settings $beforeBytes
$actions = [Collections.Generic.List[string]]::new()

if ($RollbackBackup) {
  if ($RemoveLegacyHook -or $ConfigureProxy -or $RepairPermissions -or $Proxy) { throw 'Rollback cannot be combined with configuration changes.' }
  if ($ExpectedCurrentHash -notmatch '^[a-fA-F0-9]{64}$' -or $beforeHash -ine $ExpectedCurrentHash) { throw 'Rollback refused: current hash differs or is missing; preserve newer changes.' }
  $backupPath = [IO.Path]::GetFullPath($RollbackBackup)
  if ([IO.Path]::GetDirectoryName($backupPath) -ine [IO.Path]::GetDirectoryName($settings) -or
      -not [IO.Path]::GetFileName($backupPath).StartsWith(([IO.Path]::GetFileName($settings) + '.bak-claude-env-'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Rollback requires a backup created beside this settings file by this installer.'
  }
  if ((Get-Item -LiteralPath $backupPath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing a backup symlink.' }
  $afterBytes = [IO.File]::ReadAllBytes($backupPath)
  $null = Read-Settings $afterBytes
  $actions.Add('restore-unchanged-snapshot')
} else {
  if ($ExpectedCurrentHash) { throw 'ExpectedCurrentHash requires RollbackBackup.' }
  if ($Proxy -and -not $ConfigureProxy) { throw 'Proxy requires ConfigureProxy; configuration is never implicit.' }
  if ($RepairPermissions) {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw '%USERPROFILE% is not set; cannot project permission paths.' }
    $profilePath = [IO.Path]::GetFullPath($env:USERPROFILE).Replace('\', '/')
    $templateText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'settings.official-anthropic.json')).Replace('%USERPROFILE%', $profilePath)
    $template = Read-Settings ([Text.UTF8Encoding]::new($false).GetBytes($templateText))
    $policy = $template['permissions']
    if ($policy -isnot [Collections.IDictionary] -or $policy['defaultMode'] -cne 'default' -or
        $policy['disableAutoMode'] -cne 'disable' -or $policy['disableBypassPermissionsMode'] -cne 'disable') {
      throw 'Permission template does not define the expected approval boundary; no changes made.'
    }
    if (-not $json.Contains('permissions')) { $json['permissions'] = @{} }
    $permissions = $json['permissions']
    if ($permissions -isnot [Collections.IDictionary]) { throw 'permissions must be an object.' }
    foreach ($key in @('defaultMode','disableAutoMode','disableBypassPermissionsMode')) {
      if ($permissions[$key] -cne $policy[$key]) {
        $permissions[$key] = $policy[$key]
        $actions.Add("repair-permissions-$key")
      }
    }
    if ($policy['deny'] -isnot [array] -or ($permissions.Contains('deny') -and $permissions['deny'] -isnot [array])) {
      throw 'Permission deny lists must be arrays; no changes made.'
    }
    $deny = [Collections.Generic.List[string]]::new()
    $existingDeny = @()
    if ($permissions.Contains('deny')) { $existingDeny = @($permissions['deny']) }
    foreach ($rule in @($existingDeny) + @($policy['deny'])) {
      if ($rule -isnot [string] -or [string]::IsNullOrWhiteSpace($rule)) { throw 'Permission deny rules must be nonempty strings; no changes made.' }
      if (-not $deny.Contains($rule)) { $deny.Add($rule) }
    }
    # Existing custom rules and all unrelated settings survive this targeted repair.
    if ((ConvertTo-Json -InputObject $permissions['deny'] -Compress) -cne (ConvertTo-Json -InputObject $deny.ToArray() -Compress)) {
      $permissions['deny'] = $deny.ToArray()
      $actions.Add('repair-permissions-deny-union')
    }
  }
  if ($ConfigureProxy) {
    $uri = $null
    if (-not [uri]::TryCreate($Proxy, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo) { throw 'Supply an HTTP/HTTPS proxy without embedded credentials.' }
    if (-not $json.Contains('env')) { $json['env'] = @{} }
    if ($json['env'] -isnot [Collections.IDictionary]) { throw 'env must be an object.' }
    foreach ($name in @('HTTP_PROXY','HTTPS_PROXY')) {
      $existing = @($json['env'].Keys | Where-Object { [string]$_ -ieq $name })
      if ($existing.Count -gt 1) { throw 'Ambiguous proxy key casing; no changes made.' }
      if ($existing.Count -eq 1) {
        if ([string]$json['env'][$existing[0]] -cne $Proxy) { throw 'Existing proxy differs; no values printed or overwritten.' }
      } else { $json['env'][$name] = $Proxy; $actions.Add("add-$name") }
    }
  }
  if ($RemoveLegacyHook -and $json.Contains('hooks')) {
    if ($json['hooks'] -isnot [Collections.IDictionary]) { throw 'hooks must be an object.' }
    if ($json['hooks'].Contains('SessionStart')) {
      if ($json['hooks']['SessionStart'] -isnot [array]) { throw 'SessionStart must be an array.' }
      $groups = [Collections.Generic.List[object]]::new()
      foreach ($group in $json['hooks']['SessionStart']) {
        if ($group -isnot [Collections.IDictionary] -or $group['hooks'] -isnot [array]) { throw 'Invalid SessionStart group; preserve it for manual review.' }
        $kept = @($group['hooks'] | Where-Object { -not (Test-LegacyHook $_) })
        if ($kept.Count -ne $group['hooks'].Count) {
          $actions.Add('remove-legacy-session-start-action')
          if ($kept.Count -gt 0) { $group['hooks'] = $kept; $groups.Add($group) }
        } else { $groups.Add($group) }
      }
      if ($groups.Count -gt 0) { $json['hooks']['SessionStart'] = $groups.ToArray() }
      else { $json['hooks'].Remove('SessionStart') }
      if ($json['hooks'].Count -eq 0) { $json.Remove('hooks') }
    }
  }
  if ($actions.Count -eq 0) { Write-Output 'NO_CHANGE (no writes, network calls, or journal entry)'; exit 0 }
  $afterBytes = [Text.UTF8Encoding]::new($false).GetBytes(($json | ConvertTo-Json -Depth 100 -EscapeHandling EscapeNonAscii -ErrorAction Stop) + [Environment]::NewLine)
  $null = Read-Settings $afterBytes
}
$afterHash = Get-Hash $afterBytes
if ($afterHash -eq $beforeHash) { Write-Output 'NO_CHANGE'; exit 0 }
if (-not $Apply) {
  if ($RollbackBackup) {
    Write-Output ('PREVIEW actions=' + ($actions -join ',') + '; scope=restore-backup-file; backup-bytes=restored; current-file=replaced; add -Apply to write')
  } else {
    Write-Output ('PREVIEW actions=' + ($actions -join ',') + '; add -Apply to write')
  }
  exit 0
}

$journal = [IO.Path]::GetFullPath($JournalPath)
if ($journal -ieq $settings -or -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($journal)) -PathType Container)) { throw 'Invalid journal destination.' }
if ((Test-Path -LiteralPath $journal) -and ((Get-Item -LiteralPath $journal).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing a journal symlink.' }
$stamp = [guid]::NewGuid().ToString('N')
$backup = "$settings.bak-claude-env-$stamp"
$journalBackup = Get-JournalBackupPath $backup
$stage = "$settings.tmp-claude-env-$stamp"
$published = $false
try {
  [IO.File]::WriteAllBytes($stage, $afterBytes)
  $null = Read-Settings ([IO.File]::ReadAllBytes($stage))
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
