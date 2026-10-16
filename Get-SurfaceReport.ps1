#Requires -Version 7.3
# Read-only report of the local surface a third-party checker scores: host locale,
# fonts, browser profile and where the browser proxy comes from. No machine writes;
# no network unless -CheckExitIp is explicit (then it delegates to the manual hook).
param(
  [switch]$CheckExitIp,
  [string]$ExpectedIp = '',
  [string]$Proxy = '',
  [string]$RepoRoot = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'

function Get-FontPresence([string]$Directory, [string[]]$Patterns) {
  if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) { return 'unavailable' }
  $names = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  if ($names.Count -eq 0) { return 'unavailable' }
  foreach ($pattern in $Patterns) {
    if (@($names | Where-Object { $_ -like $pattern }).Count -gt 0) { return 'True' }
  }
  return 'False'
}

$timeZone = Get-TimeZone
Write-Output ('TIMEZONE=' + $timeZone.Id + ' utc_offset=' + $timeZone.BaseUtcOffset)
Write-Output ('OS_LOCALE=' + [Globalization.CultureInfo]::CurrentCulture.Name + ' ui_locale=' + [Globalization.CultureInfo]::CurrentUICulture.Name)
Write-Output ('OS=' + [Environment]::OSVersion.VersionString)
Write-Output ('EAST_ASIAN_FONTS_PRESENT=' + (Get-FontPresence (Join-Path $env:WINDIR 'Fonts') @('msyh*', 'msjh*', 'simsun*', 'simhei*', 'mingliu*')))

# Launcher flags are read from the script that actually starts the browser, so a
# later edit cannot silently add identity or network flags without showing up here.
$launcherPath = Join-Path $RepoRoot 'start-claude-chrome.cmd'
$launcherFlags = @()
if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
  $launcherText = Get-Content -Raw -LiteralPath $launcherPath
  $launcherFlags = @([regex]::Matches($launcherText, '(?<![\w-])--([a-z0-9][a-z0-9-]*)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
  if ($launcherFlags.Count -eq 0) { $launcherFlags = @('none') }
  Write-Output ('LAUNCHER=start-claude-chrome.cmd flags=' + ($launcherFlags -join ','))
} else { Write-Output 'LAUNCHER=absent' }

$preferencesPath = Join-Path $RepoRoot 'chrome-data/Default/Preferences'
if (Test-Path -LiteralPath $preferencesPath -PathType Leaf) {
  try {
    $preferences = Get-Content -Raw -LiteralPath $preferencesPath | ConvertFrom-Json
    Write-Output ('BROWSER_PROFILE=present languages=' + (@($preferences.intl.selected_languages) -join ','))
    Write-Output ('BROWSER_ACCEPT_LANGUAGES=' + (@($preferences.intl.accept_languages) -join ','))
    Write-Output ('BROWSER_APP_LOCALE=' + [string]$preferences.intl.app_locale)
    Write-Output ('WEBRTC_POLICY_OVERRIDE=' + $(if ($null -ne $preferences.webrtc) { 'present' } else { 'none' }))
  } catch { Write-Output 'BROWSER_PROFILE=present preferences=unreadable' }
} else { Write-Output 'BROWSER_PROFILE=absent; run start-claude-chrome.cmd once to create it' }

Write-Output ('BROWSER_PROXY_SOURCE=' + $(if ($launcherFlags -contains 'proxy-server') { 'launcher-flag' } else { 'system-setting (launcher passes no --proxy-server)' }))

# Proxy configuration is reported as a state and a scope, never as a value: the
# tracked documentation must not carry this machine's infrastructure details.
$proxyState = 'unavailable'
$proxyLoopback = 'unavailable'
try {
  $internetSettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  if ($internetSettings.ProxyEnable -eq 1) {
    $proxyState = 'configured'
    $proxyHost = ([string]$internetSettings.ProxyServer -split ';' | Select-Object -First 1) -replace '^.*=', ''
    $proxyHost = ($proxyHost -split ':')[0]
    $proxyLoopback = @('localhost', '::1') -contains $proxyHost.ToLowerInvariant() -or $proxyHost -like '127.*'
  } else { $proxyState = 'direct'; $proxyLoopback = 'n/a' }
} catch { $proxyState = 'unavailable' }
Write-Output ('SYSTEM_PROXY=' + $proxyState + ' loopback=' + $proxyLoopback)

# Presence only, per scope: an existing variable is not proof that a client uses it.
$proxyVariables = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
$scopeStates = foreach ($scope in @('Process', 'User', 'Machine')) {
  $names = @($proxyVariables | Where-Object { $null -ne [Environment]::GetEnvironmentVariable($_, $scope) })
  if ($names.Count -eq 0) { $names = @('none') }
  $scope.ToLowerInvariant() + '=' + ($names -join '/')
}
Write-Output ('PROXY_ENV_PRESENT=' + ($scopeStates -join ' '))

Write-Output 'SURFACE_SOURCE=host, locale, font and proxy facts come from the installed Windows environment and the browser profile; the launcher only isolates browser data.'
Write-Output 'SCORE_NOTE=third-party risk scores are not eligibility, safety or account acceptance.'

if ($CheckExitIp) {
  & (Join-Path $PSScriptRoot 'hooks/check-exit-ip.ps1') -CheckExitIp -ExpectedIp $ExpectedIp -Proxy $Proxy
  exit $LASTEXITCODE
}
Write-Output 'NETWORK_CHECK=not-requested'
