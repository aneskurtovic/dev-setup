#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Plan','Apply','Doctor','Update')][string] $Mode = 'Plan',
    [ValidateSet('core','developer')][string] $Preset = 'core',
    [string[]] $Component,
    [string] $ProjectsFile,
    [string] $ProjectRoot = (Join-Path $env:USERPROFILE 'source/repos'),
    [string] $RepositoriesFile,
    [switch] $ChooseRepositories,
    [string] $StateRoot = (Join-Path $env:LOCALAPPDATA 'DevSetup'),
    [switch] $Json
)
$ErrorActionPreference = 'Stop'
$report = [ordered]@{ schemaVersion=1; mode=$Mode; preset=$Preset; ready=$false; packages=@(); repositories=$null; workspace=$null; manualSteps=@(); error=$null; reportPath=$null }
$lock = $null
$journalPath = $null
try {
if (!$IsWindows -or [Environment]::OSVersion.Version.Build -lt 22000) { throw 'This version targets Windows 11. Other platforms are not supported yet.' }
Import-Module (Join-Path $PSScriptRoot 'powershell/DevSetup.psm1') -Force
Update-ProcessPath
if ($Preset -eq 'developer') { Import-Module (Join-Path $PSScriptRoot 'powershell/RepositorySetup.psm1') -Force }
. (Join-Path $PSScriptRoot 'powershell/ConfigEditing.ps1')
$packages = @(Read-CoreManifest (Join-Path $PSScriptRoot "manifests/$Preset.json"))
if ($Mode -eq 'Update' -and !$Component) { throw 'Update requires -Component with explicit package names.' }
if ($ChooseRepositories -and $Mode -ne 'Apply') { throw '-ChooseRepositories requires Apply.' }
if ($RepositoriesFile -and $Mode -ne 'Apply') { throw '-RepositoriesFile requires Apply.' }
if (($ChooseRepositories -or $RepositoriesFile) -and $Preset -ne 'developer') { throw 'Repository selection requires the developer preset.' }
if ($Preset -eq 'developer' -and ![IO.Path]::IsPathFullyQualified($ProjectRoot)) { throw '-ProjectRoot must be an absolute path.' }
if ($Component) {
    if ($Mode -ne 'Update') { throw '-Component is supported only with Update; Apply always verifies all dependencies.' }
    foreach ($name in $Component) { if ($name -notin $packages.name) { throw "Unknown component: $name" } }
    $packages = @($packages | Where-Object name -In $Component)
}
$installArgs = @{}
if ($ProjectsFile) { $installArgs.ProjectsFile = $ProjectsFile }
if ($Preset -eq 'developer') { $installArgs.ConfigureDisplay = $true }
    if ($Mode -in @('Apply','Update')) {
        $null = New-Item -ItemType Directory -Path $StateRoot -Force
        try { $lock = [IO.File]::Open((Join-Path $StateRoot 'setup.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { throw 'Another setup process holds the setup lock.' }
        $journalPath = Join-Path $StateRoot ('runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.json')
        $report.reportPath = $journalPath
    }
    foreach ($package in $packages) {
        try {
        $state = Get-CorePackageState $package
        $dependencies = if ($package.PSObject.Properties['requires']) { @($package.requires) } else { @() }
        $unready = @($dependencies | Where-Object { $_ -notin @($report.packages | Where-Object Status -EQ 'Ready' | ForEach-Object Name) })
        if ($unready.Count) { $state = [pscustomobject]@{Name=$package.name;Status='Blocked';Version=$null;Detail=('Requires ' + ($unready -join ', '))} }
        elseif ($Mode -eq 'Apply' -and $state.Status -eq 'Missing') {
            if (!$Json) { Write-Host "Installing $($package.name)..." }
            $state = Install-CorePackage $package
        }
        elseif ($Mode -eq 'Update') {
            if (!$Json) { Write-Host "Updating $($package.name)..." }
            if ($state.Status -eq 'Missing') { $state = Install-CorePackage $package }
            else { $state = Install-CorePackage $package -Update }
        }
        } catch {
            $state = [pscustomobject]@{Name=$package.name;Status='Failed';Version=$null;Detail=$_.Exception.Message}
        }
        $report.packages += $state
        if ($state.Status -eq 'Incompatible') {
            $updateCommand = if ($package.source -eq 'winget') { "winget upgrade --id $($package.id) --exact --source winget" }
                elseif ($package.source -eq 'npm') { "npm install --global $($package.id)@latest" }
                else { 'wsl --update' }
            $report.manualSteps += "Update $($package.name) explicitly: $updateCommand, then rerun Apply."
        } elseif ($state.Status -in @('Failed','Conflict','NeedsAttention','NeedsRestart')) {
            $report.manualSteps += "$($package.name): $($state.Detail)"
        }
        if ($journalPath) { Write-AtomicBytes $journalPath ([Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 10))) }
        if ($state.Status -eq 'NeedsRestart') { break }
    }
    if ($Mode -ne 'Update') {
        if (@($report.packages | Where-Object Status -NE 'Ready').Count) {
            $report.workspace = @{ Status='Blocked'; Detail='Resolve missing/incompatible packages, then rerun.' }
            if ($Preset -eq 'developer') { $report.repositories = @{ Status='Blocked'; Detail='Finish package setup first.' } }
        } else {
            if ($Preset -eq 'developer') {
                $selectionPath = Join-Path $StateRoot 'repositories.json'
                if ($Mode -eq 'Apply') {
                    if ($RepositoriesFile -or $ChooseRepositories -or !(Test-Path -LiteralPath $selectionPath)) {
                        $auth = & gh auth status 2>$null
                        if ($LASTEXITCODE -ne 0 -and !$Json) { & gh auth login; if ($LASTEXITCODE -ne 0) { throw 'GitHub sign-in did not complete.' } }
                        elseif ($LASTEXITCODE -ne 0) { throw 'GitHub sign-in required. Run gh auth login, then rerun Apply.' }
                        $inventory = @(Get-RepositoryInventory)
                        if ($RepositoriesFile) { $selected = @(Read-RepositorySelection $RepositoriesFile $inventory) }
                        elseif ($Json) { throw 'Repository selection required. Rerun Apply interactively or pass -RepositoriesFile.' }
                        else { $selected = @(Request-RepositorySelection $inventory) }
                        $selection = @{schemaVersion=1;repositories=$selected} | ConvertTo-Json -Depth 4
                        Write-AtomicBytes $selectionPath ([Text.Encoding]::UTF8.GetBytes($selection))
                    } else {
                        $inventory = @(Get-RepositoryInventory)
                        $selected = @(Read-RepositorySelection $selectionPath $inventory)
                    }
                    $repoStates = @(Install-SelectedRepositories $selected $ProjectRoot)
                    $report.repositories = @{Status=if (@($repoStates | Where-Object Status -NE 'Ready').Count) {'Conflict'} else {'Ready'}; Selected=$selected; States=$repoStates; Root=$ProjectRoot}
                } else {
                    if (!(Test-Path -LiteralPath $selectionPath)) { $report.repositories = @{Status='NeedsSelection';Detail='Apply interactively to choose repositories.'} }
                    else {
                        $selection = Get-Content -LiteralPath $selectionPath -Raw | ConvertFrom-Json
                        if ($selection.schemaVersion -ne 1 -or !$selection.PSObject.Properties['repositories']) { throw 'Invalid saved repository selection.' }
                        $selected = @($selection.repositories)
                        $repoStates = @($selected | ForEach-Object { Get-RepositoryState $_ $ProjectRoot })
                        $report.repositories = @{Status=if (@($repoStates | Where-Object Status -NE 'Ready').Count) {'ChangesNeeded'} else {'Ready'}; Selected=$selected; States=$repoStates; Root=$ProjectRoot}
                    }
                }
                if (!$ProjectsFile -and $report.repositories.Status -eq 'Ready') {
                    $registryPath = Join-Path $StateRoot 'projects.json'
                    $usedCommands = @{}
                    $registry = @{schemaVersion=1;projects=@($selected | ForEach-Object {
                        $repositoryName = $_
                        $repoPath = [IO.Path]::GetFullPath(($repoStates | Where-Object Repository -EQ $repositoryName | Select-Object -First 1).Path)
                        $command = ($_.ToLowerInvariant() -replace '[^a-z0-9-]','-').Trim('-')
                        if ($command -notmatch '^[a-z]') { $command = 'repo-' + $command }
                        if ($command -in @('ai-workspace','ai-workspace-resume','ai-workspace-agents','ai-projects','ai-doctor')) { $command = 'repo-' + $command }
                        if ($usedCommands.ContainsKey($command) -or $usedCommands.ContainsKey($command + 'cc') -or $usedCommands.ContainsKey($command + 'cx')) {
                            $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($_))
                            $command += '-' + [Convert]::ToHexString($hash).Substring(0,8).ToLowerInvariant()
                        }
                        foreach ($name in @($command, ($command + 'cc'), ($command + 'cx'))) { $usedCommands[$name] = $true }
                        @{command=$command;displayName=$_;path=$repoPath;enabled=$true;replaceNavigation=$false;aliases=@()}
                    })} | ConvertTo-Json -Depth 6
                    if ($Mode -eq 'Apply') { Write-AtomicBytes $registryPath ([Text.Encoding]::UTF8.GetBytes($registry)) }
                    if (Test-Path -LiteralPath $registryPath) { $installArgs.ProjectsFile = $registryPath }
                }
            }
            try {
                $changes = @(& (Join-Path $PSScriptRoot 'Install.ps1') @installArgs -Preview)
                if ($Mode -eq 'Apply') {
                    & (Join-Path $PSScriptRoot 'Install.ps1') @installArgs 6>$null
                    $changes = @(& (Join-Path $PSScriptRoot 'Install.ps1') @installArgs -Preview)
                }
                $pending = @($changes | Where-Object Action -NE 'Unchanged')
                $report.workspace = @{ Status=if ($pending.Count) {'ChangesNeeded'} else {'Ready'}; Changes=$pending }
            } catch {
                $report.workspace = @{ Status='Conflict'; Detail=$_.Exception.Message }
                $report.manualSteps += "Workspace: $($_.Exception.Message)"
            }
        }
    }
    $report.ready = @($report.packages | Where-Object Status -NE 'Ready').Count -eq 0 -and ($Mode -eq 'Update' -or ($report.workspace.Status -eq 'Ready' -and ($Preset -eq 'core' -or $report.repositories.Status -eq 'Ready')))
} catch {
    $report.error = $_.Exception.Message
    $report.manualSteps += "Resolve this error, then rerun $Mode`: $($report.error)"
}
finally {
    try {
        if ($journalPath) { Write-AtomicBytes $journalPath ([Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 10))) }
    } catch {
        $report.ready = $false
        $report.error = "Could not save the run report to '$journalPath': $($_.Exception.Message)"
        $report.manualSteps += $report.error
    } finally { if ($lock) { $lock.Dispose() } }
}
if ($Json) { $report | ConvertTo-Json -Depth 10 }
else {
    $report.packages | Format-Table Name,Status,Version,Detail -AutoSize
    if ($report.workspace) { Write-Host ('Workspace: ' + $report.workspace.Status); $report.workspace | ConvertTo-Json -Depth 6 | Write-Host }
    if ($report.repositories) { Write-Host ('Repositories: ' + $report.repositories.Status); $report.repositories | ConvertTo-Json -Depth 6 | Write-Host }
    if ($report.error) { Write-Host $report.error -ForegroundColor Red }
    $report.manualSteps | ForEach-Object { Write-Host $_ }
    if ($journalPath) { Write-Host "Run report: $journalPath" }
    if ($Mode -ne 'Plan') {
        if ($report.ready) { Write-Host 'dev-setup completed successfully.' -ForegroundColor Green }
        else { Write-Warning 'dev-setup is incomplete. Follow the recovery steps above and rerun. Completed changes are retained.' }
    }
}
if ($report.error -or ($Mode -ne 'Plan' -and !$report.ready)) { exit 1 }
exit 0
