#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
Import-Module "$repo/powershell/DevSetup.psm1" -Force
$module = Get-Module DevSetup
$script:passed = 0
function Assert($Condition, [string]$Message) {
    if (!$Condition) { throw "FAIL: $Message" }
    $script:passed++; Write-Host "PASS: $Message"
}
# Module-local fakes exercise the real health checks without booting WSL or starting Docker.
$checks = & $module {
    function Get-Command { [pscustomobject]@{Source='wsl.exe'}; [pscustomobject]@{Source='second-wsl.exe'} }
    function Invoke-SetupProcess($File,$Arguments,$TimeoutSeconds) {
        $script:calls += ,@($Arguments)
        if ($File -ne 'wsl.exe') { throw 'Selected more than one executable' }
        switch ($Arguments[0]) {
            '--list' {
                if ($script:listFailure) { return [pscustomobject]@{ExitCode=1;Output='';Error='listing failed'} }
                $output = if ($Arguments[1] -eq '--quiet') { $script:names } else { $script:verbose }
                return [pscustomobject]@{ExitCode=0;Output=$output;Error=''}
            }
            '--distribution' {
                if ($TimeoutSeconds -ne 30 -or ($Arguments -join ' ') -ne '--distribution Ubuntu --exec id -u') { throw 'Unexpected Linux health probe' }
                if ($script:timeout) { throw 'Timed out: wsl.exe' }
                return [pscustomobject]@{ExitCode=$script:linuxCode;Output=$script:uid;Error='Linux diagnostic'}
            }
            default { throw 'Unexpected WSL command' }
        }
    }
    $p = [pscustomobject]@{name='wsl';source='windows';minimumVersion='2.0.0'}
    $script:calls=@(); $script:names="Ubuntu`r`n"; $script:verbose="  NAME STATE VERSION`r`n* Ubuntu Stopped 2`r`n"
    $script:listFailure=$false; $script:timeout=$false; $script:uid="1000`n"; $script:linuxCode=0
    $passive = Get-CorePackageState $p
    [pscustomobject]@{OK=($passive.Status -eq 'Ready' -and $passive.Version -eq '2' -and $script:calls.Count -eq 2);Message='Passive checks determine the distro version without running Linux'}
    $ready = Get-CorePackageState $p -RuntimeHealth
    [pscustomobject]@{OK=($ready.Status -eq 'Ready' -and $ready.Detail -match 'UID 1000');Message='Doctor verifies a successful Linux command under a personal default user'}
    $script:verbose="  NAME STATE VERSION`r`n* Ubuntu Arrêté 1`r`n"; $before=$script:calls.Count
    $old = Get-CorePackageState $p -RuntimeHealth
    [pscustomobject]@{OK=($old.Status -eq 'Incompatible' -and $old.Version -eq '1' -and $old.Detail -match '--set-version Ubuntu 2' -and $script:calls.Count -eq $before+2);Message='WSL 1 is incompatible even with localized state text and is not booted'}
    $script:verbose="  NAME STATE VERSION`r`n  Ubuntu Running 2`r`n"
    $script:uid='0'; $root=Get-CorePackageState $p -RuntimeHealth
    [pscustomobject]@{OK=($root.Status -eq 'NeedsAttention' -and $root.Detail -match 'personal default');Message='A root default account requires personal-user initialization'}
    $script:uid='not a uid'; $invalid=Get-CorePackageState $p -RuntimeHealth
    [pscustomobject]@{OK=($invalid.Status -eq 'NeedsAttention');Message='Malformed Linux output cannot claim runtime readiness'}
    $script:uid='1000'; $script:linuxCode=1; $failure=Get-CorePackageState $p -RuntimeHealth
    [pscustomobject]@{OK=($failure.Status -eq 'NeedsAttention' -and $failure.Detail -match 'Linux diagnostic');Message='Failed Linux commands retain actionable diagnostics'}
    $script:timeout=$true; $timeout=Get-CorePackageState $p -RuntimeHealth
    [pscustomobject]@{OK=($timeout.Status -eq 'NeedsAttention' -and $timeout.Detail -match 'Timed out');Message='Timed-out Linux initialization produces a bounded health failure'}
    $script:timeout=$false; $script:verbose='unreadable'; $unknown=Get-CorePackageState $p
    [pscustomobject]@{OK=($unknown.Status -eq 'Conflict' -and $null -eq $unknown.Version);Message='Unreadable distro versions are not replaced with a hardcoded version'}
    $script:names='Debian'; $missing=Get-CorePackageState $p
    [pscustomobject]@{OK=($missing.Status -eq 'Missing');Message='A different distro does not satisfy the Ubuntu requirement'}
    $script:listFailure=$true; $listing=Get-CorePackageState $p
    [pscustomobject]@{OK=($listing.Status -eq 'Conflict' -and $listing.Detail -match 'listing failed');Message='Failed WSL inspection is unresolved rather than reported as absent'}
}
foreach ($check in $checks) { Assert $check.OK $check.Message }
Remove-Module DevSetup
Import-Module "$repo/powershell/DevSetup.psm1" -Force
$module = Get-Module DevSetup
$checks = & $module {
    function Get-Command { [pscustomobject]@{Source='docker.exe'} }
    function Invoke-SetupProcess($File,$Arguments,$TimeoutSeconds) {
        $script:calls += ,@($Arguments)
        if ($Arguments[0] -eq '--version') { return [pscustomobject]@{ExitCode=0;Output='Docker version 29.0.0';Error=''} }
        if (($Arguments -join ' ') -ne 'version --format {{.Server.Version}}' -or $TimeoutSeconds -ne 15) { throw 'Unexpected Docker engine query' }
        if ($script:timeout) { throw 'Timed out: docker.exe' }
        [pscustomobject]@{ExitCode=$script:engineCode;Output=$script:engineVersion;Error='engine diagnostic'}
    }
    $p=[pscustomobject]@{name='docker';source='winget';id='Docker.DockerDesktop';command='docker.exe';minimumVersion='20.0.0';versionArguments=@('--version')}
    $script:calls=@(); $script:engineCode=0; $script:engineVersion='29.0.0'; $script:timeout=$false
    $passive=Get-CorePackageState $p
    [pscustomobject]@{OK=($passive.Status -eq 'Ready' -and $script:calls.Count -eq 1);Message='Passive Docker checks inspect only the installed CLI'}
    $ready=Get-CorePackageState $p -RuntimeHealth
    [pscustomobject]@{OK=($ready.Status -eq 'Ready' -and $ready.Detail -match 'engine 29.0.0 reachable');Message='Doctor verifies Docker engine connectivity using the current context'}
    $script:engineCode=1; $offline=Get-CorePackageState $p -RuntimeHealth
    [pscustomobject]@{OK=($offline.Status -eq 'NeedsAttention' -and $offline.Detail -match 'Start Docker Desktop' -and $offline.Detail -match 'engine diagnostic');Message='An installed CLI with an unreachable engine needs attention'}
    $script:engineCode=0
    foreach ($value in @('', '<no value>', 'unreadable')) {
        $script:engineVersion=$value; $invalid=Get-CorePackageState $p -RuntimeHealth
        [pscustomobject]@{OK=($invalid.Status -eq 'NeedsAttention');Message="Engine output '$value' cannot claim runtime readiness"}
    }
    $script:timeout=$true; $timeout=Get-CorePackageState $p -RuntimeHealth
    [pscustomobject]@{OK=($timeout.Status -eq 'NeedsAttention' -and $timeout.Detail -match 'Timed out');Message='Docker engine checks time out with recovery guidance'}
}
foreach ($check in $checks) { Assert $check.OK $check.Message }
Remove-Module DevSetup
Write-Host "All $script:passed runtime health checks passed."
