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
if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
  try {
    $json = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json -AsHashtable -Depth 100
    if ($json -isnot [Collections.IDictionary]) { throw 'root' }
    $envMap = $json['env']
    if ($null -ne $envMap -and $envMap -isnot [Collections.IDictionary]) { throw 'env' }
    Write-Output 'USER_SETTINGS=valid-json-object'
    foreach ($name in @('ANTHROPIC_BASE_URL','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','HTTP_PROXY','HTTPS_PROXY','NO_PROXY','NODE_TLS_REJECT_UNAUTHORIZED')) {
      $inSettings = $envMap -is [Collections.IDictionary] -and @($envMap.Keys | Where-Object { [string]$_ -ieq $name }).Count -gt 0
      $inProcess = -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name, 'Process'))
      Write-Output "$name settings_present=$inSettings process_present=$inProcess"
    }
    Write-Output ('API_KEY_HELPER_PRESENT=' + [bool]$json['apiKeyHelper'])
  } catch { [Console]::Error.WriteLine('USER_SETTINGS=invalid; no values printed or changes made.'); exit 1 }
} else { Write-Output 'USER_SETTINGS=absent; other settings scopes and credentials not inspected' }
Write-Output 'Browser, Desktop, CLI, refresh and inference routes need separate evidence. No login or model request performed.'
if ($CheckExitIp) {
  & (Join-Path $PSScriptRoot 'hooks/check-exit-ip.ps1') -CheckExitIp -ExpectedIp $ExpectedIp -Proxy $Proxy
  exit $LASTEXITCODE
}
Write-Output 'NETWORK_CHECK=not-requested'
