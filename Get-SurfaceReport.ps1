#Requires -Version 7.3
# Read-only report of the local surface a third-party checker scores: host locale,
# fonts, browser profile and where the browser proxy comes from. No machine writes;
# Network requires -CheckExitIp or -CheckUdpLeak explicitly.
param(
  [switch]$CheckExitIp,
  [string]$ExpectedIp = '',
  [string]$Proxy = '',
  [switch]$CheckUdpLeak,
  [string]$StunServer = 'stun.l.google.com',
  [int]$StunPort = 19302,
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

function Get-MaskedAddress([string]$Address) {
  if ($Address -match '^(\d{1,3}\.\d{1,3})\.\d{1,3}\.\d{1,3}$') { return ($Matches[1] + '.x.x') }
  return 'unavailable'
}

# A STUN binding request over non-proxied UDP (RFC 5389) shows the public address
# this host would offer on a path that ignores the configured proxy. It measures
# the host precondition, not the browser policy that decides whether WebRTC uses it.
function ConvertFrom-StunResponse([byte[]]$Response, [byte[]]$TransactionId) {
  $invalid = [pscustomobject]@{ Status='invalid-response'; Address='' }
  if ($Response.Length -lt 20 -or $TransactionId.Length -ne 12 -or $Response[0] -ne 1 -or $Response[1] -ne 1) { return $invalid }
  $bodyLength = ([int]$Response[2] -shl 8) -bor $Response[3]
  if ($bodyLength % 4 -ne 0 -or $Response.Length -ne 20 + $bodyLength) { return $invalid }
  $cookie = [byte[]]@(0x21, 0x12, 0xA4, 0x42)
  for ($i = 0; $i -lt 4; $i++) { if ($Response[4 + $i] -ne $cookie[$i]) { return $invalid } }
  for ($i = 0; $i -lt 12; $i++) { if ($Response[8 + $i] -ne $TransactionId[$i]) { return $invalid } }
  $address = ''
  $unsupported = $false
  $offset = 20
  while ($offset -lt $Response.Length) {
    if ($offset + 4 -gt $Response.Length) { return $invalid }
    $type = ([int]$Response[$offset] -shl 8) -bor $Response[$offset + 1]
    $length = ([int]$Response[$offset + 2] -shl 8) -bor $Response[$offset + 3]
    $next = $offset + 4 + $length + ((4 - ($length % 4)) % 4)
    if ($next -gt $Response.Length) { return $invalid }
    if ($type -eq 0x0020) {
      if ($length -lt 4 -or $Response[$offset + 4] -ne 0) { return $invalid }
      $family = $Response[$offset + 5]
      if ($family -eq 1 -and $length -eq 8) {
        $address = (@(0..3 | ForEach-Object { $Response[$offset + 8 + $_] -bxor $cookie[$_] })) -join '.'
      } elseif ($family -eq 2 -and $length -eq 20) {
        $unsupported = $true
      } else { return $invalid }
    }
    $offset = $next
  }
  if ($address) { return [pscustomobject]@{ Status='valid'; Address=$address } }
  return [pscustomobject]@{ Status=$(if ($unsupported) { 'unsupported-address-family' } else { 'no-mapped-address' }); Address='' }
}
function Get-StunMappedAddress([string]$Server, [int]$Port) {
  $cookie = [byte[]]@(0x21, 0x12, 0xA4, 0x42)
  $request = New-Object byte[] 20
  $request[1] = 1
  [Array]::Copy($cookie, 0, $request, 4, 4)
  $transactionId = New-Object byte[] 12
  [Security.Cryptography.RandomNumberGenerator]::Fill($transactionId)
  [Array]::Copy($transactionId, 0, $request, 8, 12)
  $client = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
  $client.Client.ReceiveTimeout = 4000
  try {
    $client.Connect($Server, $Port)
    [void]$client.Send($request, 20)
    $endpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
    $response = $client.Receive([ref]$endpoint)
  } catch { return [pscustomobject]@{ Status='no-response'; Address='' } } finally { $client.Dispose() }
  return ConvertFrom-StunResponse $response $transactionId
}

$timeZone = Get-TimeZone
Write-Output ('TIMEZONE=' + $timeZone.Id + ' utc_offset=' + $timeZone.BaseUtcOffset)
Write-Output ('OS_LOCALE=' + [Globalization.CultureInfo]::CurrentCulture.Name + ' ui_locale=' + [Globalization.CultureInfo]::CurrentUICulture.Name)
Write-Output ('OS=' + [Environment]::OSVersion.VersionString)
Write-Output ('EAST_ASIAN_FONTS_PRESENT=' + (Get-FontPresence (Join-Path $env:WINDIR 'Fonts') @('msyh*', 'msjh*', 'simsun*', 'simhei*', 'mingliu*')))

# Launcher flags are read from the scripts that actually start the browser, so a
# later edit cannot silently add identity or network flags without showing up here.
$launcherFiles = @(Get-ChildItem -LiteralPath $RepoRoot -Filter 'start-claude-chrome*.cmd' -File -ErrorAction SilentlyContinue | Sort-Object Name)
$allLauncherFlags = @()
if ($launcherFiles.Count -eq 0) { Write-Output 'LAUNCHER=absent' }
foreach ($launcherFile in $launcherFiles) {
  $launcherText = Get-Content -Raw -LiteralPath $launcherFile.FullName
  $flags = @([regex]::Matches($launcherText, '(?<![\w-])--([a-z0-9][a-z0-9-]*)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
  $allLauncherFlags += $flags
  Write-Output ('LAUNCHER=' + $launcherFile.Name + ' flags=' + $(if ($flags.Count -eq 0) { 'none' } else { $flags -join ',' }))
}
$sealingLaunchers = @($launcherFiles | Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'force-webrtc-ip-handling-policy=disable_non_proxied_udp' } | ForEach-Object { $_.Name })
# Reading a launcher proves configuration only; it cannot establish the policy
# loaded by an existing browser process or the candidates it actually emits.
Write-Output ('WEBRTC_NON_PROXIED_UDP=' + $(if ($sealingLaunchers.Count -gt 0) { 'configured-by-launcher ' + ($sealingLaunchers -join ',') } else { 'not-configured-by-launcher' }))
Write-Output 'WEBRTC_RUNTIME=not-verified; launcher inspection does not inspect a running browser or Claude Desktop.'

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

Write-Output ('BROWSER_PROXY_SOURCE=' + $(if ($allLauncherFlags -contains 'proxy-server') { 'launcher-flag' } else { 'system-setting (no launcher passes --proxy-server)' }))

# Proxy configuration is reported as a state and a scope, never as a value: the
# tracked documentation must not carry this machine's infrastructure details.
$proxyState = 'unavailable'
$proxyLoopback = 'unavailable'
$pacState = 'unavailable'
$autoDetect = 'unavailable'
try {
  $internetSettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $pacState = -not [string]::IsNullOrWhiteSpace([string]$internetSettings.AutoConfigURL)
  # AutoDetect is not always exposed here; absence does not prove WPAD is off.
  if ($null -ne $internetSettings.AutoDetect) { $autoDetect = [bool]$internetSettings.AutoDetect }
  if ($internetSettings.ProxyEnable -eq 1) {
    $proxyState = 'configured'
    $proxyLoopback = $true
    foreach ($entry in ([string]$internetSettings.ProxyServer -split ';')) {
      $server = $entry.Trim() -replace '^\w+=', ''
      if ($server -notmatch '^\w+://') { $server = 'http://' + $server }
      $uri = $null
      if (-not [uri]::TryCreate($server, [UriKind]::Absolute, [ref]$uri)) { $proxyLoopback = 'unavailable'; break }
      $hostName = $uri.Host.Trim([char[]]@('[',']'))
      $ip = $null
      if ($hostName -ine 'localhost' -and (-not [Net.IPAddress]::TryParse($hostName, [ref]$ip) -or -not [Net.IPAddress]::IsLoopback($ip))) { $proxyLoopback = $false }
    }
  } else { $proxyState = 'disabled'; $proxyLoopback = 'n/a' }
} catch { $proxyState = 'unavailable' }
Write-Output ('SYSTEM_PROXY=' + $proxyState + ' loopback=' + $proxyLoopback)
Write-Output ("SYSTEM_PROXY_AUTOCONFIG=pac_present=$pacState auto_detect=$autoDetect")
Write-Output 'EFFECTIVE_PROXY=unverified; static settings, PAC, browser policy/extensions and TUN need separate runtime evidence.'

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

if ($CheckUdpLeak) {
  if ($StunPort -lt 1 -or $StunPort -gt 65535) { [Console]::Error.WriteLine('Supply a UDP port between 1 and 65535.'); exit 3 }
  $probe = Get-StunMappedAddress -Server $StunServer -Port $StunPort
  if ($probe.Status -eq 'no-response') {
    Write-Output ("UDP_PROBE=$StunServer`:$StunPort reply=none; no non-proxied UDP answer observed")
  } elseif ($probe.Status -ne 'valid') {
    Write-Output ("UDP_PROBE=$StunServer`:$StunPort reply=unverified status=" + $probe.Status + '; no usable mapped address')
  } else {
    Write-Output ("UDP_PROBE=$StunServer`:$StunPort reply=yes mapped=" + (Get-MaskedAddress $probe.Address) + '; host path only, browser policy is reported above')
  }
} else { Write-Output 'UDP_PROBE=not-requested' }

if ($CheckExitIp) {
  & (Join-Path $PSScriptRoot 'hooks/check-exit-ip.ps1') -CheckExitIp -ExpectedIp $ExpectedIp -Proxy $Proxy
  exit $LASTEXITCODE
}
Write-Output 'NETWORK_CHECK=not-requested'
