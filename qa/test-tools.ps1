#Requires -Version 7.3
# Disposable fixtures only: no real settings, browser, login or external requests.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('claude-tools-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$passed = 0
function Assert($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Run([string]$Script, [string[]]$ScriptArgs = @()) {
  $info = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $null = $info.Environment.Remove('COMPUTERNAME')
  foreach ($arg in (@('-NoProfile','-File',$Script) + $ScriptArgs)) { $info.ArgumentList.Add($arg) }
  $proc = [Diagnostics.Process]::new()
  $proc.StartInfo = $info
  try {
    $null = $proc.Start()
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(20000)) { $proc.Kill($true); throw 'Fixture process timeout' }
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr), 3000)) { throw 'Fixture output timeout' }
    return @{ Code=$proc.ExitCode; Text=$stdout.Result + $stderr.Result }
  } finally { $proc.Dispose() }
}
function Case([string]$Name, [scriptblock]$Body) {
  & $Body
  $script:passed++
  Write-Output "PASS $Name"
}
function Write-Settings([string]$Text) { [IO.File]::WriteAllText($settings, $Text, [Text.UTF8Encoding]::new($false)) }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Install([string[]]$Options) {
  Run (Join-Path $repo 'install.ps1') (@('-SettingsPath',$settings,'-JournalPath',$journal) + $Options)
}
function Lane([string[]]$Options) {
  Run (Join-Path $repo 'Set-ClaudeLane.ps1') (@('-SettingsPath',$settings,'-VariantPath',$variant,'-JournalPath',$journal) + $Options)
}
$settings = Join-Path $root '配置 with spaces.json'
$journal = Join-Path $root 'journal.md'
$variant = Join-Path $root 'official-variant.json'
$variantText = '{"env":{"HTTP_PROXY":"http://127.0.0.1:10808"},"permissions":{"allow":["Read"]}}'
$relayText = '{"env":{"ANTHROPIC_BASE_URL":"https://relay-fixture.invalid/anthropic","ANTHROPIC_AUTH_TOKEN":"secret-fixture"},"model":"relay-model"}'
$hookPath = Join-Path $repo 'hooks/check-exit-ip.ps1'
$legacy = @{ type='command'; command="pwsh -NoProfile -ExecutionPolicy Bypass -File `"$hookPath`"" }
$other = @{ type='command'; command='other-tool --keep' }
$unknown = @{ type='command'; command="pwsh -NoProfile -File `"$hookPath`" -unexpected" }
$fixture = @{
  env=@{ http_proxy='http://127.0.0.1:10808'; HTTPS_PROXY='http://127.0.0.1:10808'; KEEP='private-value-fixture' }
  permissions=@{ allow=@('Read'); deny=@() }
  label='保留'; hooks=@{
    SessionStart=@(@{matcher='startup'; hooks=@($legacy,$other)}, @{hooks=@($unknown)}, @{hooks=@($legacy)})
    Stop=@(@{hooks=@($other)})
  }
} | ConvertTo-Json -Depth 20 -EscapeHandling EscapeNonAscii
$mock = Join-Path $root 'mock.ps1'
[IO.File]::WriteAllText($mock, @'
param([string]$Script,[string]$Mode,[string]$SettingsPath)
$ErrorActionPreference='Stop'
function global:Set-TimeZone { throw 'Unexpected timezone mutation' }
function global:Invoke-WebRequest {
  param($Uri,$Proxy,$TimeoutSec,$MaximumRedirection)
  if($Mode -in @('default','restore')) { throw 'Unexpected network request' }
  if($Mode -eq 'unreachable') { throw 'Fixture unreachable' }
  if($Uri -ne 'https://api.ipify.org' -or $TimeoutSec -ne 8 -or $MaximumRedirection -ne 0) { throw 'Unexpected diagnostic request' }
  if($Mode -eq 'invalid') { return @{Content='not-an-ip'} }
  return @{Content='203.0.113.9'}
}
if($Mode -eq 'default') { & $Script -SettingsPath $SettingsPath }
elseif($Mode -eq 'restore') { & $Script -Restore -SettingsPath $SettingsPath }
elseif($Mode -eq 'retired') { & $Script }
else { & $Script -CheckExitIp -ExpectedIp $(if($Mode -eq 'mismatch'){'203.0.113.10'}else{'203.0.113.9'}) -Proxy 'http://127.0.0.1:1' }
exit $LASTEXITCODE
'@)
try {
  Case 'preview leaves bytes and journal untouched' {
    Write-Settings $fixture
    $before = Hash $settings
    $r = Install @('-RemoveLegacyHook')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('PREVIEW')) $r.Text
    Assert ((Hash $settings) -eq $before -and -not (Test-Path $journal)) 'Preview wrote data'
    Assert (@(Get-ChildItem $root -Filter '*.bak-*').Count -eq 0) 'Preview created backup'
  }
  Case 'precise mixed hook removal, raw backup and idempotence' {
    $script:originalHash = Hash $settings
    $r = Install @('-RemoveLegacyHook','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    $script:backup = @(Get-ChildItem $root -Filter '*.bak-*')[0].FullName
    Assert ((Hash $backup) -eq $originalHash) 'Backup differs from raw original'
    Assert ((Get-Content -Raw -LiteralPath $journal) -notmatch '(?m)^## .*\|\s*$') 'Missing machine name when environment variable is absent'
    Assert ((Get-Content -Raw -LiteralPath $journal) -match '(?m)^## .*\| <HOST-[0-9a-f]{8}>\s*$') 'Journal header must carry a host pseudonym, not a raw hostname'
    $actual = Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json -AsHashtable
    $expected = $fixture | ConvertFrom-Json -AsHashtable
    $expected.hooks.SessionStart = @(@{matcher='startup';hooks=@($other)}, @{hooks=@($unknown)})
    # Compare the preserved subtrees independently of hashtable ordering.
    Assert ($actual.hooks.SessionStart.Count -eq 2) 'Wrong group count'
    Assert ($actual.hooks.SessionStart[0].hooks.Count -eq 1 -and $actual.hooks.SessionStart[0].hooks[0].command -eq $other.command) 'Other action lost'
    Assert ($actual.hooks.SessionStart[1].hooks[0].command -eq $unknown.command) 'Unknown wrapper lost'
    Assert (($actual.hooks.Stop | ConvertTo-Json -Depth 20 -Compress) -eq ($expected.hooks.Stop | ConvertTo-Json -Depth 20 -Compress)) 'Other event changed'
    $actual.Remove('hooks'); $expected.Remove('hooks')
    Assert (($actual | ConvertTo-Json -Depth 30 -Compress) -eq ($expected | ConvertTo-Json -Depth 30 -Compress)) 'Unrelated settings differ'
    $after = Hash $settings; $journalHash = Hash $journal
    $r = Install @('-RemoveLegacyHook','-Apply')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('NO_CHANGE')) $r.Text
    Assert ((Hash $settings) -eq $after -and (Hash $journal) -eq $journalHash) 'No-op wrote data'
  }
  Case 'rollback rejects drift and restores exact bytes with another backup' {
    $current = Hash $settings
    $r = Install @('-RollbackBackup',$backup,'-ExpectedCurrentHash',('0'*64),'-Apply')
    Assert ($r.Code -ne 0 -and (Hash $settings) -eq $current) 'Rollback ignored drift guard'
    $r = Install @('-RollbackBackup',$backup,'-ExpectedCurrentHash',$current,'-Apply')
    Assert ($r.Code -eq 0 -and (Hash $settings) -eq $originalHash) $r.Text
    Assert (@(Get-ChildItem $root -Filter '*.bak-*').Count -eq 2) 'Rollback backup missing'
  }
  Case 'relative commands and other project paths are not owned hooks' {
    Write-Settings (@{hooks=@{SessionStart=@(@{hooks=@(
      @{type='command';command='pwsh -NoProfile -File hooks/check-exit-ip.ps1'},
      @{type='command';command=('pwsh -NoProfile -File "' + (Join-Path $root 'hooks/check-exit-ip.ps1') + '"')}
    )})}} | ConvertTo-Json -Depth 20)
    $before=Hash $settings; $journalHash=Hash $journal
    $r=Install @('-RemoveLegacyHook','-Apply')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('NO_CHANGE')) 'Non-owned path matched as owned'
    Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalHash) 'Non-owned hook modified'
  }
  Case 'empty, single and multiple hook arrays preserve shape' {
    foreach ($count in @(0,1,2)) {
      $actions = @(for($i=0; $i -lt $count; $i++){ $legacy })
      Write-Settings (@{hooks=@{SessionStart=@(@{hooks=$actions});Stop=@()}} | ConvertTo-Json -Depth 20)
      $r = Install @('-RemoveLegacyHook','-Apply')
      Assert ($r.Code -eq 0) $r.Text
      $actual = Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json -AsHashtable
      Assert ($actual.hooks.Stop -is [array] -and $actual.hooks.Stop.Count -eq 0) 'Other event shape lost'
      if($count){ Assert (-not $actual.hooks.Contains('SessionStart')) 'Empty owned group remains' }
    }
    Write-Settings (@{hooks=@{SessionStart=@(@{hooks=@($legacy)})}} | ConvertTo-Json -Depth 20)
    $r=Install @('-RemoveLegacyHook','-Apply')
    Assert ($r.Code -eq 0 -and -not ((Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json -AsHashtable).Contains('hooks'))) 'Empty hooks object not removed'
  }
  Case 'proxy casing preserved, additions explicit, conflicts refuse without leaking' {
    Write-Settings '{"env":{"http_proxy":"http://127.0.0.1:10808"}}'
    $r=Install @('-ConfigureProxy','-Proxy','http://127.0.0.1:10808','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    $actual=Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json -AsHashtable
    Assert ($actual.env.Contains('http_proxy') -and $actual.env.Count -eq 2) 'Casing changed or extra env added'
    foreach($text in @('{"env":{"HTTP_PROXY":"http://secret-fixture.invalid:9"}}','{"env":{"HTTP_PROXY":"x","http_proxy":"y"}}','{"env":[]}','{"hooks":{"SessionStart":{}}}','{"hooks":{"SessionStart":[{}]}}','[]','{broken')) {
      Write-Settings $text; $before=Hash $settings
      $r=Install @('-ConfigureProxy','-Proxy','http://127.0.0.1:10808','-RemoveLegacyHook','-Apply')
      Assert ($r.Code -ne 0 -and (Hash $settings) -eq $before) 'Invalid fixture was written'
      Assert (-not $r.Text.Contains('secret-fixture.invalid')) 'Existing proxy leaked'
    }
  }
  Case 'locked settings refuse without changing bytes' {
    Write-Settings '{}'; $before=Hash $settings
    $lock=[IO.File]::Open($settings,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $r=Install @('-ConfigureProxy','-Proxy','http://127.0.0.1:10808','-Apply'); Assert ($r.Code -ne 0) 'Locked file accepted' }
    finally { $lock.Dispose() }
    Assert ((Hash $settings) -eq $before) 'Locked file modified'
  }
  Case 'diagnostic success, mismatch, unreachable and invalid responses' {
    foreach($mode in @('success','mismatch','unreachable','invalid','retired')) {
      $r=Run $mock @('-Script',$hookPath,'-Mode',$mode)
      $code=switch($mode){success{0} mismatch{2} retired{0} default{3}}
      Assert ($r.Code -eq $code) "$mode returned $($r.Code): $($r.Text)"
    }
  }
  Case 'preflight and legacy restore perform no network or timezone mutation' {
    Write-Settings $fixture; $before=Hash $settings
    foreach($mode in @('default','restore')) {
      $r=Run $mock @('-Script',(Join-Path $repo 'prep-registration.ps1'),'-Mode',$mode,'-SettingsPath',$settings)
      Assert ($r.Code -eq 0 -and -not $r.Text.Contains('private-value-fixture')) $r.Text
      Assert ((Hash $settings) -eq $before) 'Preflight modified settings'
    }
    $launcher=Get-Content -Raw -LiteralPath (Join-Path $repo 'start-claude-chrome.cmd')
    Assert ($launcher -notmatch '--(proxy-server|lang|force-webrtc)') 'Launcher still forces identity/network flags'
  }
  Case 'lane status is read-only and classifies the relay form' {
    Write-Settings $relayText; $before = Hash $settings; $journalBefore = Hash $journal
    $r = Lane @()
    Assert ($r.Code -eq 0 -and $r.Text.Contains('"current_lane":"relay"')) $r.Text
    Assert (-not $r.Text.Contains('secret-fixture')) 'Status leaked settings values'
    Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Status wrote data'
    Assert (@(Get-ChildItem $root -Filter '*.bak-claude-lane-*').Count -eq 0) 'Status created backup'
  }
  Case 'lane preview leaves bytes and journal untouched' {
    [IO.File]::WriteAllText($variant, $variantText, [Text.UTF8Encoding]::new($false))
    $before = Hash $settings; $journalBefore = Hash $journal
    $r = Lane @('-ToOfficial')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('PREVIEW')) $r.Text
    Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Preview wrote data'
    Assert (@(Get-ChildItem $root -Filter '*.bak-claude-lane-*').Count -eq 0) 'Preview created backup'
  }
  Case 'lane apply projects exact variant bytes with raw backup and idempotence' {
    $script:relayBeforeHash = Hash $settings
    $variantHash = Hash $variant
    $r = Lane @('-ToOfficial','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    Assert ((Hash $settings) -eq $variantHash) 'Settings differ from variant bytes'
    $script:laneBackup = @(Get-ChildItem $root -Filter '*.bak-claude-lane-*')[0].FullName
    Assert ((Hash $script:laneBackup) -eq $script:relayBeforeHash) 'Lane backup differs from raw original'
    Assert ((Get-Content -Raw -LiteralPath $journal).Contains('applied-readback-verified')) 'Journal missing verified phase'
    $journalHash = Hash $journal
    $r = Lane @('-ToOfficial','-Apply')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('NO_CHANGE')) $r.Text
    Assert ((Hash $settings) -eq $variantHash -and (Hash $journal) -eq $journalHash) 'No-op wrote data'
  }
  Case 'lane apply refuses unrecognized settings and broken variants' {
    foreach ($text in @('{"env":{"KEEP":"value-fixture"}}','{"env":[]}','{broken')) {
      Write-Settings $text; $before = Hash $settings
      $r = Lane @('-ToOfficial','-Apply')
      Assert ($r.Code -ne 0 -and (Hash $settings) -eq $before) "Unrecognized form accepted: $text"
    }
    Write-Settings $relayText
    [IO.File]::WriteAllText($variant, '{broken', [Text.UTF8Encoding]::new($false))
    $before = Hash $settings
    $r = Lane @('-ToOfficial','-Apply')
    Assert ($r.Code -ne 0 -and (Hash $settings) -eq $before) 'Broken variant accepted'
    [IO.File]::WriteAllText($variant, $variantText, [Text.UTF8Encoding]::new($false))
  }
  Case 'lane rollback rejects drift and restores exact bytes with another backup' {
    Write-Settings $variantText
    $current = Hash $settings
    $r = Lane @('-RollbackBackup',$script:laneBackup,'-ExpectedCurrentHash',('0'*64),'-Apply')
    Assert ($r.Code -ne 0 -and (Hash $settings) -eq $current) 'Lane rollback ignored drift guard'
    $r = Lane @('-RollbackBackup',$script:laneBackup,'-ExpectedCurrentHash',$current,'-Apply')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('APPLIED') -and (Hash $settings) -eq $script:relayBeforeHash) $r.Text
    Assert (@(Get-ChildItem $root -Filter '*.bak-claude-lane-*').Count -eq 2) 'Rollback lane backup missing'
  }
  Case 'tracked files carry no raw infrastructure identifiers' {
    # Regression barrier for the 2026-10-15 leaks: a real egress IP, hostname or
    # user path must never reach a tracked file, because a remote mirrors it.
    Push-Location $repo
    try {
      $documentedOnly = @('^127\.', '^10\.', '^192\.168\.', '^172\.(1[6-9]|2\d|3[01])\.', '^192\.0\.2\.', '^198\.51\.100\.', '^203\.0\.113\.')
      $found = [Collections.Generic.List[string]]::new()
      foreach ($relative in @(git ls-files)) {
        $text = Get-Content -LiteralPath (Join-Path $repo $relative) -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($match in [regex]::Matches($text, '(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])')) {
          if (@($documentedOnly | Where-Object { $match.Value -match $_ }).Count -eq 0) { $found.Add("$relative ip=$($match.Value)") }
        }
        if ($text -match '[A-Za-z]:\\Users\\(?!<USER>)') { $found.Add("$relative user-path") }
        if ($text.Contains([Environment]::MachineName)) { $found.Add("$relative hostname") }
      }
      Assert ($found.Count -eq 0) ('raw infrastructure identifiers: ' + ($found -join '; '))
    } finally { Pop-Location }
  }
  Write-Output "Tests: $passed passed; failed=0"
} finally {
  # Delete only the GUID directory created here; never follow a fixture junction.
  $item=Get-Item -LiteralPath $root
  if($item.Parent.FullName -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or $item.Name -notmatch '^claude-tools-[a-f0-9]{32}$' -or
     ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
     @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Unsafe fixture cleanup target' }
  Remove-Item -LiteralPath $root -Recurse -Force
}
