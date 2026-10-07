Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitHub([string[]] $Arguments) {
    $gh = (Get-Command gh.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $result = & $gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "GitHub CLI could not list repositories. Run 'gh auth login' and verify organization access." }
    return ($result -join "`n")
}

function Get-RepositoryInventory {
    $login = (Invoke-GitHub -Arguments @('api','user','--jq','.login')).Trim()
    if ($login -notmatch '^[A-Za-z0-9-]+$') { throw 'Unexpected GitHub account name.' }
    $owners = @($login)
    $orgText = Invoke-GitHub -Arguments @('api','user/orgs','--paginate','--jq','.[].login')
    $owners += @($orgText -split '\r?\n' | Where-Object { $_ })
    $result = @()
    foreach ($owner in ($owners | Sort-Object -Unique)) {
        if ($owner -notmatch '^[A-Za-z0-9-]+$') { throw 'Unexpected GitHub organization name.' }
        $json = Invoke-GitHub -Arguments @('repo','list',$owner,'--limit','1000','--json','nameWithOwner,isPrivate,isArchived,isFork')
        $repos = @(ConvertFrom-Json -InputObject $json)
        if ($repos.Count -ge 1000) { throw "Repository inventory for $owner reached the 1000-item limit. Refusing an incomplete selection." }
        foreach ($repo in $repos) {
            if ($repo.nameWithOwner -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$') { throw 'Unexpected repository name from GitHub.' }
            if ($repo.nameWithOwner.Split('/')[0] -ine $owner) { throw 'GitHub returned a repository under the wrong owner.' }
            $result += [pscustomobject]@{ NameWithOwner=$repo.nameWithOwner; Owner=$owner; Name=$repo.nameWithOwner.Split('/')[1]; Private=[bool]$repo.isPrivate; Archived=[bool]$repo.isArchived; Fork=[bool]$repo.isFork }
        }
    }
    return @($result | Sort-Object Owner,Name -Unique)
}

function Select-RepositoryNames($Repositories, [string] $Answer) {
    $items = @($Repositories | Sort-Object Owner,Name)
    if ($Answer -eq 'none' -or [string]::IsNullOrWhiteSpace($Answer)) { return @() }
    if ($Answer -eq 'all') { return @($items.NameWithOwner) }
    $selected = @{}
    foreach ($part in ($Answer -split ',')) {
        $token = $part.Trim()
        if ($token -notmatch '^\d+(?:-\d+)?$') { throw "Invalid selection '$token'. Use numbers and ranges such as 1,3-5." }
        $bounds = $token -split '-'
        $start = [int]$bounds[0]
        $end = if ($bounds.Count -eq 2) { [int]$bounds[1] } else { $start }
        if ($start -lt 1 -or $end -lt $start -or $end -gt $items.Count) { throw "Selection '$token' is outside the list." }
        for ($index=$start; $index -le $end; $index++) { $selected[$index] = $true }
    }
    return @($selected.Keys | Sort-Object | ForEach-Object { $items[$_ - 1].NameWithOwner })
}

function Request-RepositorySelection($Repositories) {
    $items = @($Repositories | Sort-Object Owner,Name)
    if (!$items.Count) { throw 'No accessible repositories were returned by GitHub.' }
    Write-Host 'Select repositories to clone. Private, archived, and forked repositories are marked.'
    for ($i=0; $i -lt $items.Count; $i++) {
        $flags = @()
        if ($items[$i].Private) { $flags += 'private' }
        if ($items[$i].Archived) { $flags += 'archived' }
        if ($items[$i].Fork) { $flags += 'fork' }
        $suffix = if ($flags.Count) { ' [' + ($flags -join ', ') + ']' } else { '' }
        Write-Host ("{0,3}. {1}{2}" -f ($i+1),$items[$i].NameWithOwner,$suffix)
    }
    while ($true) {
        $answer = Read-Host 'Enter several numbers/ranges (1,3-5), all, or none'
        try { return @(Select-RepositoryNames $items $answer) }
        catch { Write-Warning $_.Exception.Message }
    }
}

function Read-RepositorySelection([string] $Path, $Inventory) {
    $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($data.schemaVersion -ne 1 -or !$data.PSObject.Properties['repositories']) { throw "Invalid repository selection: $Path" }
    $known = @{}
    foreach ($repo in $Inventory) { $known[$repo.NameWithOwner.ToLowerInvariant()] = $true }
    $selected = @()
    foreach ($name in $data.repositories) {
        if ($name -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$' -or !$known.ContainsKey($name.ToLowerInvariant())) { throw "Selected repository is unavailable or invalid: $name" }
        if ($name -in $selected) { throw "Duplicate repository selection: $name" }
        $selected += $name
    }
    return @($selected)
}

function Get-RepositoryState([string] $NameWithOwner, [string] $Root) {
    if ($NameWithOwner -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository name.' }
    $parts = $NameWithOwner.Split('/')
    $ownerPath = Join-Path $Root $parts[0]
    $destination = Join-Path $ownerPath $parts[1]
    if (Test-Path -LiteralPath $ownerPath) {
        $ownerItem = Get-Item -LiteralPath $ownerPath -Force
        if (!$ownerItem.PSIsContainer -or ($ownerItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [pscustomobject]@{Repository=$NameWithOwner;Status='Conflict';Path=$destination;Detail='Owner directory is not a normal directory'} }
    }
    # Reuse matching clones made before the owner/repo layout was introduced.
    $flatPath = Join-Path $Root $parts[1]
    if (!(Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $flatPath)) {
        $flatItem = Get-Item -LiteralPath $flatPath -Force
        if ($flatItem.PSIsContainer -and !($flatItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $git = Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $remote = & $git.Source -C $flatPath remote get-url origin 2>$null
            $normalized = ([string]$remote).Trim() -replace '^git@github\.com:', 'https://github.com/' -replace '\.git$', ''
            if ($LASTEXITCODE -eq 0 -and $normalized -ieq "https://github.com/$NameWithOwner") { $destination = $flatPath }
        }
    }
    if (!(Test-Path -LiteralPath $destination)) { return [pscustomobject]@{Repository=$NameWithOwner;Status='Missing';Path=$destination;Detail='Clone'} }
    $item = Get-Item -LiteralPath $destination -Force
    if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [pscustomobject]@{Repository=$NameWithOwner;Status='Conflict';Path=$destination;Detail='Destination is not a normal directory'} }
    $git = Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $remote = & $git.Source -C $destination remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{Repository=$NameWithOwner;Status='Conflict';Path=$destination;Detail='Existing directory is not a Git clone with origin'} }
    $normalized = ([string]$remote).Trim() -replace '^git@github\.com:', 'https://github.com/' -replace '\.git$', ''
    if ($normalized -ine "https://github.com/$NameWithOwner") { return [pscustomobject]@{Repository=$NameWithOwner;Status='Conflict';Path=$destination;Detail='Existing origin points elsewhere'} }
    return [pscustomobject]@{Repository=$NameWithOwner;Status='Ready';Path=$destination;Detail='Existing clone preserved'}
}

function Install-SelectedRepositories([string[]] $Names, [string] $Root) {
    $git = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $states = @()
    foreach ($name in $Names) {
        $state = Get-RepositoryState $name $Root
        if ($state.Status -eq 'Missing') {
            $null = New-Item -ItemType Directory -Path (Split-Path $state.Path) -Force
            & $git clone -- "https://github.com/$name.git" $state.Path
            if ($LASTEXITCODE -ne 0) { throw "Clone failed: $name. Inspect '$($state.Path)' before retrying." }
            $state = Get-RepositoryState $name $Root
            if ($state.Status -ne 'Ready') { throw "Clone verification failed: $name" }
        }
        $states += $state
        if ($state.Status -eq 'Conflict') { break }
    }
    return @($states)
}

Export-ModuleMember -Function Get-RepositoryInventory,Select-RepositoryNames,Request-RepositorySelection,Read-RepositorySelection,Get-RepositoryState,Install-SelectedRepositories
