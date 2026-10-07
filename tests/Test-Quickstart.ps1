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
if ($env:DEV_SETUP_QUICKSTART_TEST_EXIT) { exit ([int]$env:DEV_SETUP_QUICKSTART_TEST_EXIT) }
'@ | Set-Content -LiteralPath (Join-Path $source 'bootstrap.ps1')
$archive = Join-Path $scratch 'source.zip'
Compress-Archive -Path $source -DestinationPath $archive
$env:DEV_SETUP_QUICKSTART_TEST_MARKER = $marker
try {
    & pwsh -NoProfile -File "$repo/quickstart.ps1" -ArchiveUri $archive
    if ($LASTEXITCODE -ne 0) { throw 'Quickstart did not launch the fixture.' }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'Apply/developer') { throw 'Quickstart passed the wrong mode or preset.' }
    Write-Host 'One-command quickstart fixture passed.'
    $env:DEV_SETUP_QUICKSTART_TEST_EXIT = '7'
    $failureOutput = & pwsh -NoProfile -File "$repo/quickstart.ps1" -ArchiveUri $archive 3>&1
    if ($LASTEXITCODE -ne 7 -or ($failureOutput -join "`n") -notmatch 'incomplete' -or ($failureOutput -join "`n") -match 'At line:|CategoryInfo') { throw 'Quickstart did not fail cleanly with the child exit code.' }
    $env:DEV_SETUP_QUICKSTART_TEST_SOURCE = "$repo/quickstart.ps1"
    $env:DEV_SETUP_QUICKSTART_TEST_ARCHIVE = $archive
    $code = @'
$text = Get-Content -LiteralPath $env:DEV_SETUP_QUICKSTART_TEST_SOURCE -Raw
$uri = [regex]::Match($text, 'https://github.com/aneskurtovic/dev-setup/archive/refs/tags/[^'']+\.zip').Value
$text = $text.Replace($uri, $env:DEV_SETUP_QUICKSTART_TEST_ARCHIVE)
$ErrorActionPreference = 'Continue'
$text | Invoke-Expression
if ($LASTEXITCODE -ne 7 -or $ErrorActionPreference -ne 'Continue') { throw 'Inline quickstart lost its exit status or changed the caller preference.' }
[Console]::Write('shell survived')
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $inlineOutput = & "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -EncodedCommand $encoded 2>&1
    if ($LASTEXITCODE -ne 0 -or ($inlineOutput -join "`n") -notmatch 'shell survived') { throw "Inline quickstart terminated the shell: $inlineOutput" }
    $downloadFailure = & pwsh -NoProfile -File "$repo/quickstart.ps1" -ArchiveUri 'not-a-valid-download-uri' 3>&1
    if ($LASTEXITCODE -ne 1 -or ($downloadFailure -join "`n") -notmatch 'could not complete') { throw 'Download failure was not reported cleanly.' }
    Write-Host 'Quickstart failures preserve exit codes, leave an inline shell open, and report recovery guidance.'
} finally {
    foreach ($name in @('DEV_SETUP_QUICKSTART_TEST_MARKER','DEV_SETUP_QUICKSTART_TEST_EXIT','DEV_SETUP_QUICKSTART_TEST_SOURCE','DEV_SETUP_QUICKSTART_TEST_ARCHIVE')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
}
