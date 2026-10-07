#requires -Version 7.2
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../powershell/ProjectCommands.ps1"
$script:passed=0
function Assert($Condition,$Message) {
    if (!$Condition) { throw "FAIL: $Message" }
    $script:passed++; Write-Host "PASS: $Message"
}
function New-Project($Repository, [string[]]$Aliases = @()) {
    @{command=($Repository.ToLowerInvariant() -replace '[^a-z0-9-]','-');displayName=$Repository;aliases=@($Aliases)}
}
$projects = @(New-Project 'alice/ContextTrace'; New-Project 'alice/DiplomacyJobs'; New-Project 'alice/Ludo.Nexus'; New-Project 'alice/dev-setup')
Add-RepositoryNameAliases $projects
Assert (($projects | ForEach-Object { $_.aliases -join ',' }) -join ';' -eq 'contexttrace;diplomacyjobs;ludo-nexus;dev-setup') 'Aliases consistently use lowercase repository names with hyphens for punctuation'
Add-RepositoryNameAliases $projects
Assert (@($projects | Where-Object { $_.aliases.Count -ne 1 }).Count -eq 0) 'Regeneration is idempotent and never duplicates automatic aliases'
$custom=@(New-Project 'alice/ContextTrace' @('ct'))
Add-RepositoryNameAliases $custom
Assert (($custom[0].aliases -join ',') -eq 'ct,contexttrace') 'Custom aliases are retained alongside the standard repository alias'
$duplicates=@(New-Project 'alice/alpha';New-Project 'bob/alpha';New-Project 'alice/Ludo.Nexus';New-Project 'bob/ludo-nexus')
Add-RepositoryNameAliases $duplicates
Assert (@($duplicates | Where-Object { $_.aliases.Count }).Count -eq 0) 'Ambiguous repository names and normalized punctuation collisions keep owner-qualified commands'
$shortcuts=@(New-Project 'alice/alpha';New-Project 'bob/alphacc')
Add-RepositoryNameAliases $shortcuts
Assert (@($shortcuts | Where-Object { $_.aliases.Count }).Count -eq 0) 'Aliases that would collide with another project agent shortcut are omitted'
$reserved=@(New-Project 'alice/ai-workspace';New-Project 'alice/cd';New-Project 'alice/git')
Add-RepositoryNameAliases $reserved
Assert (@($reserved | Where-Object { $_.aliases.Count }).Count -eq 0) 'Automatic aliases never claim workspace commands or existing shell commands'
$claimed=@(New-Project 'alice/alpha' @('beta');New-Project 'bob/beta')
Add-RepositoryNameAliases $claimed
Assert (($claimed[0].aliases -contains 'beta') -and !$claimed[1].aliases.Count) 'An established custom alias takes precedence over a new automatic alias'
$numeric=@(New-Project 'alice/123.project')
Add-RepositoryNameAliases $numeric
Assert (($numeric[0].aliases -join ',') -eq 'repo-123-project') 'Numeric repository names get a valid command prefix'
Write-Host "All $script:passed project command checks passed."
