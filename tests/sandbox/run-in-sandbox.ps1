# Runs inside Windows Sandbox at logon. Follows docs/CLEAN-MACHINE-TEST.md steps 1-5 (core preset)
# against a published release ZIP and writes results to the mapped C:\results folder.
param([Parameter(Mandatory)][string] $ArchiveUri)
$ErrorActionPreference = 'Continue'
$out = 'C:\results'
Start-Transcript -Path (Join-Path $out 'run.log') -Force | Out-Null
$steps = [ordered]@{}
function Step([string] $name, [scriptblock] $body) {
    Write-Host "`n===== $name ====="
    try { $global:LASTEXITCODE = 0; & $body; $steps[$name] = if ($LASTEXITCODE) { "exit $LASTEXITCODE" } else { 'ok' } }
    catch { $steps[$name] = "error: $($_.Exception.Message)"; Write-Host $_ }
    Write-Host "----- $name -> $($steps[$name])"
}
function Get-Footprint {
    @(
        "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
        "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
        "$env:LOCALAPPDATA\TerminalDevSetup",
        "$env:LOCALAPPDATA\DevSetup",
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "$env:ProgramFiles\Git\cmd\git.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ }
}

$os = Get-CimInstance Win32_OperatingSystem
$info = [ordered]@{ Caption = $os.Caption; Build = $os.BuildNumber; Arch = $env:PROCESSOR_ARCHITECTURE; User = $env:USERNAME
    WinGetPresent = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue); FootprintBefore = @(Get-Footprint) }
$info | Format-List | Out-String | Write-Host

$src = 'C:\devsetup'
Step 'download-release' {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $env:TEMP 'dev-setup.zip'
    Write-Host "Release: $ArchiveUri"
    Invoke-WebRequest -Uri $ArchiveUri -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $src -Force
    $script:root = (Get-ChildItem -LiteralPath $src -Recurse -Filter bootstrap.ps1 | Select-Object -First 1).DirectoryName
    Write-Host "Source: $script:root"
}

Step 'plan-makes-no-changes' {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script:root\bootstrap.ps1" -Mode Plan
    $after = @(Get-Footprint)
    $new = @($after | Where-Object { $_ -notin $info.FootprintBefore })
    if ($new) { throw "Plan created: $($new -join ', ')" }
}

Step 'apply-core' {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script:root\bootstrap.ps1" -Mode Apply -RepairWinGet
}

# Fresh process with refreshed PATH, as a new shell would see it.
$env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'

Step 'doctor' {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File "$script:root\Setup.ps1" -Mode Doctor -Json | Tee-Object -FilePath (Join-Path $out 'doctor.json')
}

Step 'second-plan-is-clean' {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File "$script:root\Setup.ps1" -Mode Plan -Json | Tee-Object -FilePath (Join-Path $out 'plan-after.json')
}

Step 'workspace-commands' {
    & $pwsh -NoLogo -ExecutionPolicy Bypass -Command '. $PROFILE; ai-doctor | Format-Table -AutoSize | Out-String -Width 200; $p = ai-workspace -Path $HOME -Preview; "preview executable: $($p.Executable)"'
}

$info.FootprintAfter = @(Get-Footprint)
[ordered]@{ Info = $info; Steps = $steps; Finished = (Get-Date).ToString('o') } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'summary.json') -Encoding UTF8
Stop-Transcript | Out-Null
Set-Content (Join-Path $out 'DONE') 'done'
