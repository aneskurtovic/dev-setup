#requires -Version 7.2
# Exercise the actual entry point in a copied tree with fake package/config adapters.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dev-setup-runner-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path "$scratch/powershell","$scratch/manifests"
Copy-Item "$repo/Setup.ps1" $scratch
Copy-Item "$repo/powershell/ConfigEditing.ps1" "$scratch/powershell"
Copy-Item "$repo/powershell/ProjectCommands.ps1" "$scratch/powershell"
Copy-Item "$repo/manifests/core.json" "$scratch/manifests"
Copy-Item "$repo/manifests/developer.json" "$scratch/manifests"
@'
function Read-CoreManifest($Path) { (Get-Content $Path -Raw | ConvertFrom-Json).packages }
function Update-ProcessPath {}
function Get-CorePackageState($Package, [switch]$RuntimeHealth) {
    if ($RuntimeHealth) { Add-Content "$PSScriptRoot/runtime-checks.txt" $Package.name }
    $status = if (Test-Path "$PSScriptRoot/$($Package.name).incompatible") {'Incompatible'} elseif (Test-Path "$PSScriptRoot/$($Package.name).installed") {'Ready'} else {'Missing'}
    [pscustomobject]@{Name=$Package.name;Status=$status;Version='1.0';Detail='fixture'}
}
function Install-CorePackage($Package,[switch]$Update) {
    Add-Content "$PSScriptRoot/install-calls.txt" $Package.name
    if (Test-Path "$PSScriptRoot/$($Package.name).fail") { throw 'fixture installer failed with diagnostics' }
    if (Test-Path "$PSScriptRoot/$($Package.name).restart") { return [pscustomobject]@{Name=$Package.name;Status='NeedsRestart';Version=$null;Detail='Restart Windows, then rerun Apply.'} }
    Set-Content "$PSScriptRoot/$($Package.name).installed" 'fixture'
    Get-CorePackageState $Package
}
Export-ModuleMember -Function Read-CoreManifest,Update-ProcessPath,Get-CorePackageState,Install-CorePackage
'@ | Set-Content "$scratch/powershell/DevSetup.psm1"
@'
function Get-RepositoryInventory {
    if (Test-Path "$PSScriptRoot/inventory.fail") { throw 'fixture GitHub authentication failed' }
    @([pscustomobject]@{NameWithOwner='alice/alpha';Owner='alice';Name='alpha'})
}
function Read-RepositorySelection($Path,$Inventory) { @((Get-Content $Path -Raw | ConvertFrom-Json).repositories) }
function Get-RepositoryState($NameWithOwner,$Root) {
    $path = if (Test-Path "$PSScriptRoot/repo-path.txt") { (Get-Content "$PSScriptRoot/repo-path.txt" -Raw).Trim() } else { Join-Path $Root 'alice/alpha' }
    [pscustomobject]@{Repository=$NameWithOwner;Status=if (Test-Path "$Root/repo-ready") {'Ready'} else {'Missing'};Path=$path;Detail='fixture'}
}
function Install-SelectedRepositories($Names,$Root) {
    $null=New-Item -ItemType Directory -Path $Root -Force
    Set-Content "$Root/repo-ready" 'fixture'
    @($Names | ForEach-Object { Get-RepositoryState $_ $Root })
}
Export-ModuleMember -Function Get-RepositoryInventory,Read-RepositorySelection,Get-RepositoryState,Install-SelectedRepositories
'@ | Set-Content "$scratch/powershell/RepositorySetup.psm1"
@'
param([switch]$Preview,[string]$ProjectsFile,[switch]$ConfigureDisplay)
if ($ConfigureDisplay -and (Test-Path "$PSScriptRoot/display.fail")) { throw 'fixture display configuration conflict' }
$target = if ($ConfigureDisplay) { 'display-configured' } else { 'configured' }
if ($Preview) { [pscustomobject]@{Target=$target;Action=if (Test-Path "$PSScriptRoot/$target") {'Unchanged'} else {'Write'} } }
else { Set-Content "$PSScriptRoot/$target" 'fixture' }
'@ | Set-Content "$scratch/Install.ps1"
$script:passed=0
function Assert($Condition,$Message) { if (!$Condition) { throw "FAIL: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Invoke-Fixture($Mode) {
    $out = & pwsh -NoProfile -File "$scratch/Setup.ps1" -Mode $Mode -StateRoot "$scratch/state" -Json
    [pscustomobject]@{Code=$LASTEXITCODE;Report=($out | ConvertFrom-Json)}
}
function Invoke-DeveloperFixture($Mode = 'Apply', [string[]]$Components) {
    $arguments = @('-NoProfile','-File',"$scratch/Setup.ps1",'-Mode',$Mode,'-Preset','developer','-ProjectRoot',$cloneRoot,'-StateRoot',$developerState,'-Json')
    # A single component is sufficient for these explicit-update regression cases.
    if ($Components) { $arguments += @('-Component', $Components[0]) }
    $out = & pwsh @arguments
    [pscustomobject]@{Code=$LASTEXITCODE;Report=($out | ConvertFrom-Json)}
}
$plan=Invoke-Fixture Plan
Assert ($plan.Code -eq 0 -and !$plan.Report.ready -and !(Test-Path "$scratch/state")) 'Plan reports missing tools without creating state'
Assert (!(Test-Path "$scratch/powershell/install-calls.txt") -and !(Test-Path "$scratch/configured")) 'Plan invokes neither installer nor configuration writes'
$doctor=Invoke-Fixture Doctor
Assert ($doctor.Code -eq 1 -and !$doctor.Report.ready) 'Doctor exits nonzero for a missing environment'
$first=Invoke-Fixture Apply
Assert ($first.Code -eq 0 -and $first.Report.ready) 'Apply installs missing packages then configures workspace'
Assert (@(Get-Content "$scratch/powershell/install-calls.txt").Count -eq 4) 'Core Apply invokes exactly four missing package installs'
$second=Invoke-Fixture Apply
Assert ($second.Code -eq 0 -and $second.Report.ready -and @(Get-Content "$scratch/powershell/install-calls.txt").Count -eq 4) 'Second Apply skips every already-ready package'
$doctor=Invoke-Fixture Doctor
Assert ($doctor.Code -eq 0 -and $doctor.Report.ready) 'Doctor exits zero after successful setup'
Assert (@(Get-Content "$scratch/powershell/runtime-checks.txt").Count -eq 8) 'Only Doctor requests runtime health checks; Plan and Apply remain passive'
Assert (@(Get-ChildItem "$scratch/state/runs" -Filter *.json).Count -eq 2) 'Only Apply operations create run reports'
$developerState = Join-Path $scratch 'developer-state'
$null=New-Item -ItemType Directory -Path $developerState
@{schemaVersion=1;repositories=@('alice/alpha')} | ConvertTo-Json | Set-Content "$developerState/repositories.json"
$cloneRoot = Join-Path $scratch 'clones'
$out = & pwsh -NoProfile -File "$scratch/Setup.ps1" -Mode Plan -Preset developer -ProjectRoot $cloneRoot -StateRoot $developerState -Json
$developerPlan = $out | ConvertFrom-Json
Assert ($LASTEXITCODE -eq 0 -and !$developerPlan.ready -and !(Test-Path "$cloneRoot/repo-ready")) 'Developer Plan does not clone'
$out = & pwsh -NoProfile -File "$scratch/Setup.ps1" -Mode Apply -Preset developer -ProjectRoot $cloneRoot -StateRoot $developerState -Json
$developerApply = $out | ConvertFrom-Json
Assert ($LASTEXITCODE -eq 0 -and $developerApply.ready -and $developerApply.repositories.Status -eq 'Ready') 'Developer Apply installs and clones selected repositories'
$projectRegistry = Get-Content "$developerState/projects.json" -Raw | ConvertFrom-Json
Assert ($projectRegistry.projects[0].command -eq 'alice-alpha' -and $projectRegistry.projects[0].path -eq (Join-Path $cloneRoot 'alice/alpha')) 'Selected clone creates a project command at its owner/repo path'
Assert (($projectRegistry.projects[0].aliases -join ',') -eq 'alpha') 'Automatic project registration includes a repository-name alias'
$flatClone = Join-Path $cloneRoot 'alpha'
Set-Content "$scratch/powershell/repo-path.txt" $flatClone
$out = & pwsh -NoProfile -File "$scratch/Setup.ps1" -Mode Apply -Preset developer -ProjectRoot $cloneRoot -StateRoot $developerState -Json
$projectRegistry = Get-Content "$developerState/projects.json" -Raw | ConvertFrom-Json
Assert ($LASTEXITCODE -eq 0 -and $projectRegistry.projects[0].path -eq $flatClone) 'Project commands use the verified existing clone path'
$projectRegistry.projects[0].command = 'alpha'
$projectRegistry.projects[0].aliases = @('a','work-alpha')
$projectRegistry.projects[0].replaceNavigation = $true
$projectRegistry | ConvertTo-Json -Depth 8 | Set-Content "$developerState/projects.json"
$preserved = Invoke-DeveloperFixture
$projectRegistry = Get-Content "$developerState/projects.json" -Raw | ConvertFrom-Json
Assert ($preserved.Code -eq 0 -and $projectRegistry.projects[0].command -eq 'alpha' -and ($projectRegistry.projects[0].aliases -join ',') -eq 'a,work-alpha' -and $projectRegistry.projects[0].replaceNavigation -and $projectRegistry.projects[0].path -eq $flatClone) 'Regenerating project paths preserves established commands, aliases, and navigation preferences'
# Updates inspect prerequisites but must never install or update them implicitly.
foreach ($case in @(@{Name='docker';Dependency='wsl'},@{Name='codex';Dependency='node'},@{Name='claude';Dependency='git'})) {
    $before = @(Get-Content "$scratch/powershell/install-calls.txt").Count
    $update = Invoke-DeveloperFixture Update @($case.Name)
    $newCalls = @(@(Get-Content "$scratch/powershell/install-calls.txt") | Select-Object -Skip $before)
    Assert ($update.Code -eq 0 -and $update.Report.ready -and @($newCalls).Count -eq 1 -and $newCalls[0] -eq $case.Name -and $update.Report.prerequisites[0].Name -eq $case.Dependency) "Updating $($case.Name) checks its installed prerequisite and updates only the selected package"
}
Remove-Item "$scratch/powershell/node.installed"
$before = @(Get-Content "$scratch/powershell/install-calls.txt").Count
$blockedUpdate = Invoke-DeveloperFixture Update @('codex')
Assert ($blockedUpdate.Code -eq 1 -and $blockedUpdate.Report.packages[0].Status -eq 'Blocked' -and $blockedUpdate.Report.prerequisites[0].Status -eq 'Missing' -and @(Get-Content "$scratch/powershell/install-calls.txt").Count -eq $before) 'A missing unselected prerequisite blocks Update without installing it'
Set-Content "$scratch/powershell/node.installed" 'fixture'
$manifest = Get-Content "$scratch/manifests/developer.json" -Raw | ConvertFrom-Json
($manifest.packages | Where-Object name -EQ node) | Add-Member -NotePropertyName requires -NotePropertyValue @('github')
$manifest | ConvertTo-Json -Depth 8 | Set-Content "$scratch/manifests/developer.json"
$transitive = Invoke-DeveloperFixture Update @('codex')
Assert ($transitive.Code -eq 0 -and @($transitive.Report.prerequisites).Count -eq 2 -and $transitive.Report.prerequisites[0].Name -eq 'github') 'Targeted updates check the transitive prerequisite closure in manifest order'
Copy-Item "$repo/manifests/developer.json" "$scratch/manifests/developer.json" -Force
Set-Content "$scratch/powershell/sevenzip.incompatible" 'fixture'
$partial = Invoke-DeveloperFixture
Assert ($partial.Code -eq 1 -and !$partial.Report.ready -and $partial.Report.repositories.Status -eq 'Ready' -and $partial.Report.workspace.Status -eq 'Ready' -and $partial.Report.display.Status -eq 'Ready') 'An unrelated incompatible app leaves the run incomplete while repositories, workspace, and display finish'
Remove-Item "$scratch/powershell/sevenzip.incompatible"
Set-Content "$scratch/powershell/node.incompatible" 'fixture'
$partialNode = Invoke-DeveloperFixture
Assert ($partialNode.Code -eq 1 -and $partialNode.Report.repositories.Status -eq 'Ready' -and $partialNode.Report.workspace.Status -eq 'Ready' -and $partialNode.Report.display.Status -eq 'Blocked') 'Missing display prerequisites block only display and dependent packages'
Remove-Item "$scratch/powershell/node.incompatible"
Set-Content "$scratch/display.fail" 'fixture'
$displayConflict = Invoke-DeveloperFixture
Assert ($displayConflict.Code -eq 1 -and $displayConflict.Report.workspace.Status -eq 'Ready' -and $displayConflict.Report.display.Status -eq 'Conflict') 'Display configuration conflicts preserve a successfully configured base workspace'
Remove-Item "$scratch/display.fail"
Set-Content "$scratch/powershell/inventory.fail" 'fixture'
$repoFailure = Invoke-DeveloperFixture
Assert ($repoFailure.Code -eq 1 -and $repoFailure.Report.repositories.Status -eq 'Conflict' -and $repoFailure.Report.workspace.Status -eq 'Ready' -and $repoFailure.Report.display.Status -eq 'Ready') 'Repository authentication failure does not prevent workspace and display configuration'
Remove-Item "$scratch/powershell/inventory.fail"
Set-Content "$scratch/powershell/github.incompatible" 'fixture'
$githubFailure = Invoke-DeveloperFixture
Assert ($githubFailure.Code -eq 1 -and $githubFailure.Report.repositories.Status -eq 'Blocked' -and $githubFailure.Report.workspace.Status -eq 'Ready') 'GitHub CLI is required for repositories but not the base workspace'
Remove-Item "$scratch/powershell/github.incompatible"
# A package failure must leave a useful report and still inspect independent packages.
Remove-Item "$scratch/powershell/git.installed"
Set-Content "$scratch/powershell/git.fail" 'fixture'
$failed = Invoke-Fixture Apply
Assert ($failed.Code -eq 1 -and !$failed.Report.ready -and @($failed.Report.packages).Count -eq 4) 'Failed package keeps a nonzero exit and a complete independent package report'
Assert (($failed.Report.packages | Where-Object Name -EQ git).Status -eq 'Failed' -and ($failed.Report.manualSteps -join ' ') -match 'fixture installer failed with diagnostics') 'Failed package includes actionable diagnostics and recovery steps'
Assert ($failed.Report.workspace.Status -eq 'Blocked' -and (Test-Path $failed.Report.reportPath)) 'Failed Apply blocks configuration and retains its JSON run report'
$out = & pwsh -NoProfile -File "$scratch/Setup.ps1" -Mode Apply -Preset developer -ProjectRoot $cloneRoot -StateRoot $developerState -Json
$failedDeveloper = $out | ConvertFrom-Json
Assert ($LASTEXITCODE -eq 1 -and ($failedDeveloper.packages | Where-Object Name -EQ claude).Status -eq 'Blocked') 'Dependent packages are blocked after a dependency fails'
Remove-Item "$scratch/powershell/git.fail"
Set-Content "$scratch/powershell/git.incompatible" 'fixture'
$incompatible = Invoke-Fixture Apply
Assert (($incompatible.Report.manualSteps -join ' ') -match 'winget upgrade --id Git.Git --exact' -and ($incompatible.Report.packages | Where-Object Name -EQ git).Status -eq 'Incompatible') 'Incompatible packages give an update command usable outside a checkout'
Remove-Item "$scratch/powershell/git.incompatible"
Set-Content "$scratch/powershell/git.restart" 'fixture'
$restart = Invoke-Fixture Apply
Assert ($restart.Code -eq 1 -and ($restart.Report.packages | Select-Object -Last 1).Status -eq 'NeedsRestart' -and @($restart.Report.packages).Count -eq 3) 'Restart-required installation stops subsequent package processing'
Write-Host "All $script:passed orchestration checks passed. Fixtures retained: $scratch"
