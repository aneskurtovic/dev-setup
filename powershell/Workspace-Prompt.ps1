# Captures the previous command's success before running Git or other commands.
function global:prompt {
    $succeeded = $?
    $savedExit = $global:LASTEXITCODE
    $location = Get-Location
    $name = Split-Path -Leaf $location.Path
    if (!$name) { $name = $location.Path }
    $gitLabel = ''
    try {
        if ($location.Provider.Name -eq 'FileSystem' -and (Get-Command git -ErrorAction SilentlyContinue)) {
            $ErrorActionPreference = 'SilentlyContinue'
            $PSNativeCommandUseErrorActionPreference = $false
            $state = @(& git --no-optional-locks -C $location.Path status --porcelain=v1 --branch 2>$null)
            if ($LASTEXITCODE -eq 0 -and $state.Count) {
                $branch = ($state[0] -replace '^## (?:No commits yet on |Initial commit on )?', '') -replace '\.\.\..*$', ''
                if ($branch -match '^HEAD ') { $branch = '@' + (& git -C $location.Path rev-parse --short HEAD 2>$null) }
                if ($branch.Length -gt 28) { $branch = $branch.Substring(0,25) + '...' }
                $dirty = if ($state.Count -gt 1) { '*' } else { '' }
                $gitLabel = " [$branch$dirty]"
            }
        }
    } catch {} finally { $global:LASTEXITCODE = $savedExit }
    $failure = if (!$succeeded) { if ($savedExit) { " !exit:$savedExit" } else { ' !failed' } } else { '' }
    if ($Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected) {
        $esc = [char]27
        return "${esc}[36m$name${esc}[32m$gitLabel${esc}[31m$failure${esc}[0m > "
    }
    return "$name$gitLabel$failure > "
}
