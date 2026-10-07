param([string] $RegistryPath = (Join-Path $PSScriptRoot 'projects.json'))

Set-StrictMode -Version Latest
$script:RegistryPath = $RegistryPath
$script:Profiles = @{
    codex = '{872dfbd8-fd1f-4ebe-b77e-051f87599dc0}'
    claude = '{70192e26-44aa-4be9-b659-90b754f50f96}'
    terminal = '{74e2e943-2c73-4bd0-b06c-f21ec11b6386}'
}
$script:Actions = @('ai-workspace', 'ai-workspace-resume', 'ai-workspace-agents', 'codex', 'claude', 'terminal', 'help', '?')

function Read-WorkspaceRegistry {
    if (!(Test-Path -LiteralPath $script:RegistryPath)) { return @() }
    try { $data = Get-Content -LiteralPath $script:RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid project registry '$script:RegistryPath': $($_.Exception.Message)" }
    if ($data.schemaVersion -ne 1) { throw "Unsupported schemaVersion in '$script:RegistryPath'. Expected 1." }
    $names = @{}
    foreach ($project in $data.projects) {
        foreach ($required in @('command','displayName','path','enabled','replaceNavigation','aliases')) {
            if (!$project.PSObject.Properties[$required]) { throw "Missing '$required' in '$script:RegistryPath'." }
        }
        if ($project.enabled -isnot [bool] -or $project.replaceNavigation -isnot [bool]) {
            throw "Registry enabled and replaceNavigation properties must be booleans."
        }
        if ([string]::IsNullOrWhiteSpace($project.displayName) -or ![IO.Path]::IsPathRooted($project.path)) {
            throw "Project '$($project.command)' needs a displayName and an absolute path in '$script:RegistryPath'."
        }
        $entryNames = @($project.command) + @($project.aliases)
        foreach ($name in $entryNames + @($entryNames | ForEach-Object { ($_ + 'cc'), ($_ + 'cx') })) {
            if ($name -notmatch '^[a-z][a-z0-9-]*$' -or $names.ContainsKey($name)) {
                throw "Invalid or duplicate project command '$name' in '$script:RegistryPath'."
            }
            if ($name -in @('ai-workspace','ai-workspace-resume','ai-workspace-agents','ai-projects','ai-doctor','Invoke-AiProject','Get-AiProject','Test-AiWorkspace','Resolve-AiProjectRoot')) {
                throw "Reserved project command '$name'."
            }
            $names[$name] = $true
        }
    }
    return @($data.projects)
}

function Get-AiProject {
    [CmdletBinding()]
    param([switch] $All)
    foreach ($project in Read-WorkspaceRegistry) {
        if ($All -or $project.enabled) {
            [pscustomobject]@{
                Command = $project.command; DisplayName = $project.displayName
                Path = $project.path; Enabled = $project.enabled
                Exists = Test-Path -LiteralPath $project.path -PathType Container
                Aliases = $project.aliases -join ', '
            }
        }
    }
}

function Resolve-AiProjectRoot {
    [CmdletBinding()]
    param([string] $Path = (Get-Location).Path, [switch] $Exact)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (!$item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem') {
        throw "Project path must be a filesystem directory: $Path"
    }
    $resolved = $item.FullName
    if (!$Exact -and (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        # PS 5.1 treats redirected native stderr as a terminating error under Stop.
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $PSNativeCommandUseErrorActionPreference = $false
            $root = & git -C $resolved rev-parse --show-toplevel 2>$null
            $gitExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $savedErrorPreference }
        if ($gitExit -eq 0 -and $root) { $resolved = (Get-Item -LiteralPath $root -ErrorAction Stop).FullName }
    }
    # wt treats semicolons as action separators, including in directory arguments.
    if ($resolved.Contains(';')) { throw "Windows Terminal workspace paths cannot contain semicolons: $resolved" }
    return $resolved
}

function Get-WorkspacePreferences {
    param([string] $Root, [string] $DisplayName)
    $prefs = @{ DisplayName = $DisplayName; CodexFraction = 0.5; ClaudeFraction = 0.5 }
    $files = @(@('scripts/terminal-workspace.json', 'terminal-workspace.json') |
        ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if ($files.Count -gt 1) { throw "Multiple workspace configuration files in '$Root'. Keep only scripts/terminal-workspace.json or terminal-workspace.json." }
    if ($files.Count -eq 1) {
        $file = $files[0]
        try {
            $config = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($config.schemaVersion -ne 1) { throw 'schemaVersion must be 1' }
            foreach ($property in $config.PSObject.Properties.Name) {
                if ($property -notin @('schemaVersion','id','displayName','layout')) { throw "Unknown property '$property'" }
            }
            if ($config.PSObject.Properties['displayName']) {
                if ($config.displayName -isnot [string] -or [string]::IsNullOrWhiteSpace($config.displayName)) { throw 'displayName must be a nonempty string' }
                $prefs.DisplayName = $config.displayName
            }
            if ($config.PSObject.Properties['layout']) {
                foreach ($property in $config.layout.PSObject.Properties) {
                    if ($property.Name -notin @('codexFraction','claudeFraction')) { throw "Unknown layout property '$($property.Name)'" }
                    if ($property.Value -is [string] -or $property.Value -is [bool] -or $null -eq $property.Value) { throw "$($property.Name) must be a number" }
                    $value = [double] $property.Value
                    if ([double]::IsNaN($value) -or $value -lt 0.2 -or $value -gt 0.8) { throw "$($property.Name) must be between 0.2 and 0.8" }
                    $prefs[$property.Name] = $value
                }
            }
        } catch { throw "Invalid workspace configuration '$file': $($_.Exception.Message)" }
    }
    if ([string]::IsNullOrWhiteSpace($prefs.DisplayName)) { $prefs.DisplayName = (Get-Item -LiteralPath $Root).Name }
    if ($prefs.DisplayName -match '[;\r\n\x00-\x1f]') { throw 'Workspace displayName cannot contain semicolons or control characters.' }
    return $prefs
}

function Get-WorkspaceExecutable {
    param([string] $Name)
    $command = Get-Command $Name -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$command) { throw "Required command '$Name' is unavailable. Install it or add it to PATH, then run ai-doctor." }
    return $command.Source
}

function New-WorkspacePaneArguments {
    param([string] $Role, [string] $Root, [string] $DisplayName, [string] $PowerShell, [string] $SessionMode = 'new')
    $payload = @{ root = $Root; displayName = $DisplayName; role = $Role; sessionMode = $SessionMode } | ConvertTo-Json -Compress
    $payload64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $paneScript = (Join-Path $PSScriptRoot 'Start-Pane.ps1').Replace("'", "''")
    $code = "& '$paneScript' -Payload '$payload64'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $label = if ($Role -eq 'terminal') { 'TERMINAL' } else { $Role.ToUpperInvariant() }
    $title = '{0} - {1}' -f $DisplayName, $label.Substring(0,1) + $label.Substring(1).ToLowerInvariant()
    @('-p', $script:Profiles[$Role], '-d', $Root, '--title', $title, '--suppressApplicationTitle',
      $PowerShell, '-NoLogo', '-NoExit', '-EncodedCommand', $encoded)
}

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string] $Value)
    # CommandLineToArgvW/CRT quoting for the .NET Framework fallback in PS 5.1.
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-WorkspaceTerminal {
    [CmdletBinding()]
    param([string] $Root, [string] $DisplayName, [string] $Action, [switch] $Preview)
    $wt = Get-WorkspaceExecutable 'wt.exe'
    $pwsh = Get-WorkspaceExecutable 'pwsh.exe'
    # Agent CLIs are optional: Start-Pane reports a missing CLI inside its shell.
    $prefs = Get-WorkspacePreferences -Root $Root -DisplayName $DisplayName
    $arguments = @('-w', '-1', '--maximized', 'new-tab')
    if ($Action -in @('ai-workspace','ai-workspace-resume','ai-workspace-agents')) {
        $sessionMode = switch ($Action) { 'ai-workspace-resume' {'resume'} 'ai-workspace-agents' {'agents'} default {'new'} }
        $arguments += New-WorkspacePaneArguments claude $Root $prefs.DisplayName $pwsh $sessionMode
        $right = (1.0 - $prefs.ClaudeFraction).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
        $bottom = (1.0 - $prefs.CodexFraction).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
        $arguments += @(';', 'split-pane', '-V', '-s', $right)
        $arguments += New-WorkspacePaneArguments codex $Root $prefs.DisplayName $pwsh $sessionMode
        $arguments += @(';', 'split-pane', '-H', '-s', $bottom)
        $arguments += New-WorkspacePaneArguments terminal $Root $prefs.DisplayName $pwsh $sessionMode
        $arguments += @(';', 'move-focus', 'first')
    } else {
        $arguments += New-WorkspacePaneArguments $Action $Root $prefs.DisplayName $pwsh
    }
    if ($Preview) {
        return [pscustomobject]@{ Executable = $wt; Arguments = $arguments; Root = $Root; DisplayName = $prefs.DisplayName; Action = $Action }
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $wt
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    if ($start.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    } else {
        $start.Arguments = ($arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    }
    $process = [Diagnostics.Process]::Start($start)
    if ($process.WaitForExit(3000) -and $process.ExitCode -ne 0) { throw "Windows Terminal exited with code $($process.ExitCode). Run ai-doctor." }
    $process.Dispose()
}

function ai-workspace {
    [CmdletBinding()]
    param([string] $Path = (Get-Location).Path, [switch] $Preview)
    $root = Resolve-AiProjectRoot -Path $Path
    Start-WorkspaceTerminal -Root $root -Action ai-workspace -Preview:$Preview
}

function ai-workspace-resume {
    [CmdletBinding()]
    param([string] $Path = (Get-Location).Path, [switch] $Preview)
    $root = Resolve-AiProjectRoot -Path $Path
    Start-WorkspaceTerminal -Root $root -Action ai-workspace-resume -Preview:$Preview
}

function ai-workspace-agents {
    [CmdletBinding()]
    param([string] $Path = (Get-Location).Path, [switch] $Preview)
    $root = Resolve-AiProjectRoot -Path $Path
    Start-WorkspaceTerminal -Root $root -Action ai-workspace-agents -Preview:$Preview
}

function Invoke-AiProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name, [string] $Action, [switch] $Preview)
    $project = @(Read-WorkspaceRegistry | Where-Object { $_.command -eq $Name -or $Name -in $_.aliases })
    if ($project.Count -ne 1) { throw "Unknown project '$Name'. Run ai-projects -All." }
    $project = $project[0]
    if (!$project.enabled) { throw "Project '$Name' is registered but disabled. Run ai-projects -All." }
    if ($Action -in @('help','?')) {
        return "$Name : change this shell to $($project.path)`nActions: ai-workspace, ai-workspace-resume, ai-workspace-agents, codex, claude, terminal, help`nShortcuts: ${Name}cc (Claude), ${Name}cx (Codex)`nAdd -Preview to inspect a launch without opening a window."
    }
    if ($Action -and $Action -notin $script:Actions) { throw "Unknown $Name action '$Action'. Available: $($script:Actions -join ', ')." }
    if (!(Test-Path -LiteralPath $project.path -PathType Container)) { throw "Configured project path does not exist: $($project.path)" }
    $root = Resolve-AiProjectRoot -Path $project.path -Exact
    if (!$Action) { Set-Location -LiteralPath $root; return }
    Start-WorkspaceTerminal -Root $root -DisplayName $project.displayName -Action $Action -Preview:$Preview
}

function Test-AiWorkspace {
    [CmdletBinding()]
    param()
    foreach ($name in @('wt.exe','pwsh.exe','git','codex','claude')) {
        $command = Get-Command $name -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
        [pscustomobject]@{ Check = $name; OK = [bool] $command; Detail = if ($command) { $command.Source } else { 'Missing from PATH' } }
    }
    foreach ($project in Get-AiProject -All) {
        [pscustomobject]@{ Check = $project.Command; OK = $project.Exists; Detail = "$($project.Path) (enabled: $($project.Enabled))" }
    }
    $fragment = Join-Path $env:LOCALAPPDATA 'Microsoft/Windows Terminal/Fragments/TerminalDevSetup/workspace.json'
    [pscustomobject]@{ Check = 'Terminal profiles'; OK = Test-Path -LiteralPath $fragment; Detail = $fragment }
}

function Get-WorkspaceCommandConflicts([string[]] $Names) {
    # A missing-name Get-Command lookup is expensive on Windows. Snapshot loaded
    # shell commands once, then inspect each PATH directory once for executable conflicts.
    $wanted = @{}
    foreach ($name in $Names) { $wanted[$name] = $true }
    $conflicts = @{}
    foreach ($command in Get-Command -ListImported -All -CommandType Alias,Function,Cmdlet) {
        if ($wanted.ContainsKey($command.Name) -and !$conflicts.ContainsKey($command.Name)) {
            $conflicts[$command.Name] = $command
        }
    }
    $files = @{}
    $extensions = @('', '.ps1') + @($env:PATHEXT -split ';' | Where-Object { $_ })
    foreach ($name in $Names) {
        if ($conflicts.ContainsKey($name)) { continue }
        foreach ($extension in $extensions) { $files[$name + $extension] = $name }
    }
    if ($files.Count) {
        foreach ($directory in @($env:PATH -split ';' | Where-Object { $_ } | Select-Object -Unique)) {
            try {
                $directory = [Environment]::ExpandEnvironmentVariables($directory.Trim('"'))
                foreach ($path in [IO.Directory]::EnumerateFiles($directory)) {
                    $fileName = [IO.Path]::GetFileName($path)
                    if (!$files.ContainsKey($fileName)) { continue }
                    $name = $files[$fileName]
                    if (!$conflicts.ContainsKey($name)) {
                        $conflicts[$name] = [pscustomobject]@{ModuleName='';CommandType=if ([IO.Path]::GetExtension($path) -ieq '.ps1') {'ExternalScript'} else {'Application'};Source=$path}
                    }
                }
            } catch [IO.IOException] {} catch [UnauthorizedAccessException] {} catch [ArgumentException] {}
        }
    }
    return $conflicts
}

$registeredProjects = @(Read-WorkspaceRegistry)
$registrationNames = @(foreach ($project in $registeredProjects) {
    if (!$project.enabled) { continue }
    foreach ($name in @($project.command) + @($project.aliases)) { $name; $name + 'cc'; $name + 'cx' }
})
$commandConflicts = Get-WorkspaceCommandConflicts $registrationNames
$exported = @('ai-workspace','ai-workspace-resume','ai-workspace-agents','Get-AiProject','Invoke-AiProject','Resolve-AiProjectRoot','Test-AiWorkspace')
foreach ($project in $registeredProjects) {
    if (!$project.enabled) { continue }
    foreach ($name in @($project.command) + @($project.aliases)) {
        $existing = $commandConflicts[$name]
        if ($existing -and $existing.ModuleName -ne 'TerminalWorkspace') {
            if (!$project.replaceNavigation -or $existing.CommandType -ne 'Function') {
                Write-Warning "Skipping conflicting command '$name'. Use Invoke-AiProject -Name '$($project.command)'."
                continue
            }
        }
        $body = '[CmdletBinding()] param([Parameter(Position=0)][string] $Action, [switch] $Preview) Invoke-AiProject -Name ''{0}'' -Action $Action -Preview:$Preview' -f $project.command
        Set-Item -Path "Function:script:$name" -Value ([scriptblock]::Create($body))
        $exported += $name
    }
    foreach ($shortcut in @(foreach ($entry in @($project.command) + @($project.aliases)) { @{Name=$entry + 'cc';Action='claude'}, @{Name=$entry + 'cx';Action='codex'} })) {
        $name = $shortcut.Name
        $existing = $commandConflicts[$name]
        if ($existing -and $existing.ModuleName -ne 'TerminalWorkspace') {
            if (!$project.replaceNavigation -or $existing.CommandType -ne 'Function') {
                Write-Warning "Skipping conflicting command '$name'. Use Invoke-AiProject -Name '$($project.command)' -Action '$($shortcut.Action)'."
                continue
            }
        }
        $body = '[CmdletBinding()] param([switch] $Preview) Invoke-AiProject -Name ''{0}'' -Action ''{1}'' -Preview:$Preview' -f $project.command, $shortcut.Action
        Set-Item -Path "Function:script:$name" -Value ([scriptblock]::Create($body))
        $exported += $name
    }
}
Set-Alias ai-projects Get-AiProject
Set-Alias ai-doctor Test-AiWorkspace
Export-ModuleMember -Function $exported -Alias ai-projects,ai-doctor

$completeAction = {
    param($commandName, $parameterName, $wordToComplete)
    foreach ($action in @('ai-workspace','ai-workspace-resume','ai-workspace-agents','codex','claude','terminal','help')) {
        if ($action -like "$wordToComplete*") { [Management.Automation.CompletionResult]::new($action, $action, 'ParameterValue', $action) }
    }
}
foreach ($name in $exported | Where-Object { $_ -notin @('ai-workspace','ai-workspace-resume','ai-workspace-agents','Get-AiProject','Resolve-AiProjectRoot','Test-AiWorkspace') }) {
    Register-ArgumentCompleter -CommandName $name -ParameterName Action -ScriptBlock $completeAction
}
