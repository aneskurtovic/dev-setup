[CmdletBinding()]
param([Parameter(Mandatory)][string] $Payload)

$data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
if ($data.role -notin @('codex','claude','terminal')) { throw "Invalid workspace role: $($data.role)" }
$sessionMode = if ($data.PSObject.Properties['sessionMode']) { $data.sessionMode } else { 'new' }
if ($sessionMode -notin @('new','resume','agents')) { throw "Invalid workspace session mode: $sessionMode" }
Set-Location -LiteralPath $data.root -ErrorAction Stop
$env:TERMINAL_DEV_PROJECT = $data.displayName
$env:TERMINAL_DEV_ROLE = $data.role
$label = if ($data.role -eq 'terminal') { 'TERMINAL' } else { $data.role.ToUpperInvariant() }
$color = switch ($data.role) { codex { 'Green' } claude { 'DarkYellow' } default { 'Cyan' } }
Write-Host ("{0} {1} {2}" -f $label, [char]0x00b7, $data.displayName) -ForegroundColor $color
Write-Host $data.root -ForegroundColor DarkGray
if ($data.role -ne 'terminal') {
    $agent = Get-Command $data.role -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$agent) { Write-Error "'$($data.role)' is unavailable in this pane. Run ai-doctor to diagnose PATH."; return }
    if ($sessionMode -eq 'resume') {
        if ($data.role -eq 'codex') { & $agent.Source resume }
        else { & $agent.Source --resume }
    } elseif ($sessionMode -eq 'agents') {
        & $agent.Source agents
    } else { & $agent.Source }
    if ($LASTEXITCODE -ne 0) { Write-Warning "$($data.role) exited with code $LASTEXITCODE. This PowerShell session remains available." }
}
