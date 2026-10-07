# Compare only documented, harmless Terminal serialization changes.
function ConvertTo-CanonicalValue($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in $Value.Keys | Sort-Object) { $ordered[$key] = ConvertTo-CanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return ,@($Value | ForEach-Object { ConvertTo-CanonicalValue $_ })
    }
    return $Value
}

function Test-TerminalSettingsEquivalent([string] $Expected, [string] $Current) {
    try {
        $before = ConvertFrom-Json -InputObject $Expected -AsHashtable
        $after = ConvertFrom-Json -InputObject $Current -AsHashtable
        $generated = @{
            '{872dfbd8-fd1f-4ebe-b77e-051f87599dc0}' = @('Dev Codex','TerminalDevSetup')
            '{70192e26-44aa-4be9-b659-90b754f50f96}' = @('Dev Claude','TerminalDevSetup')
            '{74e2e943-2c73-4bd0-b06c-f21ec11b6386}' = @('Dev PowerShell','TerminalDevSetup')
            '{d6fccd97-1f58-5233-bfa2-c0c69f2de059}' = @('Ubuntu','Microsoft.WSL')
        }
        foreach ($settings in @($before,$after)) {
            if ($settings.profiles -and $settings.profiles.ContainsKey('list')) {
                $settings.profiles.list = @(foreach ($profile in $settings.profiles.list) {
                    if ($profile.guid -and $generated.ContainsKey($profile.guid) -and $profile.source -eq $generated[$profile.guid][1]) {
                        if (($profile.Keys | Sort-Object) -join ',' -ne 'guid,hidden,name,source' -or
                            $profile.name -cne $generated[$profile.guid][0] -or $profile.hidden -ne $false) { return $false }
                    } else { $profile }
                })
            }
            foreach ($array in @(@{Name='keybindings';Key='keys'},@{Name='actions';Key='id'})) {
                if (!$settings.ContainsKey($array.Name)) { continue }
                $keys = @($settings[$array.Name] | ForEach-Object { $_[$array.Key] | ConvertTo-Json -Compress })
                if (@($keys | Where-Object { !$_ -or $_ -eq 'null' }).Count -or @($keys | Select-Object -Unique).Count -ne $keys.Count) { return $false }
                $settings[$array.Name] = @($settings[$array.Name] | Sort-Object { $_[$array.Key] | ConvertTo-Json -Compress })
            }
        }
        $expectedJson = ConvertTo-CanonicalValue $before | ConvertTo-Json -Depth 100 -Compress
        $currentJson = ConvertTo-CanonicalValue $after | ConvertTo-Json -Depth 100 -Compress
        return $expectedJson -ceq $currentJson
    } catch { return $false }
}
