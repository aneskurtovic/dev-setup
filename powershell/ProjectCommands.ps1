function Add-RepositoryNameAliases($Projects) {
    # Reserve navigation and both agent shortcuts before assigning any new names.
    $claims = @{}
    $candidates = @{}
    foreach ($project in $Projects) {
        $identity = $project.displayName
        $alias = ($identity.Split('/')[-1].ToLowerInvariant() -replace '[^a-z0-9-]','-').Trim('-')
        if ($alias -notmatch '^[a-z]') { $alias = 'repo-' + $alias }
        $candidates[$identity] = $alias
        foreach ($name in @($project.command) + @($project.aliases) + @($alias)) {
            foreach ($expanded in @($name, ($name + 'cc'), ($name + 'cx'))) {
                if (!$claims.ContainsKey($expanded)) { $claims[$expanded] = @() }
                $claims[$expanded] = @($claims[$expanded] + $identity | Select-Object -Unique)
            }
        }
    }
    $reserved = @('ai-workspace','ai-workspace-resume','ai-workspace-agents','ai-projects','ai-doctor','Invoke-AiProject','Get-AiProject','Test-AiWorkspace','Resolve-AiProjectRoot')
    foreach ($project in $Projects) {
        $alias = $candidates[$project.displayName]
        if ($alias -eq $project.command -or $alias -in @($project.aliases)) { continue }
        $safe = $true
        foreach ($name in @($alias, ($alias + 'cc'), ($alias + 'cx'))) {
            if ($name -in $reserved -or $claims[$name].Count -ne 1) { $safe = $false; break }
            $existing = @(Get-Command $name -ErrorAction SilentlyContinue)
            if (@($existing | Where-Object ModuleName -NE 'TerminalWorkspace').Count) { $safe = $false; break }
        }
        if ($safe) { $project.aliases = @($project.aliases) + @($alias) }
    }
}
