Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-CoreManifest([string] $Path) {
    $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($data.schemaVersion -ne 1 -or !$data.packages.Count) { throw 'Unsupported or empty package manifest.' }
    $names = @{}
    foreach ($p in $data.packages) {
        if ($p.name -notmatch '^[a-z][a-z0-9-]*$' -or $names.ContainsKey($p.name)) { throw 'Invalid or duplicate package name.' }
        $names[$p.name] = $true
        if ($p.id -notmatch '^[@A-Za-z0-9/._+-]+$' -or $p.source -notin @('winget','npm','windows')) { throw 'Invalid package ID or source.' }
        if ($p.PSObject.Properties['check'] -and $p.check -eq 'registry') {
            if ($p.source -ne 'winget' -or [string]::IsNullOrWhiteSpace($p.displayNamePattern)) { throw 'Invalid registry package check.' }
            $null = [regex]::new($p.displayNamePattern)
        } elseif ($p.command -notmatch '^[a-zA-Z0-9.-]+\.(exe|cmd)$') { throw 'Invalid executable name.' }
        $null = [version] $p.minimumVersion
        $dependencies = if ($p.PSObject.Properties['requires']) { @($p.requires) } else { @() }
        foreach ($dependency in $dependencies) {
            if (!$names.ContainsKey($dependency)) { throw "Package '$($p.name)' has an unknown or later dependency '$dependency'." }
        }
    }
    return @($data.packages)
}

function Update-ProcessPath {
    $paths = @($env:PATH) + @([Environment]::GetEnvironmentVariable('Path','Machine'), [Environment]::GetEnvironmentVariable('Path','User'))
    $env:PATH = (($paths -split ';') | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

function Invoke-SetupProcess([string] $File, [string[]] $Arguments, [int] $TimeoutSeconds = 120) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $isBatch = $File.EndsWith('.cmd',[StringComparison]::OrdinalIgnoreCase)
    $info.FileName = if ($isBatch) { (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source } else { $File }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($isBatch) {
        $payload = @{file=$File;args=@($Arguments)} | ConvertTo-Json -Compress
        $payload64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $code = '$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("' + $payload64 + '"))|ConvertFrom-Json; [string[]]$a=$p.args; & $p.file @a; exit $LASTEXITCODE'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        foreach ($arg in @('-NoProfile','-EncodedCommand',$encoded)) { $info.ArgumentList.Add($arg) }
    } else { foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) } }
    if ([IO.Path]::GetFileName($File) -ieq 'wsl.exe') { $info.StandardOutputEncoding = [Text.Encoding]::Unicode; $info.StandardErrorEncoding = [Text.Encoding]::Unicode }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw "Timed out: $([IO.Path]::GetFileName($File)). Inspect installer state before retrying."
        }
        [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$stdout.GetAwaiter().GetResult(); Error=$stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

function Get-SetupProcessDetail($Result) {
    $detail = (@($Result.Output, $Result.Error) | Where-Object { ![string]::IsNullOrWhiteSpace($_) }) -join "`n"
    $detail = $detail.Trim()
    if ($detail.Length -gt 4000) { $detail = $detail.Substring($detail.Length - 4000) }
    return $detail
}

function Get-CorePackageState($Package) {
    if ($Package.PSObject.Properties['check'] -and $Package.check -eq 'registry') {
        $uninstallPaths = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
        $installed = @(Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $Package.displayNamePattern })
        if (!$installed.Count) { return [pscustomobject]@{Name=$Package.name;Status='Missing';Version=$null;Detail="Install $($Package.id)"} }
        $versions = @($installed | ForEach-Object { [regex]::Match([string]$_.DisplayVersion,'\d+\.\d+(?:\.\d+){0,2}').Value } | Where-Object { $_ } | ForEach-Object { [version]$_ } | Sort-Object -Descending)
        if (!$versions.Count) { return [pscustomobject]@{Name=$Package.name;Status='Conflict';Version=$null;Detail='Installed application has no readable version'} }
        $version = $versions[0]
        return [pscustomobject]@{Name=$Package.name;Status=if ($version -ge [version]$Package.minimumVersion) {'Ready'} else {'Incompatible'};Version=$version.ToString();Detail=$installed[0].DisplayName}
    }
    if ($Package.source -eq 'windows') {
        $wsl = Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (!$wsl) { return [pscustomobject]@{Name=$Package.name;Status='Missing';Version=$null;Detail='WSL and Ubuntu are not available'} }
        try {
            $listed = Invoke-SetupProcess $wsl.Source @('--list','--quiet') 15
            $names = @($listed.Output -split '\r?\n' | ForEach-Object { $_.Trim([char]0,[char]0xfeff,' ') } | Where-Object { $_ })
            if ($listed.ExitCode -eq 0 -and 'Ubuntu' -in $names) { return [pscustomobject]@{Name=$Package.name;Status='Ready';Version='2';Detail='Ubuntu WSL distribution registered'} }
            if ($listed.ExitCode -ne 0 -and $listed.Output -notmatch 'has no installed distributions') {
                return [pscustomobject]@{Name=$Package.name;Status='Conflict';Version=$null;Detail="WSL inspection exited $($listed.ExitCode). $(Get-SetupProcessDetail $listed)"}
            }
            return [pscustomobject]@{Name=$Package.name;Status='Missing';Version=$null;Detail='Ubuntu WSL distribution is not registered'}
        } catch { return [pscustomobject]@{Name=$Package.name;Status='Conflict';Version=$null;Detail=$_.Exception.Message} }
    }
    $command = Get-Command $Package.command -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $Package.name -ne 'ripgrep' -or $_.Source -notmatch '[/\\](?:\.codex|Microsoft VS Code)[/\\]' } |
        Select-Object -First 1
    if (!$command) { return [pscustomobject]@{ Name=$Package.name; Status='Missing'; Version=$null; Detail="Install $($Package.id)" } }
    try {
        if ($Package.name -eq 'terminal') {
            # wt --version can create a GUI dialog. Inspect AppX/file metadata instead.
            $app = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -First 1
            $raw = if ($app) { [string]$app.Version } else { [Diagnostics.FileVersionInfo]::GetVersionInfo($command.Source).ProductVersion }
        } else {
            $result = Invoke-SetupProcess $command.Source $Package.versionArguments 15
            if ($result.ExitCode -ne 0) { throw "Version command exited $($result.ExitCode)" }
            $raw = $result.Output
        }
        $matches = [regex]::Matches([string]$raw, '\d+\.\d+\.\d+(?:\.\d+)?')
        $match = if ($Package.name -eq 'dotnet') { $matches | Sort-Object { [version]$_.Value } -Descending | Select-Object -First 1 } else { $matches | Select-Object -First 1 }
        if (!$match -or !$match.Success) { throw 'Could not determine version; verify the existing installation.' }
        $version = [version]$match.Value
        $status = if ($version -ge [version]$Package.minimumVersion) { 'Ready' } else { 'Incompatible' }
        [pscustomobject]@{ Name=$Package.name; Status=$status; Version=$version.ToString(); Detail=$command.Source }
    } catch {
        if ($Package.name -eq 'python' -and $command.Source -match '[/\\]WindowsApps[/\\]') {
            return [pscustomobject]@{ Name=$Package.name; Status='Missing'; Version=$null; Detail='Windows app execution alias does not point to a working Python installation' }
        }
        [pscustomobject]@{ Name=$Package.name; Status='Conflict'; Version=$null; Detail=$_.Exception.Message }
    }
}

function Install-CorePackage($Package, [switch] $Update) {
    if ($Package.source -eq 'windows') {
        if ($Update) { throw 'WSL upgrades are not automated here. Run wsl --update deliberately.' }
        # Installing a distribution on an existing WSL platform works as the current user.
        # WSL itself requests elevation if Windows features still need enabling.
        $wsl = (Get-Command wsl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $result = Invoke-SetupProcess $wsl @('--install','-d','Ubuntu','--no-launch') 1800
        if ($result.ExitCode -eq 0) {
            $state = Get-CorePackageState $Package
            if ($state.Status -eq 'Ready') { return $state }
            return [pscustomobject]@{Name=$Package.name;Status='NeedsAttention';Version=$null;Detail="Ubuntu is not ready after installation. Launch Ubuntu once to finish initialization, then rerun Apply. $(Get-SetupProcessDetail $result)"}
        } elseif ($result.ExitCode -ne 3010) {
            throw "WSL installation exited $($result.ExitCode). $(Get-SetupProcessDetail $result)"
        }
        return [pscustomobject]@{Name=$Package.name;Status='NeedsRestart';Version=$null;Detail='Restart Windows, launch Ubuntu once to create its user, then rerun Apply.'}
    }
    if ($Package.source -eq 'npm') {
        $npm = Get-Command npm.cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $args = @('install','--global',($Package.id + '@latest'))
        $result = Invoke-SetupProcess $npm.Source $args 1800
        if ($result.ExitCode -ne 0) { throw "npm install for $($Package.id) exited $($result.ExitCode). $(Get-SetupProcessDetail $result)" }
        Update-ProcessPath
        $state = Get-CorePackageState $Package
        if ($state.Status -ne 'Ready') { throw "$($Package.name) is $($state.Status) after npm installation. Open a new shell, then rerun Doctor." }
        return $state
    }
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $verb = if ($Update) { 'upgrade' } else { 'install' }
    $arguments = @($verb,'--id',$Package.id,'--exact','--source',$Package.source,'--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
    if (!$Update) { $arguments += '--no-upgrade' }
    # Do not request automatic reboots or suppress UAC. Native installers handle elevation.
    $result = Invoke-SetupProcess $winget.Source $arguments 1800
    $code = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$result.ExitCode),0)
    if ($code -in @(0x8A150109L,0x8A15010AL,0x8A15010BL,3010L,1641L)) {
        return [pscustomobject]@{ Name=$Package.name; Status='NeedsRestart'; Version=$null; Detail='Save work, restart Windows, then rerun Apply. No automatic restart was requested.' }
    }
    # Already-installed/no-update results are acceptable only if post-verification succeeds.
    if ($code -notin @(0L,0x8A15002BL,0x8A150061L,0x8A15010DL)) {
        throw "WinGet $verb for $($Package.id) exited $($result.ExitCode). $(Get-SetupProcessDetail $result) Logs: $env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir"
    }
    Update-ProcessPath
    $state = Get-CorePackageState $Package
    if ($state.Status -ne 'Ready') { throw "$($Package.name) is $($state.Status) after installation. Open a new shell or resolve installation/restart requirements, then rerun Doctor." }
    return $state
}

Export-ModuleMember -Function Read-CoreManifest,Update-ProcessPath,Invoke-SetupProcess,Get-CorePackageState,Install-CorePackage
