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
function Read-Json([byte[]]$Bytes) {
  try {
    $text = [Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xfeff)
    $value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100
    if ($value -isnot [Collections.IDictionary]) { throw 'root' }
    return $value
  } catch { throw 'Input must be a valid JSON object; no changes made.' }
}
function Test-RelayLane($Json) {
  $envKeys = @($Json.Keys | Where-Object { [string]$_ -ieq 'env' })
  if ($envKeys.Count -ne 1 -or $Json[$envKeys[0]] -isnot [Collections.IDictionary]) { return $false }
  return (@($Json[$envKeys[0]].Keys | Where-Object { [string]$_ -ieq 'ANTHROPIC_BASE_URL' })).Count -gt 0
}
function Assert-EntryTarget([string]$Path, [string]$What) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$What file missing." }
  if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing a $What symlink." }
}

# Default invocation is a read-only status report.
if (-not $ToOfficial -and -not $RollbackBackup) {
  $lane = 'missing'
  if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
    $lane = if (Test-RelayLane (Read-Json ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SettingsPath).Path)))) { 'relay' } else { 'official' }
  }
  $variantReady = $false
  if (Test-Path -LiteralPath $VariantPath -PathType Leaf) {
    try { $null = Read-Json ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $VariantPath).Path)); $variantReady = $true } catch { $variantReady = $false }
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
  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw '%USERPROFILE% is not set; cannot project the official variant.' }
  $profilePath = [IO.Path]::GetFullPath($env:USERPROFILE).Replace('\', '/')
  $variantText = [IO.File]::ReadAllText(([IO.Path]::GetFullPath($VariantPath))).Replace('%USERPROFILE%', $profilePath)
  $afterBytes = [Text.UTF8Encoding]::new($false).GetBytes($variantText)
  $afterHash = Get-Hash $afterBytes
  $null = Read-Json $afterBytes
  if ($afterHash -eq $beforeHash) { Write-Output 'NO_CHANGE (settings already match the official variant)'; exit 0 }
  # Whole-file replacement is only offered between the known relay form and this
  # repo's variant; an unrecognized configuration is left for manual review.
  if (-not (Test-RelayLane $beforeJson)) { throw 'Current settings are not the relay lane form (env.ANTHROPIC_BASE_URL absent) and do not match the variant; no whole-file replacement.' }
  $actions = @('switch-lane-to-official')
}
$afterHash = Get-Hash $afterBytes
if ($afterHash -eq $beforeHash) { Write-Output 'NO_CHANGE'; exit 0 }
if (-not $Apply) { Write-Output ('PREVIEW actions=' + ($actions -join ',') + '; add -Apply to write'); exit 0 }

$journal = [IO.Path]::GetFullPath($JournalPath)
if ($journal -ieq $settings -or -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($journal)) -PathType Container)) { throw 'Invalid journal destination.' }
if ((Test-Path -LiteralPath $journal) -and ((Get-Item -LiteralPath $journal).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing a journal symlink.' }
$stamp = [guid]::NewGuid().ToString('N')
$backup = "$settings.bak-claude-lane-$stamp"
$stage = "$settings.tmp-claude-lane-$stamp"
$published = $false
try {
  [IO.File]::WriteAllBytes($stage, $afterBytes)
  $null = Read-Json ([IO.File]::ReadAllBytes($stage))
  if ((Get-Hash ([IO.File]::ReadAllBytes($settings))) -ne $beforeHash) { throw 'Settings changed during planning; no replacement performed.' }
  $entry = @('', "## $(Get-Date -Format o) | $(Get-HostTag)", '- phase: prepared',
    "- actions: $($actions -join ',')", "- backup: $backup",
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
