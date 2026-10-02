#requires -Version 5.1
# Starts a disposable Windows Sandbox that runs the core clean-machine test against the release
# quickstart.ps1 points at. Results land in test-results/sandbox; a DONE file marks completion.
[CmdletBinding()]
param([string] $OutDir = (Join-Path $PSScriptRoot '../../test-results/sandbox'))
$ErrorActionPreference = 'Stop'
$sandbox = Join-Path $env:SystemRoot 'System32/WindowsSandbox.exe'
if (!(Test-Path -LiteralPath $sandbox)) {
    throw 'Windows Sandbox is not enabled. As administrator run: Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All, then restart.'
}
$quickstart = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../quickstart.ps1') -Raw
if ($quickstart -notmatch "\`$ArchiveUri = '([^']+)'") { throw 'Could not read the release ArchiveUri from quickstart.ps1.' }
$archiveUri = $Matches[1]

$OutDir = [IO.Path]::GetFullPath($OutDir)
$results = Join-Path $OutDir 'out'
if (Test-Path -LiteralPath $results) { Remove-Item -LiteralPath $results -Recurse -Force }
$null = New-Item -ItemType Directory -Path $results -Force
$esc = { param($s) [Security.SecurityElement]::Escape($s) }
$config = @"
<Configuration>
  <Networking>Enable</Networking>
  <MemoryInMB>8192</MemoryInMB>
  <MappedFolders>
    <MappedFolder><HostFolder>$(& $esc ([IO.Path]::GetFullPath($PSScriptRoot)))</HostFolder><SandboxFolder>C:\kit</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$(& $esc $results)</HostFolder><SandboxFolder>C:\results</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\kit\run-in-sandbox.ps1 -ArchiveUri "$(& $esc $archiveUri)"</Command>
  </LogonCommand>
</Configuration>
"@
$wsb = Join-Path $OutDir 'devsetup.wsb'
Set-Content -LiteralPath $wsb -Value $config -Encoding UTF8
Start-Process -FilePath $sandbox -ArgumentList "`"$wsb`""
Write-Host "Sandbox started for $archiveUri"
Write-Host "Results: $results (summary.json, run.log, doctor.json; DONE when finished)"
