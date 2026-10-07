#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dev-setup-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$script:passed = 0
function Assert($Condition, [string]$Message) {
    if (!$Condition) { throw "FAIL: $Message" }
    $script:passed++; Write-Host "PASS: $Message"
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern, [string]$Message) {
    $errorText = ''
    try { & $Body } catch { $errorText = $_.Exception.Message }
    Assert ($errorText -match $Pattern) $Message
}
. "$repo/powershell/ConfigEditing.ps1"
. "$repo/powershell/TerminalSettings.ps1"
$expectedTerminal = '{"defaultProfile":"keep","actions":[{"id":"copy","command":"copy"},{"id":"paste","command":"paste"}],"keybindings":[{"keys":"ctrl+c","id":"copy"},{"keys":"ctrl+v","id":"paste"}],"profiles":{"list":[]}}'
$generatedTerminal = $expectedTerminal | ConvertFrom-Json -AsHashtable
$generatedTerminal.actions = @($generatedTerminal.actions[1],$generatedTerminal.actions[0])
$generatedTerminal.keybindings = @($generatedTerminal.keybindings[1],$generatedTerminal.keybindings[0])
$generatedTerminal.profiles.list = @(@{guid='{d6fccd97-1f58-5233-bfa2-c0c69f2de059}';name='Ubuntu';source='Microsoft.WSL';hidden=$false})
$generatedText = $generatedTerminal | ConvertTo-Json -Depth 10
Assert (Test-TerminalSettingsEquivalent $expectedTerminal $generatedText) 'Terminal action and binding reordering plus known Ubuntu registration are harmless'
$generatedTerminal.copyOnSelect = $true
Assert (!(Test-TerminalSettingsEquivalent $expectedTerminal ($generatedTerminal | ConvertTo-Json -Depth 10))) 'Terminal comparison protects unrelated preferences'
$null = $generatedTerminal.Remove('copyOnSelect')
$generatedTerminal.profiles.list[0].commandline = 'unexpected command'
Assert (!(Test-TerminalSettingsEquivalent $expectedTerminal ($generatedTerminal | ConvertTo-Json -Depth 10))) 'Generated profile recognition refuses custom command lines'
$null = $generatedTerminal.profiles.list[0].Remove('commandline')
$generatedTerminal.keybindings += @{keys='ctrl+c';id='paste'}
Assert (!(Test-TerminalSettingsEquivalent $expectedTerminal ($generatedTerminal | ConvertTo-Json -Depth 10))) 'Duplicate shortcut chords are not treated as reorderable'
$inputJson = @'
{
  // Unicode č and nested same-name key must survive
  "custom": { "defaultProfile": "keep", "items": [1, {"x":2}] },
  "defaultProfile": "old",
}
'@
$edited = Set-JsonRootValue $inputJson 'defaultProfile' 'new'
Assert ($edited -ceq $inputJson.Replace('"defaultProfile": "old"','"defaultProfile": "new"')) 'JSONC modifies only the requested root value'
$inserted = Set-JsonRootValue '{ /* comment */ }' 'defaultProfile' 'new'
Assert (($inserted | ConvertFrom-Json).defaultProfile -eq 'new' -and $inserted.Contains('/* comment */')) 'JSONC supports an empty commented object'
Assert-Throws { Set-JsonRootValue '{"x":1,"x":2}' 'x' 3 } 'Duplicate' 'Duplicate root keys are rejected'
$nested = Set-JsonRootValue '{"x":{"y":[1,2]},"keep":true}' 'x' @{z=1}
Assert (($nested | ConvertFrom-Json).keep -eq $true) 'Object replacement preserves the next property'

$argsForInstall = @{
    InstallRoot=(Join-Path $scratch 'runtime'); ProfilePaths=@((Join-Path $scratch 'profile.ps1'))
    TerminalSettingsPath=(Join-Path $scratch 'settings.json'); FragmentPath=(Join-Path $scratch 'fragment.json')
    CodexConfigPath=(Join-Path $scratch 'codex/config.toml'); ClaudeStatuslinePath=(Join-Path $scratch 'claude/statusline.js')
    ClaudeSettingsPath=(Join-Path $scratch 'claude/settings.json')
}
$preview = @(& "$repo/Install.ps1" @argsForInstall -ConfigureDisplay -Preview)
Assert (!(Test-Path $argsForInstall.InstallRoot) -and !(Test-Path $argsForInstall.TerminalSettingsPath)) 'Fresh preview creates no config or runtime files'
Assert (@($preview | Where-Object Action -EQ 'Write').Count -gt 0) 'Fresh preview reports planned writes'
& "$repo/Install.ps1" @argsForInstall -ConfigureDisplay
$settings = Get-Content $argsForInstall.TerminalSettingsPath -Raw | ConvertFrom-Json
Assert ($settings.defaultProfile -and @($settings.keybindings | Where-Object keys -EQ 'ctrl+w').Count -eq 1) 'Fresh display creates default profile and Ctrl+W binding'
Assert ((Get-Content $argsForInstall.CodexConfigPath -Raw) -match '\[tui\]\s+status_line') 'Fresh display creates Codex tui configuration'
$claude = Get-Content $argsForInstall.ClaudeSettingsPath -Raw | ConvertFrom-Json
Assert ($claude.statusLine.type -eq 'command' -and $claude.statusLine.command.Contains('statusline.js')) 'Fresh display wires Claude renderer'
$second = @(& "$repo/Install.ps1" @argsForInstall -ConfigureDisplay -Preview)
Assert (@($second | Where-Object Action -NE 'Unchanged').Count -eq 0) 'Second display plan is a no-op'
$serializedSettings = Get-Content $argsForInstall.TerminalSettingsPath -Raw | ConvertFrom-Json -AsHashtable
$serializedSettings.keybindings = @($serializedSettings.keybindings | Sort-Object keys -Descending)
$serializedSettings | ConvertTo-Json -Depth 10 | Set-Content $argsForInstall.TerminalSettingsPath
$serializedPlan = @(& "$repo/Install.ps1" @argsForInstall -ConfigureDisplay -Preview)
Assert (@($serializedPlan | Where-Object Action -NE 'Unchanged').Count -eq 0) 'Display reinstall accepts Terminal serialization and leaves its bytes alone'
$argumentJson = $argsForInstall | ConvertTo-Json -Compress
$payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argumentJson))
$code = "`$a=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json -AsHashtable; `$p=@(& '$($repo.Replace("'","''"))/Install.ps1' @a -ConfigureDisplay -Preview); if (@(`$p | Where-Object Action -NE 'Unchanged').Count) { exit 1 }"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
& pwsh -NoProfile -EncodedCommand $encoded
Assert ($LASTEXITCODE -eq 0) 'Separate PowerShell process also reports a no-op'
& "$repo/Uninstall.ps1" -InstallRoot $argsForInstall.InstallRoot
Assert (!(Test-Path $argsForInstall.TerminalSettingsPath) -and !(Test-Path $argsForInstall.ClaudeSettingsPath)) 'Fresh rollback removes newly created settings'

# Provider tests use module-local fakes. They cannot invoke a package installer.
Import-Module "$repo/powershell/DevSetup.psm1" -Force
$packages = @(Read-CoreManifest "$repo/manifests/core.json")
Assert ($packages.Count -eq 4) 'Core manifest contains four packages'
$developerPackages = @(Read-CoreManifest "$repo/manifests/developer.json")
Assert ($developerPackages.Count -eq 19 -and @($developerPackages.name | Where-Object { $_ -in @('go','visualstudio','ssms','pgadmin') }).Count -eq 0) 'Developer manifest includes selected apps and exclusions'
$module = Get-Module DevSetup
$results = & $module {
    function Get-Command { [pscustomobject]@{Source='fake-winget.exe'}; [pscustomobject]@{Source='second-winget.exe'} }
    function Update-ProcessPath {}
    function Get-CorePackageState { param($Package) [pscustomobject]@{ Name=$Package.name; Status=$script:health } }
    function Invoke-SetupProcess { param($File,$Arguments,$TimeoutSeconds) $script:lastFile=$File; $script:lastArgs=$Arguments; [pscustomobject]@{ExitCode=$script:code;Output='';Error=''} }
    $p = [pscustomobject]@{name='git';id='Git.Git';source='winget'}
    $script:code=0; $script:health='Ready'
    $null=Install-CorePackage $p
    $installSafe = $script:lastArgs -contains '--no-upgrade' -and $script:lastArgs -contains '--exact' -and $script:lastArgs -notcontains '--allow-reboot'
    $null=Install-CorePackage $p -Update
    $updateExplicit = $script:lastArgs[0] -eq 'upgrade' -and $script:lastArgs -notcontains '--all'
    $script:code=42; $failed=$false
    try { $null=Install-CorePackage $p } catch { $failed=$_.Exception.Message -match 'exited 42' }
    $script:code=0; $script:health='Missing'; $verification=$false
    try { $null=Install-CorePackage $p } catch { $verification=$_.Exception.Message -match 'after installation' }
    $script:code=[int]0x8A150109; $restart=(Install-CorePackage $p).Status -eq 'NeedsRestart'
    $script:code=[int]0x8A15002B; $script:health='Ready'; $noUpdate=(Install-CorePackage $p -Update).Status -eq 'Ready'
    $oneExecutable = $script:lastFile -eq 'fake-winget.exe'
    @($installSafe,$updateExplicit,$failed,$verification,$restart,$noUpdate,$oneExecutable)
}
Assert $results[0] 'Provider installs an exact package without upgrade or reboot'
Assert $results[1] 'Updates target one explicit package'
Assert $results[2] 'Nonzero installer exit is a failure'
Assert $results[3] 'Installer success still requires a passing health check'
Assert $results[4] 'Reboot-required result is reported without claiming readiness'
Assert $results[5] 'No applicable upgrade succeeds after health verification'
Assert $results[6] 'Package installation selects one executable when PATH contains duplicates'
Remove-Module DevSetup
Import-Module "$repo/powershell/DevSetup.psm1" -Force
$module = Get-Module DevSetup
$wslResults = & $module {
    function Get-Command { [pscustomobject]@{Source='first-wsl.exe'}; [pscustomobject]@{Source='second-wsl.exe'} }
    function Invoke-SetupProcess { param($File,$Arguments,$TimeoutSeconds) $script:lastFile=$File; [pscustomobject]@{ExitCode=$script:code;Output='installer detail';Error=''} }
    function Get-CorePackageState { param($Package) [pscustomobject]@{Name=$Package.name;Status=$script:health} }
    $p = [pscustomobject]@{name='wsl';source='windows'}
    $script:code=0; $script:health='Ready'
    $ready = (Install-CorePackage $p).Status -eq 'Ready' -and $script:lastFile -eq 'first-wsl.exe'
    $script:health='Missing'
    $notReady = (Install-CorePackage $p).Status -eq 'NeedsAttention'
    $script:code=3010
    $restart = (Install-CorePackage $p).Status -eq 'NeedsRestart'
    $script:code=42; $failed=$false
    try { $null=Install-CorePackage $p } catch { $failed=$_.Exception.Message -match 'exited 42.*installer detail' }
    @($ready,$notReady,$restart,$failed)
}
Assert $wslResults[0] 'WSL installation selects one executable and verifies readiness without an unnecessary restart'
Assert $wslResults[1] 'Unregistered Ubuntu is not reported ready after installation'
Assert $wslResults[2] 'WSL restart-required exit is accepted without claiming readiness'
Assert $wslResults[3] 'WSL failures retain installer diagnostics'
Remove-Module DevSetup
Import-Module "$repo/powershell/DevSetup.psm1" -Force
$module = Get-Module DevSetup
$lookupResults = & $module {
    function Get-Command {
        [pscustomobject]@{Source='C:\Users\test\.codex\bin\rg.exe'}
        if ($script:standalone) { [pscustomobject]@{Source='C:\Tools\rg.exe'} }
    }
    function Invoke-SetupProcess { param($File,$Arguments,$TimeoutSeconds) $script:lastFile=$File; [pscustomobject]@{ExitCode=0;Output=$script:versionText;Error=''} }
    $p = [pscustomobject]@{name='ripgrep';source='winget';id='BurntSushi.ripgrep.MSVC';command='rg.exe';minimumVersion='14.0.0';versionArguments=@('--version')}
    $script:standalone=$true; $script:versionText='ripgrep 15.2.0'
    $ready = (Get-CorePackageState $p).Status -eq 'Ready' -and $script:lastFile -eq 'C:\Tools\rg.exe'
    $script:standalone=$false
    $missing = (Get-CorePackageState $p).Status -eq 'Missing'
    $script:standalone=$true; $script:versionText='unreadable version'
    $unreadable = (Get-CorePackageState $p).Detail -match 'Could not determine version'
    @($ready,$missing,$unreadable)
}
Assert $lookupResults[0] 'Standalone ripgrep is found even when a bundled copy appears first on PATH'
Assert $lookupResults[1] 'A bundled ripgrep copy does not satisfy the standalone dependency'
Assert $lookupResults[2] 'Unreadable versions produce a useful diagnostic'
Remove-Module DevSetup
Import-Module "$repo/powershell/DevSetup.psm1" -Force
$pwshExecutable = (Get-Command pwsh.exe -CommandType Application | Select-Object -First 1).Source
$result = Invoke-SetupProcess $pwshExecutable @('-NoProfile','-Command','[Console]::Write("ok"); exit 7') 10
Assert ($result.ExitCode -eq 7 -and $result.Output -eq 'ok') 'Process wrapper captures real stdout and exit status'
$batchPath = Join-Path $scratch 'version tool.cmd'
[IO.File]::WriteAllText($batchPath, "@echo off`r`necho tool 2.3.4`r`n")
$batchResult = Invoke-SetupProcess $batchPath @('--version') 10
Assert ($batchResult.ExitCode -eq 0 -and $batchResult.Output -match 'tool 2.3.4') 'Process wrapper runs batch launchers from paths with spaces'
Assert-Throws { Invoke-SetupProcess $pwshExecutable @('-NoProfile','-Command','Start-Sleep 10') 1 } 'Timed out' 'Hung commands time out'

$parseErrors = @()
foreach ($file in Get-ChildItem $repo -Recurse -Include *.ps1,*.psm1 | Where-Object FullName -NotMatch '[\\/]test-results[\\/]') {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    $parseErrors += $errors
}
Assert ($parseErrors.Count -eq 0) 'All PowerShell sources parse'
$bootstrapPath = "$repo/bootstrap.ps1".Replace("'","''")
$legacyCode = "`$e=`$null; `$t=`$null; [void][Management.Automation.Language.Parser]::ParseFile('$bootstrapPath',[ref]`$t,[ref]`$e); if (`$e.Count) { exit 1 }"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($legacyCode))
& "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -EncodedCommand $encoded
Assert ($LASTEXITCODE -eq 0) 'Bootstrap parses in Windows PowerShell 5.1'
Write-Host "All $script:passed setup checks passed. Fixtures retained: $scratch"
