#Requires -Version 7.3
# Manual diagnostic only. SessionStart does not provide request blocking.
param([switch]$CheckExitIp, [string]$ExpectedIp = '', [string]$Proxy = '')
$ErrorActionPreference = 'Stop'
if (-not $CheckExitIp) {
  Write-Output 'NOT_CHECKED: automatic hook retired; no network request. Use -CheckExitIp explicitly.'
  exit 0
}
$proxyUri = $null
if (-not [uri]::TryCreate($Proxy, [UriKind]::Absolute, [ref]$proxyUri) -or $proxyUri.Scheme -notin @('http','https') -or -not $proxyUri.Host -or $proxyUri.UserInfo -or $proxyUri.Query -or $proxyUri.Fragment) {
  [Console]::Error.WriteLine('Supply an explicit HTTP/HTTPS proxy without embedded credentials, query parameters or fragments.')
  exit 3
}
$expected = $null
if ($ExpectedIp -and -not [Net.IPAddress]::TryParse($ExpectedIp, [ref]$expected)) { [Console]::Error.WriteLine('Invalid expected IP.'); exit 3 }
try {
  $response = Invoke-WebRequest -Uri 'https://api.ipify.org' -Proxy $Proxy -TimeoutSec 8 -MaximumRedirection 0
  $observed = $null
  if (-not [Net.IPAddress]::TryParse($response.Content.Trim(), [ref]$observed)) { throw 'Invalid IP response' }
  if ($ExpectedIp -and -not $observed.Equals($expected)) {
    [Console]::Error.WriteLine('MISMATCH: diagnostic proxy egress differs; actual client route and eligibility remain unverified.')
    exit 2
  }
  Write-Output "OBSERVED_IP=$observed; diagnostic proxy only; not account acceptance"
  exit 0
} catch {
  [Console]::Error.WriteLine('UNVERIFIED: IP lookup failed; no inference about Claude connectivity or account safety.')
  exit 3
}
