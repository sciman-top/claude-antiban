#Requires -Version 7.3
# Disposable fixtures only: no real settings, browser, login or external requests.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('claude-tools-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$profileRoot = Join-Path $root 'profile'
$null = New-Item -ItemType Directory -Path $profileRoot
$invokeFixture = Join-Path $root 'invoke-with-process-fixture.ps1'
[IO.File]::WriteAllText($invokeFixture, @'
param([string]$Target,[string]$ArgumentsJson)
function global:Get-Process {
  param([string]$Name,[string]$ErrorAction)
  return @()
}
$targetArgs = @($ArgumentsJson | ConvertFrom-Json)
$targetParams = @{}
for ($index = 0; $index -lt $targetArgs.Count; $index++) {
  $token = [string]$targetArgs[$index]
  if ($token -notmatch '^-([A-Za-z][A-Za-z0-9]*)$') { throw 'Unexpected fixture parameter token.' }
  $name = $Matches[1]
  if ($index + 1 -lt $targetArgs.Count -and [string]$targetArgs[$index + 1] -notmatch '^-') {
    $targetParams[$name] = $targetArgs[$index + 1]
    $index++
  } else { $targetParams[$name] = $true }
}
$global:LASTEXITCODE = 0
try { & $Target @targetParams; exit [int]$LASTEXITCODE }
catch { [Console]::Error.WriteLine($_); exit 1 }
'@, [Text.UTF8Encoding]::new($false))
$passed = 0
function Assert($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Run([string]$Script, [string[]]$ScriptArgs = @(), [hashtable]$Environment = @{}) {
  $info = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $null = $info.Environment.Remove('COMPUTERNAME')
  $info.Environment['USERPROFILE'] = $profileRoot
  $diagnosticVariables = @('ANTHROPIC_BASE_URL','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','NODE_TLS_REJECT_UNAUTHORIZED')
  foreach ($key in @($info.Environment.Keys)) {
    if ($key -iin $diagnosticVariables) { $null = $info.Environment.Remove($key) }
  }
  foreach ($name in $Environment.Keys) { $info.Environment[$name] = [string]$Environment[$name] }
  $argumentJson = ConvertTo-Json -InputObject ([string[]]$ScriptArgs) -Compress
  foreach ($arg in @('-NoProfile','-File',$invokeFixture,$Script,$argumentJson)) { $info.ArgumentList.Add($arg) }
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
$settings = Join-Path $profileRoot '配置 with spaces.json'
$journal = Join-Path $profileRoot 'journal.md'
$variant = Join-Path $profileRoot 'official-variant.json'
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
param([string]$Script,[string]$Mode,[string]$SettingsPath,[string]$RepoRoot)
$ErrorActionPreference='Stop'
function global:Set-TimeZone { throw 'Unexpected timezone mutation' }
function global:Get-ItemProperty {
  param([string]$LiteralPath)
  if ($LiteralPath -ne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') { throw 'Unexpected registry access' }
  if ($Mode -eq 'surface-pac') { return [pscustomobject]@{ ProxyEnable=0; AutoConfigURL='https://pac-fixture.invalid/config'; AutoDetect=1 } }
  if ($Mode -eq 'surface-ipv6') { return [pscustomobject]@{ ProxyEnable=1; ProxyServer='http=[::1]:10808;https=127.0.0.1:10808' } }
  if ($Mode -eq 'surface-mixed') { return [pscustomobject]@{ ProxyEnable=1; ProxyServer='http=127.0.0.1:10808;https=proxy-fixture.invalid:8080' } }
  return [pscustomobject]@{ ProxyEnable=0 }
}
function global:Invoke-WebRequest {
  param($Uri,$Proxy,$TimeoutSec,$MaximumRedirection)
  if($Mode -in @('default','restore','surface','surface-no-proxy')) { throw 'Unexpected network request' }
  if($Mode -eq 'unreachable') { throw 'Fixture unreachable' }
  if($Uri -ne 'https://api.ipify.org' -or $TimeoutSec -ne 8 -or $MaximumRedirection -ne 0) { throw 'Unexpected diagnostic request' }
  if($Mode -eq 'invalid') { return @{Content='not-an-ip'} }
  return @{Content='203.0.113.9'}
}
if($Mode -eq 'default') { & $Script -SettingsPath $SettingsPath }
elseif($Mode -eq 'restore') { & $Script -Restore -SettingsPath $SettingsPath }
elseif($Mode -eq 'retired') { & $Script }
elseif($Mode -in @('surface','surface-pac','surface-ipv6','surface-mixed')) { & $Script -RepoRoot $RepoRoot }
elseif($Mode -eq 'surface-no-proxy') { & $Script -RepoRoot $RepoRoot -CheckExitIp }
elseif($Mode -eq 'surface-exit') { & $Script -RepoRoot $RepoRoot -CheckExitIp -ExpectedIp '203.0.113.9' -Proxy 'http://127.0.0.1:1' }
elseif($Mode -eq 'surface-leak') { & $Script -RepoRoot $RepoRoot -CheckUdpLeak -StunServer '127.0.0.1' -StunPort 1 }
elseif($Mode -eq 'surface-leak-invalid') { & $Script -RepoRoot $RepoRoot -CheckUdpLeak -StunPort 0 }
else { & $Script -CheckExitIp -ExpectedIp $(if($Mode -eq 'mismatch'){'203.0.113.10'}else{'203.0.113.9'}) -Proxy 'http://127.0.0.1:1' }
exit $LASTEXITCODE
'@)
$ccSwitchMock = Join-Path $root 'cc-switch-running.ps1'
[IO.File]::WriteAllText($ccSwitchMock, @'
param([string]$Mode,[string]$Repo,[string]$SettingsPath,[string]$JournalPath,[string]$VariantPath)
$ErrorActionPreference='Stop'
function global:Get-Process {
  param([string]$Name,[string]$ErrorAction)
  if ($Name -ieq 'cc-switch') { return [pscustomobject]@{ ProcessName='cc-switch' } }
  return @()
}
if ($Mode -eq 'install') {
  & (Join-Path $Repo 'install.ps1') -SettingsPath $SettingsPath -JournalPath $JournalPath -RemoveLegacyHook -Apply
} elseif ($Mode -eq 'lane') {
  & (Join-Path $Repo 'Set-ClaudeLane.ps1') -SettingsPath $SettingsPath -VariantPath $VariantPath -JournalPath $JournalPath -ToOfficial -Apply
} else { throw 'Unexpected mock mode.' }
exit $LASTEXITCODE
'@, [Text.UTF8Encoding]::new($false))
try {
  Case 'official template keeps the agreed approval boundary and no fixed network route' {
    $officialText = Get-Content -Raw -LiteralPath (Join-Path $repo 'settings.official-anthropic.json')
    $official = $officialText | ConvertFrom-Json -AsHashtable -Depth 100
    Assert ($official.permissions.defaultMode -eq 'bypassPermissions') 'Official template must default to bypass permissions'
    Assert (@($official.permissions.allow).Count -eq 1 -and $official.permissions.allow[0] -ceq 'mcp__terminal__run_in_terminal') 'Official template allow list must stay scoped to the Desktop terminal tool'
    Assert (-not $official.permissions.Contains('disableAutoMode') -and -not $official.permissions.Contains('disableBypassPermissionsMode')) 'Approval-mode disable pins must stay absent'
    Assert (-not $official.Contains('env') -and -not $official.permissions.Contains('additionalDirectories')) 'Official template must not carry machine routing or extra workspace paths'
    Assert (-not $official.Contains('statusLine')) 'Official template must not reference an unavailable local status script'
    foreach ($rule in @('PowerShell(git reset --hard*)','PowerShell(git clean -*)','PowerShell(Remove-Item *)','PowerShell(Format-Volume *)','PowerShell(reg delete*)')) {
      Assert ($official.permissions.deny -ccontains $rule) "Missing native PowerShell protection: $rule"
    }
    # 解释器前缀（pwsh/powershell 及 .exe 变体）不得回归：PowerShell 7-only 仓库
    # 工作流本身以 pwsh 起头，封禁解释器会让 bypass 自主基线下每条 shell 命令都弹确认。
    foreach ($rule in @('Bash(powershell:*)','Bash(powershell.exe:*)','Bash(pwsh:*)','Bash(pwsh.exe:*)','PowerShell(powershell:*)','PowerShell(powershell.exe:*)','PowerShell(pwsh:*)','PowerShell(pwsh.exe:*)')) {
      Assert (-not ($official.permissions.deny -ccontains $rule)) "Interpreter-blanket deny must stay absent: $rule"
    }
    Assert ($officialText -notmatch '127\.0\.0\.1|skills-manager|claude-dashboard') 'Official template still carries machine-specific values'
  }
  Case 'preview leaves bytes and journal untouched' {
    Write-Settings $fixture
    $before = Hash $settings
    $r = Install @('-RemoveLegacyHook')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('PREVIEW')) $r.Text
    Assert ((Hash $settings) -eq $before -and -not (Test-Path $journal)) 'Preview wrote data'
    Assert (@(Get-ChildItem $profileRoot -Filter '*.bak-*').Count -eq 0) 'Preview created backup'
  }
  Case 'precise mixed hook removal, raw backup and idempotence' {
    $script:originalHash = Hash $settings
    $r = Install @('-RemoveLegacyHook','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    $script:backup = @(Get-ChildItem $profileRoot -Filter '*.bak-*')[0].FullName
    Assert ((Hash $backup) -eq $originalHash) 'Backup differs from raw original'
    $journalText = Get-Content -Raw -LiteralPath $journal
    Assert ($journalText -notmatch '(?m)^## .*\|\s*$') 'Missing machine name when environment variable is absent'
    Assert ($journalText -match '(?m)^## .*\| <HOST-[0-9a-f]{8}>\s*$') 'Journal header must carry a host pseudonym, not a raw hostname'
    $journalBackup = [regex]::Match($journalText, '(?m)^- backup: (?<path>.+?)\r?$').Groups['path'].Value
    Assert ($journalBackup -match '^<SETTINGS-DIR>\\<SETTINGS-FILE>\.bak-claude-env-[a-f0-9]{32}$') 'Nonstandard settings path must use placeholders'
    Assert (-not $journalText.Contains($root)) 'Journal leaked the fixture user profile'
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
    $journalBefore = Hash $journal
    $r = Install @('-RollbackBackup',$backup,'-ExpectedCurrentHash',$current)
    Assert ($r.Code -eq 0 -and $r.Text.Contains('scope=restore-backup-file') -and $r.Text.Contains('backup-bytes=restored') -and $r.Text.Contains('current-file=replaced')) $r.Text
    Assert ((Hash $settings) -eq $current -and (Hash $journal) -eq $journalBefore) 'Rollback preview wrote data'
    $r = Install @('-RollbackBackup',$backup,'-ExpectedCurrentHash',$current,'-Apply')
    Assert ($r.Code -eq 0 -and (Hash $settings) -eq $originalHash) $r.Text
    Assert (@(Get-ChildItem $profileRoot -Filter '*.bak-*').Count -eq 2) 'Rollback backup missing'
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
    try { $r=Install @('-ConfigureProxy','-Proxy','http://127.0.0.1:10808','-Apply'); Assert ($r.Code -ne 0) ("Locked file accepted: " + $r.Text) }
    finally { $lock.Dispose() }
    Assert ((Hash $settings) -eq $before) 'Locked file modified'
  }
  Case 'install and lane fail closed while cc-switch is running' {
    [IO.File]::WriteAllText($variant, $variantText, [Text.UTF8Encoding]::new($false))
    Write-Settings $fixture
    $before = Hash $settings; $journalBefore = if (Test-Path $journal) { Hash $journal } else { '' }
    $r = Run $ccSwitchMock @('-Mode','install','-Repo',$repo,'-SettingsPath',$settings,'-JournalPath',$journal,'-VariantPath',$variant)
    Assert ($r.Code -ne 0 -and $r.Text.Contains('cc-switch is running')) $r.Text
    Assert ((Hash $settings) -eq $before -and ((Test-Path $journal) -eq [bool]$journalBefore)) 'Installer changed data while CC Switch was active'
    if ($journalBefore) { Assert ((Hash $journal) -eq $journalBefore) 'Installer journal changed while CC Switch was active' }

    Write-Settings $relayText
    $before = Hash $settings; $journalBefore = if (Test-Path $journal) { Hash $journal } else { '' }
    $r = Run $ccSwitchMock @('-Mode','lane','-Repo',$repo,'-SettingsPath',$settings,'-JournalPath',$journal,'-VariantPath',$variant)
    Assert ($r.Code -ne 0 -and $r.Text.Contains('cc-switch is running')) $r.Text
    Assert ((Hash $settings) -eq $before -and ((Test-Path $journal) -eq [bool]$journalBefore)) 'Lane writer changed data while CC Switch was active'
    if ($journalBefore) { Assert ((Hash $journal) -eq $journalBefore) 'Lane journal changed while CC Switch was active' }
  }
  Case 'journal redacts backup paths outside the user profile' {
    $outside = Join-Path $root 'outside-profile'
    $null = New-Item -ItemType Directory -Path $outside -Force
    $outsideSettings = Join-Path $outside 'settings.json'
    $outsideJournal = Join-Path $outside 'install-journal.md'
    [IO.File]::WriteAllText($outsideSettings, (@{hooks=@{SessionStart=@(@{hooks=@($legacy)})}} | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $r = Run (Join-Path $repo 'install.ps1') @('-SettingsPath',$outsideSettings,'-JournalPath',$outsideJournal,'-RemoveLegacyHook','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    $installLog = Get-Content -Raw -LiteralPath $outsideJournal
    Assert (-not $installLog.Contains($root)) 'Installer journal leaked an external settings path'
    Assert ($installLog -match '(?m)^- backup: <SETTINGS-DIR>\\<SETTINGS-FILE>\.bak-claude-env-[a-f0-9]{32}\r?$') 'Installer backup path was not reduced to the placeholder form'

    $outsideLaneJournal = Join-Path $outside 'lane-journal.md'
    [IO.File]::WriteAllText($outsideSettings, $relayText, [Text.UTF8Encoding]::new($false))
    $r = Run (Join-Path $repo 'Set-ClaudeLane.ps1') @('-SettingsPath',$outsideSettings,'-VariantPath',$variant,'-JournalPath',$outsideLaneJournal,'-ToOfficial','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    $laneLog = Get-Content -Raw -LiteralPath $outsideLaneJournal
    Assert (-not $laneLog.Contains($root)) 'Lane journal leaked an external settings path'
    Assert ($laneLog -match '(?m)^- backup: <SETTINGS-DIR>\\<SETTINGS-FILE>\.bak-claude-lane-[a-f0-9]{32}\r?$') 'Lane backup path was not reduced to the placeholder form'
  }
  Case 'journal preserves only the standard settings path within the user profile' {
    foreach ($relative in @('.claude/settings.json','private-organization/settings.json')) {
      $target = Join-Path $profileRoot $relative
      $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
      foreach ($writer in @('install','lane')) {
        $log = Join-Path $root ($writer + '-path-' + [guid]::NewGuid().ToString('N') + '.md')
        $source = if ($writer -eq 'install') { $fixture } else { $relayText }
        [IO.File]::WriteAllText($target,$source,[Text.UTF8Encoding]::new($false))
        $options = @('-SettingsPath',$target,'-JournalPath',$log)
        if ($writer -eq 'install') { $r = Run (Join-Path $repo 'install.ps1') ($options + @('-RemoveLegacyHook','-Apply')) }
        else { $r = Run (Join-Path $repo 'Set-ClaudeLane.ps1') ($options + @('-VariantPath',$variant,'-ToOfficial','-Apply')) }
        Assert ($r.Code -eq 0) $r.Text
        $text = Get-Content -Raw -LiteralPath $log
        Assert (-not $text.Contains('private-organization') -and -not $text.Contains($root)) 'User-relative directory leaked into the journal'
        $prefix = if ($relative -eq '.claude/settings.json') { '%USERPROFILE%\.claude\settings.json.bak-' } else { '<SETTINGS-DIR>\<SETTINGS-FILE>.bak-' }
        Assert ($text.Contains($prefix)) 'Wrong journal path classification'
      }
    }
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
    $processVars = @{ ANTHROPIC_BASE_URL='process-secret-fixture'; HTTP_PROXY='process-proxy-fixture'; ALL_PROXY='process-socks-fixture' }
    foreach($mode in @('default','restore')) {
      $environment = if ($mode -eq 'default') { $processVars } else { @{} }
      $r=Run $mock @('-Script',(Join-Path $repo 'prep-registration.ps1'),'-Mode',$mode,'-SettingsPath',$settings) $environment
      Assert ($r.Code -eq 0 -and -not $r.Text.Contains('private-value-fixture')) $r.Text
      Assert ((Hash $settings) -eq $before) 'Preflight modified settings'
      if ($mode -eq 'default') {
        Assert ($r.Text -match '(?m)^ANTHROPIC_BASE_URL settings_present=False process_present=True user_present=(True|False|unavailable) machine_present=(True|False|unavailable)\r?$') $r.Text
        Assert ($r.Text -match '(?m)^HTTP_PROXY settings_present=True process_present=True user_present=(True|False|unavailable) machine_present=(True|False|unavailable)\r?$') $r.Text
        Assert ($r.Text -match '(?m)^ALL_PROXY settings_present=False process_present=True user_present=(True|False|unavailable) machine_present=(True|False|unavailable)\r?$') $r.Text
        Assert (-not $r.Text.Contains('process-secret-fixture') -and -not $r.Text.Contains('process-proxy-fixture') -and -not $r.Text.Contains('process-socks-fixture')) 'Preflight leaked an environment value'
      }
    }
    Remove-Item -LiteralPath $settings
    $r=Run $mock @('-Script',(Join-Path $repo 'prep-registration.ps1'),'-Mode','default','-SettingsPath',$settings) $processVars
    Assert ($r.Code -eq 0 -and $r.Text.Contains('USER_SETTINGS=absent') -and $r.Text.Contains('ANTHROPIC_BASE_URL settings_present=False process_present=True')) $r.Text
    Assert (-not $r.Text.Contains('process-secret-fixture')) 'Preflight leaked process values when settings are absent'
    # Boundary: the default entry stays free of identity and network flags; the opt-in
    # entry may add only the documented WebRTC IP handling policy that keeps WebRTC
    # media from leaving through non-proxied UDP, and must reuse the same profile.
    $launcher=Get-Content -Raw -LiteralPath (Join-Path $repo 'start-claude-chrome.cmd')
    Assert ($launcher -notmatch '--(proxy-server|lang|force-webrtc|disable-webrtc|user-agent|accept-lang|dns-over-https)') 'Default launcher still forces identity/network flags'
    $leakless=Get-Content -Raw -LiteralPath (Join-Path $repo 'start-claude-chrome-leakless.cmd')
    Assert ($leakless -match '--force-webrtc-ip-handling-policy=disable_non_proxied_udp') 'Leakless entry lost its WebRTC IP handling policy'
    Assert ($leakless -notmatch '--(proxy-server|lang|user-agent|accept-lang|disable-webrtc|dns-over-https|force-webrtc-ip-handling-policy=(?!disable_non_proxied_udp))') 'Leakless entry carries flags beyond the documented WebRTC policy'
    Assert ($leakless.Contains('--user-data-dir="%~dp0chrome-data"')) 'Leakless entry must reuse the same isolated profile'
  }
  Case 'surface report is read-only, local-only and prints no infrastructure values' {
    # The report exists so a third-party score can be attributed to host, browser or
    # network facts without visiting a scoring site; it must stay read-only and must
    # never put this machine's values into output that could be quoted elsewhere.
    $surfaceRoot = Join-Path $root 'surface'
    $surfaceProfile = Join-Path $surfaceRoot 'chrome-data/Default'
    $null = New-Item -ItemType Directory -Path $surfaceProfile -Force
    [IO.File]::WriteAllText((Join-Path $surfaceRoot 'start-claude-chrome.cmd'),
      "@echo off`r`nstart `"`" `"chrome.exe`" --user-data-dir=`"%~dp0chrome-data`" --no-first-run `"https://claude.ai`"`r`n",
      [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $surfaceRoot 'start-claude-chrome-leakless.cmd'),
      "@echo off`r`nstart `"`" `"chrome.exe`" --user-data-dir=`"%~dp0chrome-data`" --no-first-run --force-webrtc-ip-handling-policy=disable_non_proxied_udp `"https://claude.ai`"`r`n",
      [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $surfaceProfile 'Preferences'),
      '{"intl":{"selected_languages":["en-US","en"],"accept_languages":"en-US,en"},"webrtc":{"ip_handling_policy":"disable_non_proxied_udp"}}',
      [Text.UTF8Encoding]::new($false))
    $surfaceBefore = @(Get-ChildItem -LiteralPath $surfaceRoot -Recurse -Force | ForEach-Object { $_.FullName })
    $r = Run $mock @('-Script',(Join-Path $repo 'Get-SurfaceReport.ps1'),'-Mode','surface','-RepoRoot',$surfaceRoot)
    Assert ($r.Code -eq 0) $r.Text
    Assert ($r.Text -match '(?m)^LAUNCHER=start-claude-chrome\.cmd flags=user-data-dir,no-first-run\r?$') $r.Text
    Assert ($r.Text -match '(?m)^LAUNCHER=start-claude-chrome-leakless\.cmd flags=user-data-dir,no-first-run,force-webrtc-ip-handling-policy\r?$') $r.Text
    Assert ($r.Text -match '(?m)^WEBRTC_NON_PROXIED_UDP=configured-by-launcher start-claude-chrome-leakless\.cmd\r?$') $r.Text
    Assert ($r.Text -match '(?m)^WEBRTC_RUNTIME=not-verified;') $r.Text
    Assert ($r.Text -notmatch 'sealed-by-launcher') $r.Text
    Assert ($r.Text -match '(?m)^BROWSER_PROFILE=present languages=en-US,en\r?$') $r.Text
    Assert ($r.Text -match '(?m)^WEBRTC_POLICY_OVERRIDE=present\r?$') $r.Text
    Assert ($r.Text -match '(?m)^EAST_ASIAN_FONTS_PRESENT=(True|False|unavailable)\r?$') $r.Text
    Assert ($r.Text -match '(?m)^SYSTEM_PROXY=disabled loopback=n/a\r?$') $r.Text
    Assert ($r.Text -match '(?m)^EFFECTIVE_PROXY=unverified;') $r.Text
    Assert ($r.Text -match '(?m)^PROXY_ENV_PRESENT=process=none user=(none|\S+) machine=(none|\S+)\r?$') $r.Text
    Assert ($r.Text -match '(?m)^NETWORK_CHECK=not-requested\r?$') $r.Text
    Assert (@(Get-ChildItem -LiteralPath $surfaceRoot -Recurse -Force | ForEach-Object { $_.FullName }).Count -eq $surfaceBefore.Count) 'Surface report added files'
    foreach ($match in [regex]::Matches($r.Text, '(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])')) {
      Assert ($match.Value -match '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') ('Surface report printed a raw address: ' + $match.Value)
    }
    $r = Run $mock @('-Script',(Join-Path $repo 'Get-SurfaceReport.ps1'),'-Mode','surface-no-proxy','-RepoRoot',$surfaceRoot)
    Assert ($r.Code -eq 3) "Surface exit check without an explicit proxy returned $($r.Code): $($r.Text)"
    $r = Run $mock @('-Script',(Join-Path $repo 'Get-SurfaceReport.ps1'),'-Mode','surface-exit','-RepoRoot',$surfaceRoot)
    Assert ($r.Code -eq 0 -and $r.Text.Contains('OBSERVED_IP=203.0.113.9')) $r.Text
    # The UDP probe stays off unless requested and reports the loopback no-answer path
    # honestly, so the fixture never depends on external UDP reachability.
    Assert ($r.Text -notmatch '(?m)^UDP_PROBE=stun\.l\.google\.com') 'Surface report probed UDP without being asked'
    $r = Run $mock @('-Script',(Join-Path $repo 'Get-SurfaceReport.ps1'),'-Mode','surface-leak','-RepoRoot',$surfaceRoot)
    Assert ($r.Code -eq 0 -and $r.Text.Contains('UDP_PROBE=127.0.0.1:1 reply=none')) $r.Text
    $r = Run $mock @('-Script',(Join-Path $repo 'Get-SurfaceReport.ps1'),'-Mode','surface-leak-invalid','-RepoRoot',$surfaceRoot)
    Assert ($r.Code -eq 3) "Surface UDP probe accepted an invalid port: $($r.Code): $($r.Text)"
  }
  Case 'surface distinguishes PAC and all static proxy entries without claiming an effective route' {
    $proxyRoot = Join-Path $root 'surface-proxy'
    $null = New-Item -ItemType Directory -Path $proxyRoot
    foreach ($mode in @('surface-pac','surface-ipv6','surface-mixed')) {
      $r = Run $mock @('-Script',(Join-Path $repo 'Get-SurfaceReport.ps1'),'-Mode',$mode,'-RepoRoot',$proxyRoot)
      Assert ($r.Code -eq 0 -and $r.Text.Contains('EFFECTIVE_PROXY=unverified')) $r.Text
      Assert (-not $r.Text.Contains('pac-fixture.invalid') -and -not $r.Text.Contains('proxy-fixture.invalid')) 'Proxy source value leaked'
      if ($mode -eq 'surface-pac') {
        Assert ($r.Text.Contains('SYSTEM_PROXY=disabled loopback=n/a') -and $r.Text.Contains('pac_present=True auto_detect=True') -and -not $r.Text.Contains('SYSTEM_PROXY=direct')) $r.Text
      } elseif ($mode -eq 'surface-ipv6') {
        Assert ($r.Text.Contains('SYSTEM_PROXY=configured loopback=True')) $r.Text
      } else { Assert ($r.Text.Contains('SYSTEM_PROXY=configured loopback=False')) $r.Text }
    }
  }
  Case 'STUN validates transaction, complete attributes and IPv4 family before accepting an address' {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Get-SurfaceReport.ps1'), [ref]$null, [ref]$null)
    $parser = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertFrom-StunResponse'}, $true)
    . ([scriptblock]::Create($parser.Extent.Text))
    $tx = [byte[]]@(0..11)
    $valid = [Convert]::FromHexString('0101000c2112a442000102030405060708090a0b002000080001a147e112a643')
    $result = ConvertFrom-StunResponse $valid $tx
    Assert ($result.Status -eq 'valid' -and $result.Address -eq '192.0.2.1') 'Valid binding response rejected'
    foreach ($index in @(0,1,2,3,4,8,23,24,25)) {
      $bad = [byte[]]$valid.Clone(); $bad[$index] = $bad[$index] -bxor 1
      $result = ConvertFrom-StunResponse $bad $tx
      Assert ($result.Status -eq 'invalid-response' -and -not $result.Address) "Malformed response accepted at index $index"
    }
    foreach ($bad in @([byte[]]$valid[0..18], [byte[]]$valid[0..30], [byte[]]($valid + [byte[]]@(0,0,0,0)))) {
      Assert ((ConvertFrom-StunResponse $bad $tx).Status -eq 'invalid-response') 'Incomplete or trailing datagram accepted'
    }
    $empty = [byte[]]$valid[0..19]; $empty[3] = 0
    Assert ((ConvertFrom-StunResponse $empty $tx).Status -eq 'no-mapped-address') 'Missing address treated as success'
    $ipv6 = [byte[]]::new(44); [Array]::Copy($valid, $ipv6, 28); $ipv6[3]=24; $ipv6[23]=20; $ipv6[25]=2
    Assert ((ConvertFrom-StunResponse $ipv6 $tx).Status -eq 'unsupported-address-family') 'Unsupported IPv6 mapped address misread as IPv4'
    $padded = [byte[]]($valid + [byte[]]@(0x80,0x22,0,1,0x41,0,0,0)); $padded[3]=20
    Assert ((ConvertFrom-StunResponse $padded $tx).Status -eq 'valid') 'Padded unknown attribute rejected'
    $padded[35]=8
    Assert ((ConvertFrom-StunResponse $padded $tx).Status -eq 'invalid-response') 'Malformed attribute after a mapped address ignored'
  }
  Case 'lane status is read-only and classifies the relay form' {
    Write-Settings $relayText; $before = Hash $settings; $journalBefore = Hash $journal
    $r = Lane @()
    Assert ($r.Code -eq 0 -and $r.Text.Contains('"current_lane":"relay"')) $r.Text
    Assert (-not $r.Text.Contains('secret-fixture')) 'Status leaked settings values'
    Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Status wrote data'
    Assert (@(Get-ChildItem $profileRoot -Filter '*.bak-claude-lane-*').Count -eq 0) 'Status created backup'
  }
  Case 'lane status calls only an exact projected variant official' {
    [IO.File]::WriteAllText($variant, '{"statusLine":{"command":"node %USERPROFILE%/.claude/plugin.js","type":"command"}}', [Text.UTF8Encoding]::new($false))
    $profilePath = [IO.Path]::GetFullPath($profileRoot).Replace('\','/')
    $projected = ([IO.File]::ReadAllText($variant)).Replace('%USERPROFILE%', $profilePath)
    [IO.File]::WriteAllText($settings, $projected, [Text.UTF8Encoding]::new($false))
    $officialHash = Hash $settings
    $r = Lane @()
    Assert ($r.Code -eq 0 -and $r.Text.Contains('"current_lane":"official"')) $r.Text
    Assert ((Hash $settings) -eq $officialHash) 'Status modified official settings'

    [IO.File]::AppendAllText($settings, "`n")
    $customHash = Hash $settings
    $r = Lane @()
    Assert ($r.Code -eq 0 -and $r.Text.Contains('"current_lane":"custom"')) $r.Text
    Assert ((Hash $settings) -eq $customHash) 'Status modified custom settings'
    Write-Settings $relayText
    [IO.File]::WriteAllText($variant, $variantText, [Text.UTF8Encoding]::new($false))
  }
  Case 'lane status classifies missing and invalid settings without writing' {
    Remove-Item -LiteralPath $settings
    $r = Lane @()
    Assert ($r.Code -eq 0 -and $r.Text.Contains('"current_lane":"missing"')) $r.Text
    [IO.File]::WriteAllText($settings, '{broken', [Text.UTF8Encoding]::new($false))
    $journalBefore = Hash $journal
    $r = Lane @()
    Assert ($r.Code -eq 0 -and $r.Text.Contains('"current_lane":"invalid"')) $r.Text
    Assert (-not $r.Text.Contains('must be a valid JSON')) 'Status leaked a parse error instead of a class'
    Assert ((Hash $journal) -eq $journalBefore) 'Status wrote journal'
    Assert (@(Get-ChildItem $profileRoot -Filter '*.bak-claude-lane-*').Count -eq 0) 'Status created backup'
    Write-Settings $relayText
  }
  Case 'official status reports inherited overrides without claiming a route' {
    $r = Run (Join-Path $repo 'Set-ClaudeLane.ps1') @('-SettingsPath',$settings,'-VariantPath',$variant,'-JournalPath',$journal) @{
      ANTHROPIC_BASE_URL='https://private-value-fixture.invalid'; CLAUDE_CODE_USE_BEDROCK='1'
    }
    Assert ($r.Code -eq 0) $r.Text
    $state = $r.Text | ConvertFrom-Json
    Assert ($state.process_overrides_present -contains 'ANTHROPIC_BASE_URL' -and $state.process_overrides_present -contains 'CLAUDE_CODE_USE_BEDROCK') 'Inherited overrides missing from status'
    Assert ($state.route_verified -eq $false -and -not $r.Text.Contains('private-value-fixture')) 'Status leaked a value or claimed a route'
  }
  Case 'official child removes route credentials and keeps proxy and CA configuration' {
    $cleanText = '{"permissions":{"defaultMode":"default"}}'
    [IO.File]::WriteAllText($variant,$cleanText,[Text.UTF8Encoding]::new($false))
    Write-Settings $cleanText
    $before = Hash $settings; $journalBefore = Hash $journal
    $r = Run (Join-Path $repo 'Set-ClaudeLane.ps1') @('-OfficialPreflight','-SettingsPath',$settings,'-VariantPath',$variant,'-JournalPath',$journal) @{
      ANTHROPIC_BASE_URL='https://private-value-fixture.invalid'; ANTHROPIC_AUTH_TOKEN='private-token-fixture';
      CLAUDE_CONFIG_DIR='private-config-fixture'; CLAUDE_CODE_USE_BEDROCK='1'; NODE_TLS_REJECT_UNAUTHORIZED='0'; HTTP_PROXY='http://proxy-fixture.invalid';
      NODE_EXTRA_CA_CERTS='fixture-ca-only'; MAX_THINKING_TOKENS='1'; CLAUDE_CODE_EXTRA_BODY='{"k":"private-value-fixture"}'; MAX_MCP_OUTPUT_TOKENS='1'
      CLAUDE_CODE_USE_ANTHROPIC_AWS='1'; CLAUDE_CODE_USE_MANTLE='1'; CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST='1'
      CLAUDE_CODE_OAUTH_REFRESH_TOKEN='private-refresh-fixture'; CLAUDE_CODE_OAUTH_SCOPES='private-scopes-fixture'
    }
    Assert ($r.Code -eq 0) $r.Text
    foreach ($name in @('ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','CLAUDE_CONFIG_DIR','CLAUDE_CODE_USE_BEDROCK','NODE_TLS_REJECT_UNAUTHORIZED','MAX_THINKING_TOKENS','CLAUDE_CODE_EXTRA_BODY','MAX_MCP_OUTPUT_TOKENS','CLAUDE_CODE_USE_ANTHROPIC_AWS','CLAUDE_CODE_USE_MANTLE','CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST','CLAUDE_CODE_OAUTH_REFRESH_TOKEN','CLAUDE_CODE_OAUTH_SCOPES')) {
      Assert ($r.Text -match ("(?m)^" + $name + ' settings_present=False process_present=False ')) "Override survived: $name"
    }
    foreach ($name in @('HTTP_PROXY','NODE_EXTRA_CA_CERTS')) {
      Assert ($r.Text -match ("(?m)^" + $name + ' settings_present=False process_present=True ')) "Network configuration removed: $name"
    }
    Assert (-not $r.Text.Contains('private-token-fixture') -and -not $r.Text.Contains('private-value-fixture') -and -not $r.Text.Contains('private-refresh-fixture') -and -not $r.Text.Contains('private-scopes-fixture')) 'Child preflight leaked values'
    Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Child preflight wrote data'
    Write-Settings $relayText
    [IO.File]::WriteAllText($variant,$variantText,[Text.UTF8Encoding]::new($false))
  }
  Case 'official child refuses mismatched settings and credential-bearing variants' {
    foreach ($text in @('{"apiKeyHelper":"fixture-helper"}','{"env":{"ANTHROPIC_BASE_URL":"https://private-value-fixture.invalid"}}','{"env":{"CLAUDE_CONFIG_DIR":"private-config-fixture"}}','{"env":{"MAX_THINKING_TOKENS":"1"}}','{"env":{"CLAUDE_CODE_EXTRA_BODY":"{}"}}','{"env":{"MAX_MCP_OUTPUT_TOKENS":"1"}}','{"env":[]}','{"env":"private-value-fixture"}')) {
      [IO.File]::WriteAllText($variant,$text,[Text.UTF8Encoding]::new($false)); Write-Settings $text
      foreach ($action in @('-OfficialPreflight','-LaunchOfficial')) {
        $r = Lane @($action)
        Assert ($r.Code -ne 0 -and $r.Text.Contains('no process started') -and -not $r.Text.Contains('private-value-fixture')) $r.Text
      }
    }
    $cleanText = '{"permissions":{"defaultMode":"default"}}'
    [IO.File]::WriteAllText($variant,$cleanText,[Text.UTF8Encoding]::new($false)); Write-Settings $cleanText
    $r = Lane @('-LaunchOfficial')
    Assert ($r.Code -ne 0 -and $r.Text.Contains('default user settings path only') -and -not $r.Text.Contains('OFFICIAL_PROCESS=started')) $r.Text
    Write-Settings $relayText
    [IO.File]::WriteAllText($variant,$variantText,[Text.UTF8Encoding]::new($false))
    $before = Hash $settings
    foreach ($options in @(@('-OfficialPreflight'),@('-OfficialPreflight','-Apply'),@('-LaunchOfficial','-ToOfficial'))) {
      $r = Lane $options
      Assert ($r.Code -ne 0 -and (Hash $settings) -eq $before) 'Unsafe official process action accepted'
    }
  }
  Case 'lane preview leaves bytes and journal untouched' {
    [IO.File]::WriteAllText($variant, $variantText, [Text.UTF8Encoding]::new($false))
    $before = Hash $settings; $journalBefore = Hash $journal
    $r = Lane @('-ToOfficial')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('PREVIEW') -and $r.Text.Contains('full-file-replacement=true') -and $r.Text.Contains('extra-settings=not-preserved')) $r.Text
    Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Preview wrote data'
    Assert (@(Get-ChildItem $profileRoot -Filter '*.bak-claude-lane-*').Count -eq 0) 'Preview created backup'
  }
  Case 'lane apply projects exact variant bytes with raw backup and idempotence' {
    $script:relayBeforeHash = Hash $settings
    $variantHash = Hash $variant
    $r = Lane @('-ToOfficial','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    Assert ((Hash $settings) -eq $variantHash) 'Settings differ from variant bytes'
    $script:laneBackup = @(Get-ChildItem $profileRoot -Filter '*.bak-claude-lane-*')[0].FullName
    Assert ((Hash $script:laneBackup) -eq $script:relayBeforeHash) 'Lane backup differs from raw original'
    $journalText = Get-Content -Raw -LiteralPath $journal
    Assert ($journalText.Contains('applied-readback-verified')) 'Journal missing verified phase'
    $backupMatches = [regex]::Matches($journalText, '(?m)^- backup: (?<path>.+?)\r?$')
    $journalBackup = $backupMatches[$backupMatches.Count - 1].Groups['path'].Value
    Assert ($journalBackup -match '^<SETTINGS-DIR>\\<SETTINGS-FILE>\.bak-claude-lane-[a-f0-9]{32}$') 'Nonstandard lane path must use placeholders'
    Assert (-not $journalText.Contains($root)) 'Lane journal leaked the fixture user profile'
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
  Case 'legacy repository template refresh is pinned to its exact historical digest' {
    foreach ($expectedLegacyHash in @('7670e3ce0a27aea327f17d4ccf3f0293ba578d75ed783eb3dfd2d93bbaa355af','d1d81170b3b5b0edd1769084dd3cc75dba01145736eb25e2b344a04a75591b8f')) {
    $profilePath = [IO.Path]::GetFullPath($profileRoot).Replace('\','/')
    $legacyTemplateText = $null
    foreach ($commit in @(git -C $repo rev-list --all -- 'settings.official-anthropic.json' 2>$null)) {
      $lines = @(git -C $repo show "$($commit):settings.official-anthropic.json" 2>$null)
      if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { continue }
      $candidate = [string]::Join("`n", $lines) + "`n"
      $normalized = $candidate.Replace($profilePath, '%USERPROFILE%')
      $candidateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($normalized))).ToLowerInvariant()
      if ($candidateHash -eq $expectedLegacyHash) { $legacyTemplateText = $candidate; break }
    }
    Assert (-not [string]::IsNullOrWhiteSpace($legacyTemplateText)) 'Exact previous official-template fixture was not found in Git history'
    $legacyProjected = $legacyTemplateText.Replace('%USERPROFILE%', $profilePath)
    $journalBefore = if (Test-Path $journal) { Hash $journal } else { '' }
    foreach ($lineEnding in @('LF','CRLF')) {
      $legacyCandidate = if ($lineEnding -eq 'CRLF') { $legacyProjected.Replace("`n", "`r`n") } else { $legacyProjected }
      [IO.File]::WriteAllText($settings, $legacyCandidate, [Text.UTF8Encoding]::new($false))
      $legacyHash = Hash $settings
      $r = Lane @('-ToOfficial')
      Assert ($r.Code -eq 0 -and $r.Text.Contains('refresh-known-official-template')) "${lineEnding}: $($r.Text)"
      Assert ((Hash $settings) -eq $legacyHash -and ((Test-Path $journal) -eq [bool]$journalBefore)) "$lineEnding legacy preview modified settings or journal"
    }

    [IO.File]::AppendAllText($settings, "`n")
    $modifiedHash = Hash $settings
    $r = Lane @('-ToOfficial','-Apply')
    Assert ($r.Code -ne 0 -and $r.Text.Contains('neither the relay form nor the exact previous repository template')) $r.Text
    Assert ((Hash $settings) -eq $modifiedHash) 'Modified legacy settings were replaced'
    if ($journalBefore) { Assert ((Hash $journal) -eq $journalBefore) 'Rejected legacy settings changed the journal' }
    }
    Write-Settings $relayText
  }
  Case 'lane rollback rejects drift and restores exact bytes with another backup' {
    Write-Settings $variantText
    $current = Hash $settings
    $journalBefore = Hash $journal
    $r = Lane @('-RollbackBackup',$script:laneBackup,'-ExpectedCurrentHash',$current)
    Assert ($r.Code -eq 0 -and $r.Text.Contains('scope=restore-backup-file') -and $r.Text.Contains('backup-bytes=restored') -and $r.Text.Contains('current-file=replaced')) $r.Text
    Assert ((Hash $settings) -eq $current -and (Hash $journal) -eq $journalBefore) 'Rollback preview wrote data'
    $r = Lane @('-RollbackBackup',$script:laneBackup,'-ExpectedCurrentHash',('0'*64),'-Apply')
    Assert ($r.Code -ne 0 -and (Hash $settings) -eq $current) 'Lane rollback ignored drift guard'
    $r = Lane @('-RollbackBackup',$script:laneBackup,'-ExpectedCurrentHash',$current,'-Apply')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('APPLIED') -and (Hash $settings) -eq $script:relayBeforeHash) $r.Text
    Assert (@(Get-ChildItem $profileRoot -Filter '*.bak-claude-lane-*').Count -eq 2) 'Rollback lane backup missing'
  }
  Case 'variant placeholder projects the current profile instead of a literal path' {
    Write-Settings $relayText
    [IO.File]::WriteAllText($variant, '{"statusLine":{"command":"node %USERPROFILE%/.claude/plugin.js","type":"command"}}', [Text.UTF8Encoding]::new($false))
    $r = Lane @('-ToOfficial','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    $projected = Get-Content -Raw -LiteralPath $settings
    $profile = [IO.Path]::GetFullPath($profileRoot).Replace('\','/')
    Assert ($projected.Contains("node $profile/.claude/plugin.js")) $projected
    Assert (-not $projected.Contains('%USERPROFILE%')) 'Placeholder was projected literally'
    [IO.File]::WriteAllText($variant, $variantText, [Text.UTF8Encoding]::new($false))
    Write-Settings $relayText
  }
  Case 'relay lane switch projects a repo-external variant without printing or journalling values' {
    $relayVariant = Join-Path $profileRoot 'relay-variant.json'
    $relaySource = '{"env":{"ANTHROPIC_BASE_URL":"https://relay-fixture.invalid/anthropic","ANTHROPIC_AUTH_TOKEN":"secret-fixture"},"permissions":{"defaultMode":"bypassPermissions"}}'
    [IO.File]::WriteAllText($relayVariant, $relaySource, [Text.UTF8Encoding]::new($false))
    Write-Settings $variantText
    $before = Hash $settings; $journalBefore = Hash $journal
    $r = Lane @('-ToRelay','-RelayVariant',$relayVariant)
    Assert ($r.Code -eq 0 -and $r.Text.Contains('PREVIEW') -and $r.Text.Contains('switch-lane-to-relay') -and $r.Text.Contains('full-file-replacement=true')) $r.Text
    Assert (-not $r.Text.Contains('secret-fixture') -and -not $r.Text.Contains('relay-fixture.invalid')) 'Relay preview leaked a value'
    Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Relay preview wrote data'
    $backupsBefore = @(Get-ChildItem $profileRoot -Filter '*.bak-claude-lane-*').Count
    $r = Lane @('-ToRelay','-RelayVariant',$relayVariant,'-Apply')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('APPLIED')) $r.Text
    Assert ((Hash $settings) -eq (Hash $relayVariant)) 'Settings differ from the relay variant bytes'
    Assert (@(Get-ChildItem $profileRoot -Filter '*.bak-claude-lane-*').Count -eq ($backupsBefore + 1)) 'Relay switch created no raw backup'
    $journalText = Get-Content -Raw -LiteralPath $journal
    Assert ($journalText.Contains('switch-lane-to-relay') -and $journalText.Contains('applied-readback-verified')) 'Relay journal entry incomplete'
    Assert (-not $journalText.Contains('secret-fixture') -and -not $journalText.Contains('relay-fixture.invalid') -and -not $journalText.Contains($root)) 'Relay journal leaked a value or path'
    $r = Lane @()
    Assert ($r.Code -eq 0 -and $r.Text.Contains('"current_lane":"relay"') -and -not $r.Text.Contains('secret-fixture')) $r.Text
    $journalHash = Hash $journal
    $r = Lane @('-ToRelay','-RelayVariant',$relayVariant,'-Apply')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('NO_CHANGE') -and (Hash $journal) -eq $journalHash) $r.Text
    $r = Lane @('-ToOfficial','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    $r = Lane @('-ToRelay','-RelayVariant',$relayVariant,'-Apply')
    Assert ($r.Code -eq 0 -and (Hash $settings) -eq (Hash $relayVariant)) 'Returning to the relay lane failed'
    Write-Settings $relayText
  }
  Case 'relay lane switch refuses unidentified, credential-helper and hook variants' {
    $relayVariant = Join-Path $profileRoot 'relay-variant.json'
    $relaySource = '{"env":{"ANTHROPIC_BASE_URL":"https://relay-fixture.invalid/anthropic","ANTHROPIC_AUTH_TOKEN":"secret-fixture"}}'
    Write-Settings $variantText
    $before = Hash $settings
    $r = Lane @('-ToRelay')
    Assert ($r.Code -ne 0 -and $r.Text.Contains('-RelayVariant')) $r.Text
    $r = Lane @('-RelayVariant',$relayVariant)
    Assert ($r.Code -ne 0 -and $r.Text.Contains('RelayVariant requires ToRelay')) $r.Text
    foreach ($text in @('{"env":{"KEEP":"value-fixture"}}','{"env":[]}','{"env":"value-fixture"}','{"apiKeyHelper":"fixture-helper","env":{"ANTHROPIC_BASE_URL":"https://relay-fixture.invalid/anthropic","ANTHROPIC_AUTH_TOKEN":"secret-fixture"}}','{"env":{"ANTHROPIC_BASE_URL":"https://relay-fixture.invalid/anthropic","ANTHROPIC_AUTH_TOKEN":"secret-fixture"},"hooks":{"SessionStart":[]}}')) {
      [IO.File]::WriteAllText($relayVariant, $text, [Text.UTF8Encoding]::new($false))
      $r = Lane @('-ToRelay','-RelayVariant',$relayVariant,'-Apply')
      Assert ($r.Code -ne 0 -and -not $r.Text.Contains('secret-fixture')) "Relay variant accepted: $text"
      if ($text.Contains('apiKeyHelper')) { Assert ($r.Text.Contains('credential helper')) 'Helper refusal was masked by an earlier check' }
      if ($text.Contains('SessionStart')) { Assert ($r.Text.Contains('declares hooks')) 'Hook refusal was masked by an earlier check' }
      Assert ((Hash $settings) -eq $before) "Relay variant replaced settings: $text"
    }
    [IO.File]::WriteAllText($relayVariant, $relaySource, [Text.UTF8Encoding]::new($false))
    Write-Settings '{"env":{"KEEP":"value-fixture"}}'
    $custom = Hash $settings
    $r = Lane @('-ToRelay','-RelayVariant',$relayVariant,'-Apply')
    Assert ($r.Code -ne 0 -and $r.Text.Contains('neither the official variant nor the relay form')) $r.Text
    Assert ((Hash $settings) -eq $custom) 'Custom settings were replaced by the relay variant'
    Write-Settings $variantText
    $r = Lane @('-ToRelay','-RelayVariant',(Join-Path $profileRoot 'absent-relay-variant.json'),'-Apply')
    Assert ($r.Code -ne 0 -and (Hash $settings) -eq $before) 'Missing relay variant was accepted'
    Write-Settings $relayText
  }
  Case 'relay requires immediate gateway bearer auth and refuses subscription or ambiguous credentials' {
    Write-Settings $variantText
    $before = Hash $settings; $journalBefore = Hash $journal
    $relayVariant = Join-Path $profileRoot 'relay-credential-fixture.json'
    foreach ($envMap in @(
      @{ANTHROPIC_BASE_URL='https://relay-fixture.invalid'},
      @{ANTHROPIC_BASE_URL='https://relay-fixture.invalid';ANTHROPIC_AUTH_TOKEN=' '},
      @{ANTHROPIC_BASE_URL='https://relay-fixture.invalid';ANTHROPIC_AUTH_TOKEN=@('secret-fixture')},
      @{ANTHROPIC_BASE_URL='https://relay-fixture.invalid';ANTHROPIC_API_KEY='secret-fixture'},
      @{ANTHROPIC_BASE_URL='https://relay-fixture.invalid';ANTHROPIC_AUTH_TOKEN='secret-fixture';CLAUDE_CODE_OAUTH_TOKEN='secret-fixture'},
      @{ANTHROPIC_BASE_URL='https://relay-fixture.invalid';ANTHROPIC_AUTH_TOKEN='sk-ant-oat-fixture'},
      @{ANTHROPIC_BASE_URL='https://relay-fixture.invalid';ANTHROPIC_AUTH_TOKEN='secret-fixture';ANTHROPIC_API_KEY='secret-fixture'}
    )) {
      [IO.File]::WriteAllText($relayVariant, (@{env=$envMap} | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
      $r = Lane @('-ToRelay','-RelayVariant',$relayVariant,'-Apply')
      Assert ($r.Code -ne 0 -and -not $r.Text.Contains('secret-fixture') -and -not $r.Text.Contains('sk-ant-oat-fixture')) 'Unsafe relay credential accepted or printed'
      Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Rejected relay changed settings or journal'
    }
    Write-Settings $relayText
  }
  Case 'relay endpoints reject invalid or cleartext remote URLs before any write' {
    Write-Settings $variantText
    $before=Hash $settings; $journalBefore=Hash $journal
    $source=Join-Path $profileRoot 'endpoint-fixture.json'
    foreach ($endpoint in @('', ' ', @('https://relay-fixture.invalid'), 'relative/path', 'ftp://relay-fixture.invalid', 'http://relay-fixture.invalid', 'https://private-user:private-secret@relay-fixture.invalid', 'https://relay-fixture.invalid/#private-secret')) {
      [IO.File]::WriteAllText($source,(@{env=@{ANTHROPIC_BASE_URL=$endpoint;ANTHROPIC_AUTH_TOKEN='private-bearer-fixture'}} | ConvertTo-Json -Depth 10))
      foreach ($options in @(@('-ToRelay','-RelayVariant',$source),@('-ToRelay','-RelayVariant',$source,'-Apply'))) {
        $r=Lane $options
        Assert ($r.Code -ne 0 -and -not $r.Text.Contains('private-secret') -and -not $r.Text.Contains('private-bearer-fixture')) 'Unsafe endpoint accepted or printed'
        Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Rejected endpoint wrote data'
      }
    }
    foreach ($endpoint in @('https://relay-fixture.invalid/anthropic','http://127.0.0.1:1234','http://[::1]:1234','http://localhost:1234')) {
      [IO.File]::WriteAllText($source,(@{env=@{ANTHROPIC_BASE_URL=$endpoint;ANTHROPIC_AUTH_TOKEN='private-bearer-fixture'}} | ConvertTo-Json -Depth 10))
      $r=Lane @('-ToRelay','-RelayVariant',$source)
      Assert ($r.Code -eq 0 -and $r.Text.Contains('PREVIEW')) $r.Text
      Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Endpoint preview wrote data'
    }
    Write-Settings $relayText
  }
  Case 'relay refuses provider and OAuth overrides even when their values are empty' {
    Write-Settings $variantText
    $before=Hash $settings; $journalBefore=Hash $journal
    $source=Join-Path $profileRoot 'provider-fixture.json'
    foreach ($name in @('CLAUDE_CONFIG_DIR','CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_VERTEX','CLAUDE_CODE_USE_FOUNDRY','CLAUDE_CODE_USE_ANTHROPIC_AWS','CLAUDE_CODE_USE_MANTLE','CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST','CLAUDE_CODE_OAUTH_REFRESH_TOKEN','CLAUDE_CODE_OAUTH_SCOPES')) {
      $map=@{ANTHROPIC_BASE_URL='https://relay-fixture.invalid';ANTHROPIC_AUTH_TOKEN='private-bearer-fixture'}
      $map[$name]=''
      [IO.File]::WriteAllText($source,(@{env=$map} | ConvertTo-Json -Depth 10))
      $r=Lane @('-ToRelay','-RelayVariant',$source,'-Apply')
      Assert ($r.Code -ne 0 -and $r.Text.Contains('conflicting') -and -not $r.Text.Contains('private-bearer-fixture')) $r.Text
      Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Rejected override wrote data'
    }
    Write-Settings $relayText
  }
  Case 'relay source cannot be stored in the repository or reached through a directory junction' {
    $fakeRepo = Join-Path $root 'relay-repo'
    $null = New-Item -ItemType Directory -Path $fakeRepo
    Copy-Item -LiteralPath (Join-Path $repo 'Set-ClaudeLane.ps1') -Destination $fakeRepo
    $source = Join-Path $fakeRepo 'relay.json'
    [IO.File]::WriteAllText($source, $relayText, [Text.UTF8Encoding]::new($false))
    $junction = Join-Path $root 'outside-repo-alias'
    $null = New-Item -ItemType Junction -Path $junction -Target $fakeRepo
    try {
      Write-Settings $variantText
      $before=Hash $settings; $journalBefore=Hash $journal
      foreach ($candidate in @($source, (Join-Path $junction 'relay.json'))) {
        $r = Run (Join-Path $fakeRepo 'Set-ClaudeLane.ps1') @('-SettingsPath',$settings,'-VariantPath',$variant,'-JournalPath',$journal,'-ToRelay','-RelayVariant',$candidate,'-Apply')
        Assert ($r.Code -ne 0 -and $r.Text.Contains('outside this repository')) $r.Text
        Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Repo source changed machine data'
      }
    } finally { Remove-Item -LiteralPath $junction -Force }
    Write-Settings $relayText
  }
  Case 'permission repair preserves custom settings and rules with preview, raw backup, idempotence and protected rollback' {
    $customText = '{"customTimestamp":"2030-01-02T03:04:05.000Z","nested":{"items":[null,[],["2030-01-02T03:04:05.1234567+08:00"],false,1]},"model":"custom-fixture","modelSettings":{"keep":true},"env":{"KEEP":"secret-fixture"},"permissions":{"defaultMode":"acceptEdits","deny":["Read(**/custom-private/**)"],"ask":["Bash(git push:*)"]},"hooks":{"Stop":[]}}'
    Write-Settings $customText
    $before=Hash $settings; $journalBefore=Hash $journal
    $backups=@(Get-ChildItem $profileRoot -Filter '*.bak-claude-env-*' | ForEach-Object FullName)
    $r=Install @('-RepairPermissions')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('PREVIEW') -and -not $r.Text.Contains('secret-fixture')) $r.Text
    Assert ((Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Permission preview wrote files'
    $r=Install @('-RepairPermissions','-Apply')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('APPLIED')) $r.Text
    $document=[Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($settings))
    try {
      Assert ($document.RootElement.GetProperty('customTimestamp').GetString() -ceq '2030-01-02T03:04:05.000Z') 'Unrelated timestamp changed'
      $items=$document.RootElement.GetProperty('nested').GetProperty('items')
      Assert ($items.GetArrayLength() -eq 5 -and $items[0].ValueKind -eq 'Null' -and $items[1].GetArrayLength() -eq 0 -and $items[2][0].GetString() -ceq '2030-01-02T03:04:05.1234567+08:00' -and -not $items[3].GetBoolean() -and $items[4].GetInt32() -eq 1) 'Nested JSON types or strings changed'
    } finally { $document.Dispose() }
    $newBackup=@(Get-ChildItem $profileRoot -Filter '*.bak-claude-env-*' | Where-Object FullName -NotIn $backups)
    Assert ($newBackup.Count -eq 1 -and (Hash $newBackup[0].FullName) -eq $before) 'Permission repair raw backup differs'
    $actual=Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json -AsHashtable
    $expected=$customText | ConvertFrom-Json -AsHashtable
    $profilePath=[IO.Path]::GetFullPath($profileRoot).Replace('\','/')
    $policy=((Get-Content -Raw -LiteralPath (Join-Path $repo 'settings.official-anthropic.json')).Replace('%USERPROFILE%',$profilePath) | ConvertFrom-Json -AsHashtable).permissions
    Assert ($actual.permissions.defaultMode -eq 'bypassPermissions' -and -not $actual.permissions.Contains('disableAutoMode') -and -not $actual.permissions.Contains('disableBypassPermissionsMode')) 'Permission boundary not repaired'
    Assert ($actual.permissions.deny -contains 'Read(**/custom-private/**)') 'Custom deny lost'
    foreach($rule in $policy.deny) { Assert ($actual.permissions.deny -ccontains $rule) 'Template deny missing' }
    Assert ($actual.permissions.deny -ccontains "Read($profilePath/.claude/settings.json)" -and -not ($actual.permissions.deny -match '%USERPROFILE%')) 'Permission repair left unexpanded user paths'
    foreach($key in @('defaultMode','disableAutoMode','disableBypassPermissionsMode','deny')) { $actual.permissions.Remove($key);$expected.permissions.Remove($key) }
    Assert (($actual | ConvertTo-Json -Depth 30 -Compress) -ceq ($expected | ConvertTo-Json -Depth 30 -Compress)) 'Unrelated custom settings changed'
    $after=Hash $settings; $journalAfter=Hash $journal
    $r=Install @('-RepairPermissions','-Apply')
    Assert ($r.Code -eq 0 -and $r.Text.Contains('NO_CHANGE') -and (Hash $settings) -eq $after -and (Hash $journal) -eq $journalAfter) 'Permission repair is not idempotent'
    $r=Install @('-RollbackBackup',$newBackup[0].FullName,'-ExpectedCurrentHash',('0'*64),'-Apply')
    Assert ($r.Code -ne 0 -and (Hash $settings) -eq $after) 'Permission rollback ignored drift'
    $r=Install @('-RollbackBackup',$newBackup[0].FullName,'-ExpectedCurrentHash',$after,'-Apply')
    Assert ($r.Code -eq 0 -and (Hash $settings) -eq $before) 'Permission rollback did not restore original bytes'
    foreach($text in @('{"permissions":[]}','{"permissions":{"deny":"Read(*)"}}','{"permissions":{"deny":[null]}}','{"permissions":{"deny":[12]}}')) {
      Write-Settings $text; $before=Hash $settings; $journalBefore=Hash $journal
      $r=Install @('-RepairPermissions','-Apply')
      Assert ($r.Code -ne 0 -and (Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Malformed permissions were changed'
    }
    Write-Settings '{"label":"keep"}'
    $r=Install @('-RepairPermissions','-Apply')
    Assert ($r.Code -eq 0) $r.Text
    $j=Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json -AsHashtable
    Assert ($j.label -eq 'keep' -and $j.permissions.defaultMode -eq 'bypassPermissions') 'Missing permissions were not initialized to the template baseline'
    Assert ($j.permissions.deny -ccontains "Read($profilePath/.claude/.credentials.json)") 'Missing permissions did not receive projected credential protection'
    $before=Hash $settings; $journalBefore=Hash $journal
    $r=Run (Join-Path $repo 'install.ps1') @('-SettingsPath',$settings,'-JournalPath',$journal,'-RepairPermissions','-Apply') @{USERPROFILE=''}
    Assert ($r.Code -ne 0 -and $r.Text.Contains('cannot project permission paths') -and (Hash $settings) -eq $before -and (Hash $journal) -eq $journalBefore) 'Absent profile was not rejected before writes'
  }
  Case 'tracked files carry no raw infrastructure identifiers' {
    # Regression barrier for the 2026-10-15 leaks: a real egress IP, hostname,
    # user path, proxy provider or endpoint domain must never reach a tracked
    # file, because a public remote mirrors it.
    Push-Location $repo
    try {
      $documentedOnly = @('^127\.', '^10\.', '^192\.168\.', '^172\.(1[6-9]|2\d|3[01])\.', '^192\.0\.2\.', '^198\.51\.100\.', '^203\.0\.113\.')
      # Built from pieces so this barrier file does not contain the literals itself.
      $bannedLiterals = @('b' + 'wg', 'band' + 'wagon', 'fq.sci' + 'man.top')
      $found = [Collections.Generic.List[string]]::new()
      foreach ($relative in @(git ls-files)) {
        $text = Get-Content -LiteralPath (Join-Path $repo $relative) -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($match in [regex]::Matches($text, '(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])')) {
          if (@($documentedOnly | Where-Object { $match.Value -match $_ }).Count -eq 0) { $found.Add("$relative ip=$($match.Value)") }
        }
        # Either separator: a real forward-slash user path was published once, which a
        # backslash-only pattern missed.
        if ($text -match '(?i)(?:[A-Za-z]:)?[\\/]Users[\\/](?!<USER>)') { $found.Add("$relative user-path") }
        if ($text.Contains([Environment]::MachineName)) { $found.Add("$relative hostname") }
        foreach ($literal in $bannedLiterals) {
          if ($text.IndexOf($literal, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found.Add("$relative provider=$literal") }
        }
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
