#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$originalPath = $env:PATH
try {
    if (!(Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        # Fixture-only executable resolution. No test executes this as Terminal.
        $fixtureBin = Join-Path ([IO.Path]::GetTempPath()) ('dev-setup-bin-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixtureBin
        Copy-Item -LiteralPath "$env:SystemRoot/System32/where.exe" -Destination (Join-Path $fixtureBin 'wt.exe')
        $env:PATH = $fixtureBin + ';' + $env:PATH
        Write-Host 'Using a Terminal executable-resolution fixture; this is not a clean-machine provisioning test.'
    }
    & pwsh -NoProfile -File "$PSScriptRoot/Test-Workspace.ps1"
    if ($LASTEXITCODE) { throw 'Workspace tests failed.' }
    & pwsh -NoProfile -File "$PSScriptRoot/Test-WorkspaceStartup.ps1"
    if ($LASTEXITCODE) { throw 'Workspace startup tests failed.' }
    & pwsh -NoProfile -File "$PSScriptRoot/Test-Setup.ps1"
    if ($LASTEXITCODE) { throw 'Setup tests failed.' }
    & pwsh -NoProfile -File "$PSScriptRoot/Test-Orchestration.ps1"
    if ($LASTEXITCODE) { throw 'Orchestration tests failed.' }
    & pwsh -NoProfile -File "$PSScriptRoot/Test-RuntimeHealth.ps1"
    if ($LASTEXITCODE) { throw 'Runtime health tests failed.' }
    & pwsh -NoProfile -File "$PSScriptRoot/Test-ProjectCommands.ps1"
    if ($LASTEXITCODE) { throw 'Project command tests failed.' }
    & pwsh -NoProfile -File "$PSScriptRoot/Test-Repositories.ps1"
    if ($LASTEXITCODE) { throw 'Repository tests failed.' }
    & pwsh -NoProfile -File "$PSScriptRoot/Test-Quickstart.ps1"
    if ($LASTEXITCODE) { throw 'Quickstart test failed.' }
    & node --check "$PSScriptRoot/../claude/statusline.js"
    if ($LASTEXITCODE) { throw 'Renderer syntax failed.' }
} finally { $env:PATH = $originalPath }
