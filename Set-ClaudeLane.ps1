#Requires -Version 7.3
[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$ToOfficial,
  [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude/settings.json'),
  [string]$VariantPath = (Join-Path $PSScriptRoot 'settings.official-anthropic.json'),
  [string]$JournalPath = (Join-Path $PSScriptRoot 'machine-journal.md'),
  [string]$RollbackBackup = '',
  [string]$ExpectedCurrentHash = ''
)
$ErrorActionPreference = 'Stop'
$legacyOfficialTemplateHash = '7670e3ce0a27aea327f17d4ccf3f0293ba578d75ed783eb3dfd2d93bbaa355af'

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
function Test-LegacyOfficialTemplate([byte[]]$Bytes) {
  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $false }
  try {
    $text = [Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xfeff)
    $profilePath = [IO.Path]::GetFullPath($env:USERPROFILE).Replace('\', '/')
    $normalized = $text.Replace($profilePath, '%USERPROFILE%').Replace("`r`n", "`n").Replace("`r", "`n")
    $normalizedBytes = [Text.UTF8Encoding]::new($false).GetBytes($normalized)
    return (Get-Hash $normalizedBytes) -eq $legacyOfficialTemplateHash
  } catch { return $false }
}
function Assert-EntryTarget([string]$Path, [string]$What) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$What file missing." }
  if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing a $What symlink." }
}

# Default invocation is a read-only status report.
if (-not $ToOfficial -and -not $RollbackBackup) {
  $lane = 'missing'
  $settingsBytes = $null
  if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
    $settingsBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SettingsPath).Path)
    $settingsJson = Read-Json $settingsBytes
    $lane = if (Test-RelayLane $settingsJson) { 'relay' } else { 'custom' }
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
  } | ConvertTo-Json -Compress
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
  if (Get-Process -Name 'cc-switch' -ErrorAction SilentlyContinue) { throw 'cc-switch is running and rewrites settings.json; close it before switching lanes.' }
  Assert-EntryTarget $settings 'Settings'
  Assert-EntryTarget ([IO.Path]::GetFullPath($VariantPath)) 'Variant'
  $beforeBytes = [IO.File]::ReadAllBytes($settings)
  $beforeHash = Get-Hash $beforeBytes
  $beforeJson = Read-Json $beforeBytes
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
$afterHash = Get-Hash $afterBytes
if ($afterHash -eq $beforeHash) { Write-Output 'NO_CHANGE'; exit 0 }
if (-not $Apply) { Write-Output ('PREVIEW actions=' + ($actions -join ',') + '; add -Apply to write'); exit 0 }

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
