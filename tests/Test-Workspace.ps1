#requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('terminal-dev-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$script:passed = 0
function Assert($Condition, [string] $Message) {
    if (!$Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Assert-Throws([scriptblock] $Body, [string] $Pattern, [string] $Message) {
    $caught = $null
    try { & $Body } catch { $caught = $_.Exception.Message }
    Assert ($caught -and $caught -match $Pattern) $Message
}
function Write-Json([string] $Path, $Value) { $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8 }

try {
    $projectRoot = Join-Path $scratch "My Projects (demo) O'Brien - č"
    $nested = Join-Path $projectRoot 'src/nested'
    $plain = Join-Path $scratch 'Not a repository'
    $null = New-Item -ItemType Directory -Path $nested,$plain
    & git init --quiet $projectRoot
    if ($LASTEXITCODE) { throw 'git init failed' }
    $registry = Join-Path $scratch 'projects.json'
    $registryData = @{ schemaVersion = 1; projects = @(
        @{ command = 'workspace-fixture'; displayName = 'Fixture'; path = $projectRoot; enabled = $true; replaceNavigation = $true; aliases = @('fixture-alias') },
        @{ command = 'pending-fixture'; displayName = 'Pending'; path = $plain; enabled = $false; replaceNavigation = $false; aliases = @() }
    ) }
    Write-Json $registry $registryData
    function global:workspace-fixturecc { 'old shortcut' }
    function global:fixture-aliascc { 'old alias shortcut' }
    $modulePath = Join-Path $repo 'powershell/TerminalWorkspace.psm1'
    Import-Module $modulePath -ArgumentList $registry -Force -DisableNameChecking
    Assert ((workspace-fixturecc -Preview).Action -eq 'claude') 'Opt-in shortcut replaces a legacy project function'
    Assert ((fixture-aliascc -Preview).Action -eq 'claude') 'Opt-in alias shortcut replaces a legacy alias function'
    Assert ((Resolve-AiProjectRoot $nested) -eq $projectRoot) 'Nested Git directory resolves to root, including Unicode and punctuation'
    Assert ((Resolve-AiProjectRoot $plain) -eq $plain) 'Non-Git directory falls back to current folder'
    $previousPath = $env:PATH
    try { $env:PATH = ''; Assert ((Resolve-AiProjectRoot $nested) -eq $nested) 'Missing Git falls back to current folder' }
    finally { $env:PATH = $previousPath }
    $preview = ai-workspace -Path $nested -Preview
    Assert ($preview.Root -eq $projectRoot) 'Generic workspace uses Git root'
    Assert (($preview.Arguments | Where-Object { $_ -eq 'new-tab' }).Count -eq 1) 'Workspace creates exactly one tab'
    Assert (@($preview.Arguments | Where-Object { $_ -eq 'split-pane' }).Count -eq 2) 'Workspace creates exactly three panes'
    Assert (($preview.Arguments[0..3] -join ' ') -eq '-w -1 --maximized new-tab') 'Workspace requests a new maximized window'
    Assert (($preview.Arguments -join ' ') -match 'split-pane -V -s 0.5.*split-pane -H -s 0.5') 'Correct split directions and proportions'
    Assert (($preview.Arguments[-3..-1] -join ' ') -eq '; move-focus first') 'Initial focus returns to Claude'
    Assert (($preview.Arguments -join ' ').Contains($preview.DisplayName + ' - Claude')) 'Terminal title puts the project before the pane role'
    $resumePreview = ai-workspace-resume -Path $nested -Preview
    Assert (@($resumePreview.Arguments | Where-Object { $_ -eq 'split-pane' }).Count -eq 2) 'Resume workspace keeps the three-pane layout'
    $resumeModes = @()
    for ($i=0; $i -lt $resumePreview.Arguments.Count; $i++) {
        if ($resumePreview.Arguments[$i] -eq '-EncodedCommand') {
            $code = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($resumePreview.Arguments[$i+1]))
            $match = [regex]::Match($code, "-Payload '([^']+)'")
            $pane = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
            $resumeModes += $pane.sessionMode
        }
    }
    Assert (($resumeModes -join ',') -eq 'resume,resume,resume') 'Resume mode reaches both agent panes'
    $agentsPreview = ai-workspace-agents -Path $nested -Preview
    $agentModes = @()
    for ($i=0; $i -lt $agentsPreview.Arguments.Count; $i++) {
        if ($agentsPreview.Arguments[$i] -eq '-EncodedCommand') {
            $code = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($agentsPreview.Arguments[$i+1]))
            $match = [regex]::Match($code, "-Payload '([^']+)'")
            $pane = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
            $agentModes += $pane.sessionMode
        }
    }
    Assert (($agentModes -join ',') -eq 'agents,agents,agents') 'Agent-browser mode reaches both agent panes'
    $fixtureBin = Join-Path $scratch 'preview-bin'
    $null = New-Item -ItemType Directory -Path $fixtureBin
    foreach ($name in @('wt.exe','pwsh.exe')) { Copy-Item -LiteralPath "$env:SystemRoot/System32/where.exe" -Destination (Join-Path $fixtureBin $name) }
    $previousPath = $env:PATH
    try {
        $env:PATH = $fixtureBin
        $withoutAgents = ai-workspace -Path $plain -Preview
        Assert ($withoutAgents.Action -eq 'ai-workspace') 'Core workspace preview works without agent CLIs'
    } finally { $env:PATH = $previousPath }
    $payloads = @()
    for ($i = 0; $i -lt $preview.Arguments.Count; $i++) {
        if ($preview.Arguments[$i] -eq '-EncodedCommand') {
            $code = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($preview.Arguments[$i + 1]))
            $match = [regex]::Match($code, "-Payload '([^']+)'")
            $payloads += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
        }
    }
    Assert (($payloads.role -join ',') -eq 'claude,codex,terminal') 'Pane roles have the intended order'
    Assert (@($payloads | Where-Object { $_.root -ne $projectRoot }).Count -eq 0) 'All encoded pane payloads preserve the exact project path'
    Push-Location $plain
    try {
        workspace-fixture
        Assert ((Get-Location).Path -eq $projectRoot) 'Bare dispatcher navigates the current shell'
        foreach ($action in @('codex','claude','terminal','ai-workspace')) {
            Set-Location -LiteralPath $plain
            $launch = fixture-alias $action -Preview
            Assert ($launch.Root -eq $projectRoot -and $launch.Action -eq $action) "Project action $action ignores caller directory"
        }
        Assert ((workspace-fixturecc -Preview).Action -eq 'claude') 'Project cc shortcut opens the Claude profile'
        Assert ((workspace-fixturecx -Preview).Action -eq 'codex') 'Project cx shortcut opens the Codex profile'
        Assert ((fixture-aliascc -Preview).Action -eq 'claude') 'Alias cc shortcut opens the Claude profile'
        Assert ((fixture-aliascx -Preview).Action -eq 'codex') 'Alias cx shortcut opens the Codex profile'
        Assert ((workspace-fixture ai-workspace-resume -Preview).Action -eq 'ai-workspace-resume') 'Project dispatcher opens resume workspace'
        Assert ((workspace-fixture ai-workspace-agents -Preview).Action -eq 'ai-workspace-agents') 'Project dispatcher opens agents workspace'
        Assert-Throws { workspace-fixture wat } 'Unknown.*action' 'Unknown actions are rejected'
        Assert-Throws { Invoke-AiProject pending-fixture terminal } 'registered but disabled' 'Disabled projects cannot be launched through the dispatcher'
        Assert ((workspace-fixture help) -match 'ai-workspace') 'Project help lists available actions'
    } finally { Pop-Location }
    $completion = TabExpansion2 'workspace-fixture cl' 20
    Assert ('claude' -in $completion.CompletionMatches.CompletionText) 'Action tab completion works'

    $scripts = Join-Path $projectRoot 'scripts'
    $null = New-Item -ItemType Directory -Path $scripts
    $preferences = Join-Path $scripts 'terminal-workspace.json'
    Write-Json $preferences @{ schemaVersion=1; displayName='Custom Project'; layout=@{codexFraction=0.7;claudeFraction=0.55} }
    $custom = ai-workspace -Path $projectRoot -Preview
    Assert ($custom.DisplayName -eq 'Custom Project' -and ($custom.Arguments -join ' ') -match 'split-pane -V -s 0.45.*split-pane -H -s 0.3') 'Portable preferences override title and proportions'
    $rootPreferences = Join-Path $projectRoot 'terminal-workspace.json'
    Copy-Item -LiteralPath $preferences -Destination $rootPreferences
    Assert-Throws { ai-workspace -Path $projectRoot -Preview } 'Multiple workspace configuration' 'Ambiguous metadata locations are rejected'
    Remove-Item -LiteralPath $preferences
    Assert ((ai-workspace -Path $projectRoot -Preview).DisplayName -eq 'Custom Project') 'Root-level metadata supports repositories without a scripts directory'
    Move-Item -LiteralPath $rootPreferences -Destination $preferences
    Write-Json $preferences @{ schemaVersion=1; layout=@{codexFraction=1.5} }
    Assert-Throws { ai-workspace -Path $projectRoot -Preview } 'Invalid workspace configuration.*codexFraction' 'Invalid proportions report the configuration file and property'
    Write-Json $preferences @{ schemaVersion=1; startupCommand='arbitrary command' }
    Assert-Throws { ai-workspace -Path $projectRoot -Preview } 'Unknown property' 'Repository metadata cannot inject startup commands'
    Remove-Item -LiteralPath $preferences
    $registryData.projects[0].path = Join-Path $scratch 'missing'
    Write-Json $registry $registryData
    Assert-Throws { workspace-fixture terminal -Preview } 'Configured project path does not exist' 'Missing project paths are reported clearly'
    $registryData.projects[0].path = $projectRoot
    Write-Json $registry $registryData
    $savedPath = $env:PATH
    try { $env:PATH=''; Assert-Throws { workspace-fixture terminal -Preview } "Required command 'wt.exe'" 'Missing Terminal fails before any launch' }
    finally { $env:PATH=$savedPath }

    $shellPayload = @{ root=$projectRoot;displayName='Fixture';role='terminal' } | ConvertTo-Json -Compress
    $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($shellPayload))
    $paneFile = (Join-Path $repo 'powershell/Start-Pane.ps1').Replace("'","''")
    $paneCode = "& '$paneFile' -Payload '$base64'; [Console]::WriteLine((Get-Location).Path)"
    $pane64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($paneCode))
    $output = & pwsh -NoProfile -OutputFormat Text -EncodedCommand $pane64
    Assert ($LASTEXITCODE -eq 0 -and $output[-1] -eq $projectRoot) 'Real pane bootstrap safely enters a path with spaces, apostrophes, parentheses and Unicode'
    $agentBin = Join-Path $scratch 'agent-fixtures'
    $null = New-Item -ItemType Directory -Path $agentBin
    [IO.File]::WriteAllText((Join-Path $agentBin 'codex.cmd'), "@echo off`r`necho CODEX %*`r`n")
    [IO.File]::WriteAllText((Join-Path $agentBin 'claude.cmd'), "@echo off`r`necho CLAUDE %*`r`n")
    $savedAgentPath = $env:PATH
    $pwshExecutable = (Get-Command pwsh.exe).Source
    try {
        $env:PATH = $agentBin + ';' + $env:PATH
        foreach ($fixture in @(@{role='codex';mode='agents';expected='CODEX agents'},@{role='claude';mode='agents';expected='CLAUDE agents'},@{role='codex';mode='resume';expected='CODEX resume'},@{role='claude';mode='resume';expected='CLAUDE --resume'})) {
            $fixturePayload = @{root=$projectRoot;displayName='Fixture';role=$fixture.role;sessionMode=$fixture.mode} | ConvertTo-Json -Compress
            $fixture64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fixturePayload))
            $fixtureOutput = & $pwshExecutable -NoProfile -File "$repo/powershell/Start-Pane.ps1" -Payload $fixture64
            Assert ($LASTEXITCODE -eq 0 -and ($fixtureOutput -join ' ') -match [regex]::Escape($fixture.expected)) "Pane launches $($fixture.role) $($fixture.mode) command"
        }
    } finally { $env:PATH = $savedAgentPath }

    $legacy = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $legacyCode = "`$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; Import-Module '$($modulePath.Replace("'","''"))' -ArgumentList '$($registry.Replace("'","''"))' -DisableNameChecking; (workspace-fixture terminal -Preview).Root"
    $legacy64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($legacyCode))
    $legacyOutput = @(& $legacy -NoProfile -OutputFormat Text -EncodedCommand $legacy64)
    Assert ($LASTEXITCODE -eq 0 -and $legacyOutput[-1] -eq $projectRoot) 'Dispatcher and launch preview work in Windows PowerShell 5.1'
    $legacyCode = "`$ErrorActionPreference='Stop'; `$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; Import-Module '$($modulePath.Replace("'","''"))' -ArgumentList '$($registry.Replace("'","''"))' -DisableNameChecking; Resolve-AiProjectRoot '$($plain.Replace("'","''"))'"
    $legacy64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($legacyCode))
    $legacyOutput = @(& $legacy -NoProfile -OutputFormat Text -EncodedCommand $legacy64)
    Assert ($LASTEXITCODE -eq 0 -and $legacyOutput[-1] -eq $plain) 'Non-Git fallback works with strict error handling in Windows PowerShell 5.1'
    Remove-Module TerminalWorkspace

    $installRoot = Join-Path $scratch 'installed'
    $profileOne = Join-Path $scratch 'profile7.ps1'
    $profileTwo = Join-Path $scratch 'profile5.ps1'
    $settingsFile = Join-Path $scratch 'settings.json'
    $fragmentFile = Join-Path $scratch 'fragment/workspace.json'
    $originalProfile = "function keep-me { 'original' }`r`n"
    $originalSettings = '{"defaultProfile":"{00000000-0000-0000-0000-000000000000}","custom":"preserve me","profiles":{"list":[]},"keybindings":[{"keys":"ctrl+c","id":"copy"},{"keys":"ctrl+t","id":"newTab"}]}'
    [IO.File]::WriteAllText($profileOne, $originalProfile)
    [IO.File]::WriteAllText($settingsFile, $originalSettings)
    $installArgs = @{ ProjectsFile=$registry; InstallRoot=$installRoot; ProfilePaths=@($profileOne,$profileTwo); TerminalSettingsPath=$settingsFile; FragmentPath=$fragmentFile }
    & (Join-Path $repo 'Install.ps1') @installArgs
    Assert (([IO.File]::ReadAllText($profileOne)) -match 'function keep-me') 'Installer preserves existing profile functions'
    Assert ((Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).custom -eq 'preserve me') 'Installer preserves unrelated Terminal settings'
    Assert ((Get-Content -LiteralPath $fragmentFile -Raw | ConvertFrom-Json).profiles.Count -eq 3) 'Fragment defines three reusable profiles'
    $manifest = Get-Content -LiteralPath (Join-Path $installRoot 'installation.json') -Raw | ConvertFrom-Json
    $hashes = @{}
    foreach ($entry in $manifest.files) { $hashes[$entry.path] = (Get-FileHash -LiteralPath $entry.path).Hash }
    & (Join-Path $repo 'Install.ps1') @installArgs
    $unchanged = @($hashes.Keys | Where-Object { (Get-FileHash -LiteralPath $_).Hash -ne $hashes[$_] })
    Assert ($unchanged.Count -eq 0) 'Second install is byte-for-byte idempotent for all managed targets'
    Assert ([regex]::Matches([IO.File]::ReadAllText($profileOne), '# BEGIN TerminalDevSetup').Count -eq 1) 'Repeated installation leaves one profile import'
    Add-Content -LiteralPath $profileOne -Value '# subsequent user edit'
    Assert-Throws { & (Join-Path $installRoot 'Uninstall.ps1') } 'Changed since installation' 'Rollback refuses to overwrite subsequent user edits'
    Assert-Throws { & (Join-Path $repo 'Install.ps1') @installArgs } 'Changed since installation' 'Reinstall refuses to re-baseline subsequent edits against original backups'
    Assert ([IO.File]::ReadAllText($profileOne).Contains('# subsequent user edit')) 'Refused reinstall preserves the user edit'
    # Restore only this temporary test fixture to its expected installed bytes.
    $profileContent = [IO.File]::ReadAllText($profileOne)
    [IO.File]::WriteAllText($profileOne, ($profileContent -replace '# subsequent user edit\r?\n$',''), [Text.UTF8Encoding]::new($true))
    & (Join-Path $repo 'Install.ps1') @installArgs
    $generatedSettings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    $generatedSettings.profiles.list = @(
        @{ guid='{872dfbd8-fd1f-4ebe-b77e-051f87599dc0}'; name='Dev Codex'; hidden=$false; source='TerminalDevSetup' },
        @{ guid='{70192e26-44aa-4be9-b659-90b754f50f96}'; name='Dev Claude'; hidden=$false; source='TerminalDevSetup' },
        @{ guid='{74e2e943-2c73-4bd0-b06c-f21ec11b6386}'; name='Dev PowerShell'; hidden=$false; source='TerminalDevSetup' }
    )
    $generatedSettings.keybindings = @($generatedSettings.keybindings[1], $generatedSettings.keybindings[0])
    Write-Json $settingsFile $generatedSettings
    $null = & (Join-Path $installRoot 'Uninstall.ps1') -Preview
    Assert ($true) 'Rollback accepts Terminal-generated registration, formatting, and unique-keybinding reordering'
    $generatedSettings.custom = 'user changed this'
    Write-Json $settingsFile $generatedSettings
    Assert-Throws { & (Join-Path $installRoot 'Uninstall.ps1') -Preview } 'Changed since installation' 'Rollback still rejects unrelated settings changes alongside generated registration'
    $generatedSettings.custom = 'preserve me'
    Write-Json $settingsFile $generatedSettings
    & (Join-Path $installRoot 'Uninstall.ps1')
    Assert ([IO.File]::ReadAllText($profileOne) -eq $originalProfile) 'Rollback restores original profile bytes'
    Assert ([IO.File]::ReadAllText($settingsFile) -eq $originalSettings) 'Rollback restores original Terminal settings bytes'
    Assert (!(Test-Path -LiteralPath $profileTwo) -and !(Test-Path -LiteralPath $fragmentFile)) 'Rollback removes only newly installed files'
    Write-Host "All $script:passed checks passed. Test artifacts: $scratch"
} finally {
    Remove-Module TerminalWorkspace -ErrorAction SilentlyContinue
    # Retain the small, isolated fixtures and backups for inspection; no recursive deletion.
}
