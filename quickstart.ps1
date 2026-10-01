#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Plan','Apply','Doctor')][string] $Mode = 'Apply',
    [string] $ArchiveUri = 'https://github.com/aneskurtovic/dev-setup/archive/refs/tags/v0.3.0-preview.zip'
)
$ErrorActionPreference = 'Stop'
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
if ($LASTEXITCODE -ne 0) { throw "dev-setup $Mode needs attention. Review the report above, then rerun the same command after resolving it or restarting Windows." }
