#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Plan','Apply','Doctor')][string] $Mode = 'Apply',
    [string] $ArchiveUri = 'https://github.com/aneskurtovic/dev-setup/archive/refs/tags/v0.3.2-preview.zip'
)
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
try {
if ($env:OS -ne 'Windows_NT' -or [Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'dev-setup currently targets Windows 11.'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$stage = Join-Path ([IO.Path]::GetTempPath()) ('dev-setup-' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $stage 'source.zip'
$extracted = Join-Path $stage 'source'
$null = New-Item -ItemType Directory -Path $stage,$extracted -Force
if (Test-Path -LiteralPath $ArchiveUri -PathType Leaf) {
    Copy-Item -LiteralPath $ArchiveUri -Destination $archive
} else {
    Invoke-WebRequest -Uri $ArchiveUri -OutFile $archive -UseBasicParsing
}
Expand-Archive -LiteralPath $archive -DestinationPath $extracted
$bootstraps = @(Get-ChildItem -LiteralPath $extracted -Recurse -File -Filter bootstrap.ps1)
if ($bootstraps.Count -ne 1) { throw 'The downloaded release did not contain exactly one bootstrap.ps1.' }
Write-Host "Starting dev-setup $Mode from $($bootstraps[0].DirectoryName)"
$legacyPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
& $legacyPowerShell -NoProfile -ExecutionPolicy Bypass -File $bootstraps[0].FullName -Mode $Mode -Preset developer
if ($LASTEXITCODE -ne 0) {
    $setupExitCode = $LASTEXITCODE
    Write-Warning "dev-setup $Mode is incomplete. Follow the recovery steps and run report above, then rerun this command."
    if ($PSCommandPath) { exit $setupExitCode }
    $global:LASTEXITCODE = $setupExitCode
    return
}
} catch {
    Write-Warning "dev-setup could not complete: $($_.Exception.Message)"
    Write-Warning 'Check the download URL, network access, and installer permissions, then rerun. Completed changes are retained.'
    if ($PSCommandPath) { exit 1 }
    $global:LASTEXITCODE = 1
} finally { $ErrorActionPreference = $previousErrorActionPreference }
