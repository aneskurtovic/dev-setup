#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Plan','Apply','Doctor')][string] $Mode = 'Plan',
    [ValidateSet('core','developer')][string] $Preset = 'core',
    [switch] $RepairWinGet,
    [string] $ProjectRoot,
    [string] $ProjectsFile,
    [string] $RepositoriesFile,
    [switch] $ChooseRepositories
)
$ErrorActionPreference = 'Stop'
try {
if ($env:OS -ne 'Windows_NT' -or [Environment]::OSVersion.Version.Build -lt 22000) { throw 'dev-setup currently targets Windows 11.' }
function Find-PowerShell7 {
    $command = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $candidates = @()
    if ($command) { $candidates += $command.Source }
    $candidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate) {
            $versionText = & $candidate -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
            if ($LASTEXITCODE -eq 0 -and [version]$versionText -ge [version]'7.2') { return $candidate }
        }
    }
}
$pwshPath = Find-PowerShell7
if ($Mode -eq 'Apply') {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$winget -and $RepairWinGet) {
        # Explicit opt-in to the Microsoft-documented PSGallery repair route.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
        Install-Module Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force
        Import-Module Microsoft.WinGet.Client
        Repair-WinGetPackageManager
        $env:PATH += ';' + [Environment]::GetEnvironmentVariable('Path','User')
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (!$winget) { throw 'WinGet is unavailable. Install/update Microsoft App Installer, or rerun Apply with -RepairWinGet to use the Microsoft repair module.' }
    if (!$pwshPath) {
        & $winget.Source install --id Microsoft.PowerShell --exact --source winget --no-upgrade --accept-source-agreements --accept-package-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) { throw "PowerShell installation failed ($LASTEXITCODE). Inspect WinGet logs and rerun." }
        $pwshPath = Find-PowerShell7
        if (!$pwshPath) { throw 'PowerShell 7.2+ is still unavailable. A pre-existing old version requires an explicit upgrade, or a new shell may be needed.' }
    }
}
if (!$pwshPath) {
    Write-Host 'PowerShell 7.2+ is missing. Apply installs it with WinGet, then runs the selected preset.'
    Write-Host 'Plan/Doctor made no changes. WinGet/App Installer must be available; -RepairWinGet is an explicit repair option for Apply.'
    if ($Mode -eq 'Doctor') { exit 1 }
    exit 0
}
$setupArgs = @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Setup.ps1'),'-Mode',$Mode,'-Preset',$Preset)
if ($ProjectRoot) { $setupArgs += @('-ProjectRoot',$ProjectRoot) }
if ($ProjectsFile) { $setupArgs += @('-ProjectsFile',$ProjectsFile) }
if ($RepositoriesFile) { $setupArgs += @('-RepositoriesFile',$RepositoriesFile) }
if ($ChooseRepositories) { $setupArgs += '-ChooseRepositories' }
& $pwshPath @setupArgs
exit $LASTEXITCODE
} catch {
    Write-Warning "dev-setup bootstrap could not complete: $($_.Exception.Message)"
    exit 1
}
