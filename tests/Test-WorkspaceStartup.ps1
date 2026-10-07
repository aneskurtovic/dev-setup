#requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('dev-setup-startup-' + [guid]::NewGuid().ToString('N'))
$bin=Join-Path $scratch 'bin'
$null=New-Item -ItemType Directory -Path $bin
$originalPath=$env:PATH
$script:passed=0
function Assert($Condition,$Message) {
    if (!$Condition) { throw "FAIL: $Message" }
    $script:passed++; Write-Host "PASS: $Message"
}
try {
    foreach ($name in @('startup-executable.cmd','startup-script.ps1','startup-normalcc.CMD')) {
        Set-Content -LiteralPath (Join-Path $bin $name) 'fixture; never executed'
    }
    $env:PATH="$bin;$bin;$(Join-Path $scratch 'missing')"
    function global:startup-existing { 'preserved' }
    $registry=Join-Path $scratch 'projects.json'
    @{schemaVersion=1;projects=@(foreach ($name in @('startup-existing','startup-executable','startup-script','startup-normal')) {
        @{command=$name;displayName=$name;path=$scratch;enabled=$true;replaceNavigation=$false;aliases=@()}
    })} | ConvertTo-Json -Depth 5 | Set-Content $registry
    $warnings=@(Import-Module "$repo/powershell/TerminalWorkspace.psm1" -ArgumentList $registry -Force -DisableNameChecking 3>&1)
    Assert ((startup-existing) -eq 'preserved') 'Startup preserves an existing shell function without replacement permission'
    Assert (!(Get-Command startup-executable -CommandType Function -ListImported -ErrorAction SilentlyContinue)) 'Executable conflicts remain protected with batched discovery'
    Assert (!(Get-Command startup-script -CommandType Function -ListImported -ErrorAction SilentlyContinue)) 'PowerShell script conflicts remain protected with batched discovery'
    Assert (!(Get-Command startup-normalcc -CommandType Function -ListImported -ErrorAction SilentlyContinue)) 'Agent shortcut conflicts preserve executable names regardless of extension case'
    Assert ([bool](Get-Command startup-normal -CommandType Function -ListImported -ErrorAction SilentlyContinue)) 'A conflicting agent shortcut does not block the project navigation function'
    Assert ($warnings.Count -eq 4) 'Each protected conflict reports a warning'
    $module=Get-Module TerminalWorkspace
    $discovery = & $module {
        function Get-Command {
            param($Name,[switch]$ListImported,[switch]$All,$CommandType)
            if ($Name -or !$ListImported -or !$All) { throw 'Startup must snapshot imported commands without per-name discovery' }
            $script:discoveryCalls++
            [pscustomobject]@{Name='startup-existing';ModuleName='fixture';CommandType='Function'}
        }
        $script:discoveryCalls=0
        $names=@('startup-existing','startup-executable','startup-script') + @(1..100 | ForEach-Object { 'startup-missing-' + $_ })
        $conflicts=Get-WorkspaceCommandConflicts $names
        [pscustomobject]@{Calls=$script:discoveryCalls;Conflicts=$conflicts}
    }
    Assert ($discovery.Calls -eq 1) 'Command discovery runs once even with more than one hundred candidate names'
    Assert ($discovery.Conflicts.Count -eq 3 -and $discovery.Conflicts['startup-executable'].CommandType -eq 'Application' -and $discovery.Conflicts['startup-script'].CommandType -eq 'ExternalScript') 'The startup snapshot retains only real shell and PATH conflicts'
} finally {
    $env:PATH=$originalPath
    Remove-Module TerminalWorkspace -ErrorAction SilentlyContinue
    Remove-Item Function:\startup-existing -ErrorAction SilentlyContinue
}
Write-Host "All $script:passed workspace startup checks passed."
