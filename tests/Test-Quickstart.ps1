#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dev-setup-quickstart-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $scratch 'source/dev-setup-fixture'
$null = New-Item -ItemType Directory -Path $source -Force
$marker = Join-Path $scratch 'invoked.txt'
@'
param([string]$Mode,[string]$Preset)
Set-Content -LiteralPath $env:DEV_SETUP_QUICKSTART_TEST_MARKER -Value "$Mode/$Preset"
'@ | Set-Content -LiteralPath (Join-Path $source 'bootstrap.ps1')
$archive = Join-Path $scratch 'source.zip'
Compress-Archive -Path $source -DestinationPath $archive
$env:DEV_SETUP_QUICKSTART_TEST_MARKER = $marker
try {
    & pwsh -NoProfile -File "$repo/quickstart.ps1" -ArchiveUri $archive
    if ($LASTEXITCODE -ne 0) { throw 'Quickstart did not launch the fixture.' }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'Apply/developer') { throw 'Quickstart passed the wrong mode or preset.' }
    Write-Host 'One-command quickstart fixture passed.'
} finally { Remove-Item Env:DEV_SETUP_QUICKSTART_TEST_MARKER -ErrorAction SilentlyContinue }
