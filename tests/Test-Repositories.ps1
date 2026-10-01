#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dev-setup-repos-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
Import-Module "$repo/powershell/RepositorySetup.psm1" -Force
$items = @(
    [pscustomobject]@{NameWithOwner='alice/alpha';Owner='alice';Name='alpha';Private=$false;Archived=$false;Fork=$false},
    [pscustomobject]@{NameWithOwner='alice/beta';Owner='alice';Name='beta';Private=$true;Archived=$false;Fork=$false},
    [pscustomobject]@{NameWithOwner='team/omega';Owner='team';Name='omega';Private=$false;Archived=$true;Fork=$false}
)
if (@(Select-RepositoryNames $items '1,3').Count -ne 2) { throw 'Multi-selection failed.' }
if (@(Select-RepositoryNames $items '1-3').Count -ne 3) { throw 'Range selection failed.' }
if (@(Select-RepositoryNames $items 'none').Count -ne 0) { throw 'None selection failed.' }
$selectionPath = Join-Path $scratch 'selection.json'
@{schemaVersion=1;repositories=@('alice/alpha','team/omega')} | ConvertTo-Json | Set-Content -LiteralPath $selectionPath
if (@(Read-RepositorySelection $selectionPath $items).Count -ne 2) { throw 'Saved selection failed.' }
@{schemaVersion=1;repositories=@('alice/unknown')} | ConvertTo-Json | Set-Content -LiteralPath $selectionPath
try { $null=Read-RepositorySelection $selectionPath $items; throw 'Unavailable repository was accepted.' }
catch { if ($_.Exception.Message -eq 'Unavailable repository was accepted.') { throw } }
$root = Join-Path $scratch 'clones'
$state = Get-RepositoryState 'alice/alpha' $root
if ($state.Status -ne 'Missing' -or $state.Path -ne (Join-Path $root 'alice/alpha')) { throw 'Missing clone state is wrong.' }
$null = New-Item -ItemType Directory -Path $state.Path -Force
& git init --quiet $state.Path
& git -C $state.Path remote add origin git@github.com:alice/alpha.git
if ((Get-RepositoryState 'alice/alpha' $root).Status -ne 'Ready') { throw 'Existing matching SSH clone was not preserved.' }
& git -C $state.Path remote set-url origin https://github.com/team/omega.git
if ((Get-RepositoryState 'alice/alpha' $root).Status -ne 'Conflict') { throw 'Mismatched origin was accepted.' }
try { $null=Get-RepositoryState '../escape' $root; throw 'Traversal was accepted.' }
catch { if ($_.Exception.Message -eq 'Traversal was accepted.') { throw } }
Write-Host 'Repository selection and preservation checks passed.'
