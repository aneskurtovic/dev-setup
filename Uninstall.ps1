#requires -Version 7.2
[CmdletBinding()]
param([string] $InstallRoot = $PSScriptRoot, [switch] $Preview)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$mutexName = 'Local\DevSetup-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($InstallRoot.ToLowerInvariant())))
$mutex = [Threading.Mutex]::new($false, $mutexName)
$ownsMutex = $false
try {
try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
if (!$ownsMutex) { throw 'Another workspace install or rollback is running.' }
$manifestPath = Join-Path $InstallRoot 'installation.json'
if (!(Test-Path -LiteralPath $manifestPath)) { throw "No installation manifest: $manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$settingsHelper = Join-Path $InstallRoot 'TerminalSettings.ps1'
if (Test-Path -LiteralPath $settingsHelper) { . $settingsHelper }

function ConvertTo-CanonicalValue($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in $Value.Keys | Sort-Object) { $ordered[$key] = ConvertTo-CanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value | ForEach-Object { ConvertTo-CanonicalValue $_ })
        return ,$items
    }
    return $Value
}

function Test-TerminalGeneratedSettings($Entry) {
    # Terminal persists these fragment registrations itself on first launch.
    # Accept that known transformation, but still refuse unrelated user edits.
    if ($Entry.PSObject.Properties['installedContent'] -and $Entry.installedContent -and (Test-Path -LiteralPath $settingsHelper)) {
        return Test-TerminalSettingsEquivalent $Entry.installedContent ([IO.File]::ReadAllText($Entry.path))
    }
    if (!$Entry.existed -or $Entry.path -notmatch '[/\\]settings\.json$' -or !(Test-Path -LiteralPath $Entry.backup)) { return $false }
    try {
        $before = Get-Content -LiteralPath $Entry.backup -Raw | ConvertFrom-Json -AsHashtable
        $after = Get-Content -LiteralPath $Entry.path -Raw | ConvertFrom-Json -AsHashtable
        if ($after.defaultProfile -ne '{74e2e943-2c73-4bd0-b06c-f21ec11b6386}') { return $false }
        $names = @{
            '{872dfbd8-fd1f-4ebe-b77e-051f87599dc0}' = 'Dev Codex'
            '{70192e26-44aa-4be9-b659-90b754f50f96}' = 'Dev Claude'
            '{74e2e943-2c73-4bd0-b06c-f21ec11b6386}' = 'Dev PowerShell'
        }
        foreach ($profile in $after.profiles.list | Where-Object { $_.source -eq 'TerminalDevSetup' }) {
            if (!$names.ContainsKey($profile.guid) -or $profile.name -ne $names[$profile.guid] -or $profile.hidden -ne $false) { return $false }
            if (($profile.Keys | Sort-Object) -join ',' -ne 'guid,hidden,name,source') { return $false }
        }
        $after.profiles.list = @($after.profiles.list | Where-Object { $_.source -ne 'TerminalDevSetup' })
        if ($before.ContainsKey('defaultProfile')) { $after.defaultProfile = $before.defaultProfile }
        else { $after.Remove('defaultProfile') }
        # Terminal may reorder keybindings on serialization. Order is immaterial
        # only when each chord is unique; duplicate bindings remain protected.
        foreach ($settings in @($before, $after)) {
            if ($settings.ContainsKey('keybindings')) {
                $chords = @($settings.keybindings | ForEach-Object { $_.keys | ConvertTo-Json -Compress })
                if (@($chords | Select-Object -Unique).Count -ne $chords.Count) { return $false }
                $settings.keybindings = @($settings.keybindings | Sort-Object { $_.keys | ConvertTo-Json -Compress })
            }
        }
        $originalJson = ConvertTo-CanonicalValue $before | ConvertTo-Json -Depth 100 -Compress
        $currentJson = ConvertTo-CanonicalValue $after | ConvertTo-Json -Depth 100 -Compress
        return $originalJson -eq $currentJson
    } catch { return $false }
}

# Refuse to overwrite subsequent edits, and check every file before changing any.
foreach ($entry in $manifest.files) {
    if (!$entry.installedHash) { throw "Incomplete installation: $($entry.path). Reconcile manually using backups; no files restored." }
    if (!(Test-Path -LiteralPath $entry.path)) { throw "Changed since installation: missing $($entry.path). No files restored." }
    if ((Test-Path -LiteralPath $entry.path) -and $entry.installedHash) {
        if ((Get-FileHash -LiteralPath $entry.path -Algorithm SHA256).Hash -ne $entry.installedHash -and !(Test-TerminalGeneratedSettings $entry)) {
            throw "Changed since installation: $($entry.path). Preserve/reconcile your edits using '$manifestPath' before rollback. No files restored."
        }
    }
    if ($entry.existed -and !(Test-Path -LiteralPath $entry.backup)) { throw "Backup missing: $($entry.backup)" }
}
foreach ($entry in $manifest.files) {
    if ($Preview) { [pscustomobject]@{ Path = $entry.path; Action = if ($entry.existed) { 'Restore original bytes' } else { 'Remove installed file' } }; continue }
    if ($entry.existed) {
        Copy-Item -LiteralPath $entry.backup -Destination $entry.path -Force
    } elseif (Test-Path -LiteralPath $entry.path) {
        Remove-Item -LiteralPath $entry.path
    }
}
if (!$Preview) {
    Move-Item -LiteralPath $manifestPath -Destination (Join-Path $InstallRoot ('uninstalled-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-ffff') + '.json'))
    Write-Host 'Original configuration restored. Backups retained. Open a new PowerShell session.'
}
} finally { if ($ownsMutex) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
