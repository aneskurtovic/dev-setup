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
    function Get-Command { [pscustomobject]@{Source='fake-winget.exe'} }
    function Update-ProcessPath {}
    function Get-CorePackageState { param($Package) [pscustomobject]@{ Name=$Package.name; Status=$script:health } }
    function Invoke-SetupProcess { param($File,$Arguments,$TimeoutSeconds) $script:lastArgs=$Arguments; [pscustomobject]@{ExitCode=$script:code;Output='';Error=''} }
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
    @($installSafe,$updateExplicit,$failed,$verification,$restart,$noUpdate)
}
Assert $results[0] 'Provider installs an exact package without upgrade or reboot'
Assert $results[1] 'Updates target one explicit package'
Assert $results[2] 'Nonzero installer exit is a failure'
Assert $results[3] 'Installer success still requires a passing health check'
Assert $results[4] 'Reboot-required result is reported without claiming readiness'
Assert $results[5] 'No applicable upgrade succeeds after health verification'
Remove-Module DevSetup
Import-Module "$repo/powershell/DevSetup.psm1" -Force
$result = Invoke-SetupProcess (Get-Command pwsh.exe).Source @('-NoProfile','-Command','[Console]::Write("ok"); exit 7') 10
Assert ($result.ExitCode -eq 7 -and $result.Output -eq 'ok') 'Process wrapper captures real stdout and exit status'
$batchPath = Join-Path $scratch 'version tool.cmd'
[IO.File]::WriteAllText($batchPath, "@echo off`r`necho tool 2.3.4`r`n")
$batchResult = Invoke-SetupProcess $batchPath @('--version') 10
Assert ($batchResult.ExitCode -eq 0 -and $batchResult.Output -match 'tool 2.3.4') 'Process wrapper runs batch launchers from paths with spaces'
Assert-Throws { Invoke-SetupProcess (Get-Command pwsh.exe).Source @('-NoProfile','-Command','Start-Sleep 10') 1 } 'Timed out' 'Hung commands time out'

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
