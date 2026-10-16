#Requires -Version 7.3
# Read-only preflight. No login, timezone, fingerprint or credential changes.
param(
  [switch]$CheckExitIp,
  [string]$ExpectedIp = '',
  [string]$Proxy = '',
  [switch]$Restore,
  [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude/settings.json')
)
$ErrorActionPreference = 'Stop'
Write-Output ('TIMEZONE=' + (Get-TimeZone).Id + '; unchanged')
if ($Restore) { Write-Output 'LEGACY_RESTORE_RETIRED: no automatic timezone change or restore.'; exit 0 }
Write-Output 'ELIGIBILITY=not-determined; check actual location and entity eligibility against Supported Regions Policy.'
Write-Output 'https://www.anthropic.com/legal/supported-regions'
$envNames = @('ANTHROPIC_BASE_URL','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','NODE_TLS_REJECT_UNAUTHORIZED')
$envScopes = @('Process','User','Machine')
$scopedEnvironment = @{}
foreach ($scope in $envScopes) {
  try { $scopedEnvironment[$scope] = [Environment]::GetEnvironmentVariables($scope) }
  catch { $scopedEnvironment[$scope] = $null }
}
$settingsEnv = $null
if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
  try {
    $json = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json -AsHashtable -Depth 100
    if ($json -isnot [Collections.IDictionary]) { throw 'root' }
    $settingsEnv = $json['env']
    if ($null -ne $settingsEnv -and $settingsEnv -isnot [Collections.IDictionary]) { throw 'env' }
    Write-Output 'USER_SETTINGS=valid-json-object'
    Write-Output ('API_KEY_HELPER_PRESENT=' + [bool]$json['apiKeyHelper'])
  } catch { [Console]::Error.WriteLine('USER_SETTINGS=invalid; no values printed or changes made.'); exit 1 }
} else { Write-Output 'USER_SETTINGS=absent' }
foreach ($name in $envNames) {
  $inSettings = $settingsEnv -is [Collections.IDictionary] -and @($settingsEnv.Keys | Where-Object { [string]$_ -ieq $name }).Count -gt 0
  $states = foreach ($scope in $envScopes) {
    $map = $scopedEnvironment[$scope]
    if ($null -eq $map) { "$($scope.ToLowerInvariant())_present=unavailable" }
    else {
      $present = @($map.Keys | Where-Object { [string]$_ -ieq $name }).Count -gt 0
      "$($scope.ToLowerInvariant())_present=$present"
    }
  }
  Write-Output ("$name settings_present=$inSettings " + ($states -join ' '))
}
Write-Output 'Browser, Desktop, CLI, refresh and inference routes need separate evidence. No login or model request performed.'
if ($CheckExitIp) {
  & (Join-Path $PSScriptRoot 'hooks/check-exit-ip.ps1') -CheckExitIp -ExpectedIp $ExpectedIp -Proxy $Proxy
  exit $LASTEXITCODE
}
Write-Output 'NETWORK_CHECK=not-requested'
