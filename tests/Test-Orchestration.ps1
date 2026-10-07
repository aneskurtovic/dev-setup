#requires -Version 7.2
# Exercise the actual entry point in a copied tree with fake package/config adapters.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dev-setup-runner-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path "$scratch/powershell","$scratch/manifests"
Copy-Item "$repo/Setup.ps1" $scratch
Copy-Item "$repo/powershell/ConfigEditing.ps1" "$scratch/powershell"
Copy-Item "$repo/manifests/core.json" "$scratch/manifests"
Copy-Item "$repo/manifests/developer.json" "$scratch/manifests"
@'
function Read-CoreManifest($Path) { (Get-Content $Path -Raw | ConvertFrom-Json).packages }
function Get-CorePackageState($Package) {
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
Export-ModuleMember -Function Read-CoreManifest,Get-CorePackageState,Install-CorePackage
'@ | Set-Content "$scratch/powershell/DevSetup.psm1"
@'
function Get-RepositoryInventory { @([pscustomobject]@{NameWithOwner='alice/alpha';Owner='alice';Name='alpha'}) }
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
if ($Preview) { [pscustomobject]@{Target='fixture';Action=if (Test-Path "$PSScriptRoot/configured") {'Unchanged'} else {'Write'} } }
else { Set-Content "$PSScriptRoot/configured" 'fixture' }
'@ | Set-Content "$scratch/Install.ps1"
$script:passed=0
function Assert($Condition,$Message) { if (!$Condition) { throw "FAIL: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Invoke-Fixture($Mode) {
    $out = & pwsh -NoProfile -File "$scratch/Setup.ps1" -Mode $Mode -StateRoot "$scratch/state" -Json
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
$flatClone = Join-Path $cloneRoot 'alpha'
Set-Content "$scratch/powershell/repo-path.txt" $flatClone
$out = & pwsh -NoProfile -File "$scratch/Setup.ps1" -Mode Apply -Preset developer -ProjectRoot $cloneRoot -StateRoot $developerState -Json
$projectRegistry = Get-Content "$developerState/projects.json" -Raw | ConvertFrom-Json
Assert ($LASTEXITCODE -eq 0 -and $projectRegistry.projects[0].path -eq $flatClone) 'Project commands use the verified existing clone path'
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
