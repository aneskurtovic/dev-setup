#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $ProjectsFile,
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'TerminalDevSetup'),
    [string[]] $ProfilePaths = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Microsoft.PowerShell_profile.ps1'),
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell/Microsoft.PowerShell_profile.ps1')
    ),
    [string] $TerminalSettingsPath = (Join-Path $env:LOCALAPPDATA 'Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json'),
    [string] $FragmentPath = (Join-Path $env:LOCALAPPDATA 'Microsoft/Windows Terminal/Fragments/TerminalDevSetup/workspace.json'),
    [switch] $ConfigureDisplay,
    [string] $CodexConfigPath = (Join-Path $env:USERPROFILE '.codex/config.toml'),
    [string] $ClaudeStatuslinePath = (Join-Path $env:USERPROFILE '.claude/statusline.js'),
    [string] $ClaudeSettingsPath = (Join-Path $env:USERPROFILE '.claude/settings.json'),
    [switch] $Preview
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'powershell/ConfigEditing.ps1')
. (Join-Path $PSScriptRoot 'powershell/TerminalSettings.ps1')
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$mutexName = 'Local\DevSetup-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($InstallRoot.ToLowerInvariant())))
$mutex = [Threading.Mutex]::new($false, $mutexName)
$ownsMutex = $false
try {
try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
if (!$ownsMutex) { throw 'Another workspace install or rollback is running.' }
$pwsh = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$null = Get-Command wt.exe -CommandType Application -ErrorAction Stop
$settingsText = if (Test-Path -LiteralPath $TerminalSettingsPath) { [IO.File]::ReadAllText($TerminalSettingsPath) } else { '{}' }
$settings = $settingsText | ConvertFrom-Json
$shellGuid = '{74e2e943-2c73-4bd0-b06c-f21ec11b6386}'
$registryTarget = Join-Path $InstallRoot 'projects.json'
if (!$ProjectsFile) {
    $ProjectsFile = if (Test-Path -LiteralPath $registryTarget) { $registryTarget } else { Join-Path $PSScriptRoot 'config/projects.example.json' }
}
$registryText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ProjectsFile).Path)
# Parse and validate before changing any configuration.
Import-Module (Join-Path $PSScriptRoot 'powershell/TerminalWorkspace.psm1') -ArgumentList $ProjectsFile -Force -DisableNameChecking
$null = Get-AiProject -All
Remove-Module TerminalWorkspace

$utf8 = [Text.UTF8Encoding]::new($false)
$utf8Bom = [Text.UTF8Encoding]::new($true)
$writes = [ordered]@{}
foreach ($file in @('TerminalWorkspace.psm1','Start-Pane.ps1','Workspace-Prompt.ps1','TerminalSettings.ps1')) {
    $writes[(Join-Path $InstallRoot $file)] = @{ Content = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "powershell/$file")); Encoding = $utf8 }
}
$writes[(Join-Path $InstallRoot 'Uninstall.ps1')] = @{ Content = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Uninstall.ps1')); Encoding = $utf8 }
$writes[$registryTarget] = @{ Content = $registryText; Encoding = $utf8 }

$profiles = @()
$definitions = @(
    @{ name = 'Dev Codex'; guid = '{872dfbd8-fd1f-4ebe-b77e-051f87599dc0}'; background = '#0B1511'; accent = '#4ADE80' },
    @{ name = 'Dev Claude'; guid = '{70192e26-44aa-4be9-b659-90b754f50f96}'; background = '#19110D'; accent = '#F5A35C' },
    @{ name = 'Dev PowerShell'; guid = $shellGuid; background = '#0A0A0F'; accent = '#60A5FA' }
)
foreach ($definition in $definitions) {
    $profile = [ordered]@{
        name = $definition.name; guid = $definition.guid; hidden = $false
        commandline = ('"{0}" -NoLogo' -f $pwsh)
        startingDirectory = '%USERPROFILE%'
        background = $definition.background; cursorColor = $definition.accent; tabColor = $definition.accent
        opacity = 100; useAcrylic = $false; padding = '8'
        suppressApplicationTitle = $true
        icon = (Join-Path (Split-Path $pwsh) 'assets/Powershell_av_colors.ico')
    }
    $profiles += $profile
}
$fragmentText = @{ profiles = $profiles } | ConvertTo-Json -Depth 10
$writes[$FragmentPath] = @{ Content = $fragmentText + "`n"; Encoding = $utf8 }

$importPath = (Join-Path $InstallRoot 'TerminalWorkspace.psm1').Replace("'", "''")
$promptPath = (Join-Path $InstallRoot 'Workspace-Prompt.ps1').Replace("'", "''")
$importBlock = @"
# BEGIN TerminalDevSetup (managed)
Import-Module '$importPath' -Global -Force -DisableNameChecking
. '$promptPath'
# END TerminalDevSetup (managed)
"@
$readLineBlock = @'
if ($Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) {
    Import-Module PSReadLine -MinimumVersion 2.4.0 -ErrorAction SilentlyContinue
    if (Get-Module PSReadLine) {
        if ((Get-Module PSReadLine).Version -ge [version]'2.2.0') {
            Set-PSReadLineOption -PredictionSource History
            Set-PSReadLineOption -PredictionViewStyle InlineView
        }
        Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
        Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    }
}
'@
foreach ($path in $ProfilePaths) {
    $content = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { '' }
    $pattern = '(?ms)^Import-Module PSReadLine[^\r\n]*\r?\nif \(\(Get-Module PSReadLine\).*?^Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward[^\r\n]*'
    $content = [regex]::Replace($content, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $readLineBlock })
    $managed = '(?ms)^# BEGIN TerminalDevSetup \(managed\)\r?\n.*?^# END TerminalDevSetup \(managed\)[^\r\n]*'
    if ($content -match $managed) {
        $content = [regex]::Replace($content, $managed, [Text.RegularExpressions.MatchEvaluator]{ param($match) $importBlock })
    } else { $content = $content.TrimEnd() + "`r`n`r`n" + $importBlock + "`r`n" }
    $writes[$path] = @{ Content = $content; Encoding = $utf8Bom }
}

# Change only the defaultProfile value, leaving formatting, bindings and existing profiles intact.
$settingsText = Set-JsonRootValue $settingsText 'defaultProfile' $shellGuid
if (($settingsText | ConvertFrom-Json).defaultProfile -ne $shellGuid) { throw 'Could not update the Terminal defaultProfile safely.' }
if ($ConfigureDisplay) {
    # Change only Ctrl+W's binding; retain the old action for any other shortcuts.
    $bindings = @($settings.keybindings | Where-Object { $null -ne $_ -and $_.keys -ne 'ctrl+w' })
    $bindings += [ordered]@{ id='Terminal.ClosePane'; keys='ctrl+w' }
    $settingsText = Set-JsonRootValue $settingsText 'keybindings' $bindings
    $null = Get-Command node -CommandType Application -ErrorAction Stop
    $codex = if (Test-Path -LiteralPath $CodexConfigPath) { [IO.File]::ReadAllText($CodexConfigPath) } else { '' }
    $status = 'status_line = ["model-with-reasoning", "context-remaining", "git-branch", "five-hour-limit", "weekly-limit"]'
    if ($codex -notmatch '(?m)^\[tui\]\s*$') {
        if ($codex -match '(?m)^\s*(?:tui\s*[.=]|\[\s*["'']?tui)') { throw 'Nonstandard tui syntax: configure status_line manually before using ConfigureDisplay.' }
        $codex = $codex.TrimEnd() + "`n[tui]`n"
    }
    $section = [regex]::new('(?ms)^\[tui\][^\r\n]*\r?\n(?<body>.*?)(?=^\[|\z)')
    $codex = $section.Replace($codex, [Text.RegularExpressions.MatchEvaluator]{ param($m)
        $body = $m.Groups['body'].Value
        if ($body -match '(?m)^status_line\s*=') {
            $body = [regex]::Replace($body, '(?ms)^status_line\s*=\s*\[.*?\][^\r\n]*', $status)
        } else { $body = $status + "`n" + $body }
        "[tui]`n" + $body
    })
    $writes[$CodexConfigPath] = @{ Content = $codex; Encoding = $utf8 }
    $writes[$ClaudeStatuslinePath] = @{ Content = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'claude/statusline.js')); Encoding = $utf8 }
    $claudeSettings = if (Test-Path -LiteralPath $ClaudeSettingsPath) { [IO.File]::ReadAllText($ClaudeSettingsPath) } else { '{}' }
    # Claude invokes the command through a shell; reject shell metacharacters in this optional integration.
    if ($ClaudeStatuslinePath -match '["`$\r\n%!]') { throw 'Unsupported shell metacharacter in ClaudeStatuslinePath.' }
    $command = 'node "' + $ClaudeStatuslinePath.Replace('\','/') + '"'
    $claudeSettings = Set-JsonRootValue $claudeSettings 'statusLine' ([ordered]@{ type='command'; command=$command })
    $writes[$ClaudeSettingsPath] = @{ Content=$claudeSettings; Encoding=$utf8 }
}

$writes[$TerminalSettingsPath] = @{ Content = $settingsText; Encoding = $utf8 }

$manifestPath = Join-Path $InstallRoot 'installation.json'
$manifest = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable } else { @{ schemaVersion = 1; files = @() } }
# Never silently re-baseline a user's changed file against an older backup.
foreach ($entry in $manifest.files) {
    if (!$writes.Contains($entry.path)) { continue }
    if (!$entry.installedHash -or !(Test-Path -LiteralPath $entry.path) -or (Get-FileHash -LiteralPath $entry.path).Hash -ne $entry.installedHash) {
        if ($entry.path -eq $TerminalSettingsPath -and $entry.installedHash -and (Test-Path -LiteralPath $entry.path)) {
            $recordedSettings = $entry.installedContent
            # Recover the exact prior content for installations made before snapshots.
            if (!$recordedSettings -and $entry.backup -and (Test-Path -LiteralPath $entry.backup)) {
                $candidate = Set-JsonRootValue ([IO.File]::ReadAllText($entry.backup)) 'defaultProfile' $shellGuid
                foreach ($withDisplay in @($false,$true)) {
                    if ($withDisplay) {
                        $previous = $candidate | ConvertFrom-Json
                        $previousBindings = @($previous.keybindings | Where-Object { $null -ne $_ -and $_.keys -ne 'ctrl+w' })
                        $previousBindings += [ordered]@{id='Terminal.ClosePane';keys='ctrl+w'}
                        $candidate = Set-JsonRootValue $candidate 'keybindings' $previousBindings
                    }
                    $candidateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($candidate)))
                    if ($candidateHash -eq $entry.installedHash) { $recordedSettings = $candidate; break }
                }
            }
            if ($recordedSettings -and (Test-TerminalSettingsEquivalent $recordedSettings $settingsText)) { continue }
        }
        throw "Changed since installation or incomplete installation: $($entry.path). Reconcile with backups before reinstalling; no files changed."
    }
}
if ($Preview) {
    foreach ($target in $writes.Keys) {
        $write = $writes[$target]
        $desired = [byte[]] ($write.Encoding.GetPreamble() + $write.Encoding.GetBytes($write.Content))
        $exists = Test-Path -LiteralPath $target
        $same = $exists -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -eq [Convert]::ToBase64String($desired)
        if (!$same -and $exists -and $target -eq $TerminalSettingsPath) { $same = Test-TerminalSettingsEquivalent $write.Content ([IO.File]::ReadAllText($target)) }
        [pscustomobject]@{ Target=$target; Exists=$exists; Action=if ($same) {'Unchanged'} else {'Write'} }
    }
    return
}
$backupRoot = Join-Path $InstallRoot ('backups/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-ffff'))
$null = New-Item -ItemType Directory -Path $backupRoot -Force

# Preserve the original bytes of every target before applying any writes.
foreach ($target in $writes.Keys) {
    $entry = @($manifest.files | Where-Object { $_.path -eq $target })
    if ($entry.Count -eq 0) {
        $exists = Test-Path -LiteralPath $target
        $backup = if ($exists) { Join-Path $backupRoot ("{0:D3}.bak" -f $manifest.files.Count) } else { $null }
        if ($exists) { Copy-Item -LiteralPath $target -Destination $backup }
        $manifest.files += @{ path = $target; existed = $exists; backup = $backup; installedHash = $null }
    }
}
Write-AtomicBytes $manifestPath ($utf8.GetBytes(($manifest | ConvertTo-Json -Depth 10)))
foreach ($target in $writes.Keys) {
    $write = $writes[$target]
    $desired = [byte[]] ($write.Encoding.GetPreamble() + $write.Encoding.GetBytes($write.Content))
    $same = (Test-Path -LiteralPath $target) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -eq [Convert]::ToBase64String($desired)
    if (!$same -and (Test-Path -LiteralPath $target) -and $target -eq $TerminalSettingsPath) { $same = Test-TerminalSettingsEquivalent $write.Content ([IO.File]::ReadAllText($target)) }
    if (!$same) {
        $null = New-Item -ItemType Directory -Path (Split-Path $target) -Force
        Write-AtomicBytes $target $desired
        Write-Host "Updated: $target"
    }
    $entry = $manifest.files | Where-Object { $_.path -eq $target } | Select-Object -First 1
    $entry.installedHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($target -eq $TerminalSettingsPath) { $entry['installedContent'] = [IO.File]::ReadAllText($target) }
    Write-AtomicBytes $manifestPath ($utf8.GetBytes(($manifest | ConvertTo-Json -Depth 10)))
}
Write-Host "Installed. Open a new PowerShell session, then run ai-doctor or ai-workspace."
Write-Host "Rollback: pwsh -NoProfile -File `"$(Join-Path $InstallRoot 'Uninstall.ps1')`""
} finally { if ($ownsMutex) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
