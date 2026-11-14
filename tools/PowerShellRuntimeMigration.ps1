function Get-PowerShell7SettingsTextUpdate {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$OldPath,
        [Parameter(Mandatory)][string]$NewPath
    )
    <# Terminal settings are JSONC. Windows PowerShell 5.1 cannot parse its comments, so
       replace the exact JSON-escaped path in the text and leave every other byte alone. #>
    $oldJsonPath = $OldPath.Replace('\', '\\')
    $newJsonPath = $NewPath.Replace('\', '\\')
    $updated = [regex]::Replace($Text, [regex]::Escape($oldJsonPath), [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $newJsonPath }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $updated = [regex]::Replace($updated, '(?i)%ProgramFiles%\\\\PowerShell\\\\7\\\\pwsh\.exe', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $newJsonPath })
    $packagePathPattern = '(?i)[A-Z]:\\\\(?:Program Files\\\\)?WindowsApps\\\\Microsoft\.PowerShell_[^\\\\;"\s]+\\\\pwsh\.exe'
    return [regex]::Replace($updated, $packagePathPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $newJsonPath })
}

function Update-PowerShell7TerminalSettingsFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OldPath,
        [Parameter(Mandatory)][string]$NewPath,
        [Parameter(Mandatory)][string]$LogPath
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $preambleLength = 0
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encoding = New-Object System.Text.UTF32Encoding($true, $false)
        $preambleLength = 4
    } elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        $encoding = New-Object System.Text.UTF32Encoding($false, $false)
        $preambleLength = 4
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $preambleLength = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $false)
        $preambleLength = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $false)
        $preambleLength = 2
    }
    $text = $encoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)
    $updated = Get-PowerShell7SettingsTextUpdate -Text $text -OldPath $OldPath -NewPath $NewPath
    if ($updated -ceq $text) { return [pscustomobject]@{ Changed = $false; BackupPath = $null } }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfffZ')
    $backupPath = "$Path.$stamp.bak"
    while (Test-Path -LiteralPath $backupPath) { $backupPath = "$Path.$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).bak" }
    [IO.File]::Copy($Path, $backupPath, $false)
    $preamble = New-Object byte[] $preambleLength
    if ($preambleLength -gt 0) { [Array]::Copy($bytes, 0, $preamble, 0, $preambleLength) }
    $body = $encoding.GetBytes($updated)
    $newBytes = New-Object byte[] ($preamble.Length + $body.Length)
    [Array]::Copy($preamble, 0, $newBytes, 0, $preamble.Length)
    [Array]::Copy($body, 0, $newBytes, $preamble.Length, $body.Length)
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $replaceBackupPath = "$tempPath.replace.bak"
    try {
        [IO.File]::WriteAllBytes($tempPath, $newBytes)
        [IO.File]::Replace($tempPath, $Path, $replaceBackupPath)
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $replaceBackupPath) { Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction SilentlyContinue }
    }
    $line = '{0:u} Terminal settings updated; before={1}; after={2}; backup={3}' -f [DateTime]::UtcNow,$OldPath,$NewPath,$backupPath
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    return [pscustomobject]@{ Changed = $true; BackupPath = $backupPath }
}

function Get-PowerShell7TaskActionMigration {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$LegacyPwshPath,
        [Parameter(Mandatory)][string]$SystemPwshPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$UserPwshAlias
    )
    $principal = $Task.Principal
    $isSystem = ([string]$principal.LogonType -eq 'ServiceAccount') -or
        ([string]$principal.UserId -match '^(?i)(SYSTEM|NT AUTHORITY\\SYSTEM|S-1-5-18|LOCAL SERVICE|NT AUTHORITY\\LOCAL SERVICE|NETWORK SERVICE|NT AUTHORITY\\NETWORK SERVICE)$')
    $newPath = if ($isSystem) { $SystemPwshPath } else { $UserPwshAlias }
    $definitions = [System.Collections.Generic.List[object]]::new()
    $hasMatch = $false
    foreach ($action in @($Task.Actions)) {
        $execute = [string]$action.Execute
        $arguments = if ($action.PSObject.Properties['Arguments']) { [string]$action.Arguments } else { [string]$action.Argument }
        $actionChanged = $false
        $newExecute = Convert-PowerShell7RuntimeReference -Text $execute -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $SystemPwshPath
        $newArguments = Convert-PowerShell7RuntimeReference -Text $arguments -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $SystemPwshPath
        $isRuntimeExecutable = $execute -match '(?i)pwsh\.exe$' -and
            ($newExecute -cne $execute -or $execute -match '(?i)WindowsApps\\Microsoft\.PowerShell_[^\\]+\\pwsh\.exe$')
        $userNeedsAlias = -not $isSystem -and $isRuntimeExecutable -and $UserPwshAlias -and $execute -cne $UserPwshAlias
        if ($newExecute -cne $execute -or $newArguments -cne $arguments -or ($isRuntimeExecutable -and -not $isSystem)) {
            $hasMatch = $true
            $actionChanged = $true
        }
        if ($userNeedsAlias) { $actionChanged = $true }
        if ($isSystem) {
            $execute = $newExecute
            $arguments = $newArguments
        } elseif ($actionChanged -and $UserPwshAlias) {
            if ($isRuntimeExecutable) { $execute = $UserPwshAlias }
            $arguments = Convert-PowerShell7RuntimeReference -Text $arguments -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $UserPwshAlias
        }
        if ($action.ClassId) {
            # Preserve COM-handler actions; recreating them as Exec actions corrupts the task.
            $definitions.Add($action)
            continue
        }
        $workingDirectory = [string]$action.WorkingDirectory
        if ($workingDirectory) {
            $replacement = if ($isSystem) { $SystemPwshPath } else { $UserPwshAlias }
            if ($replacement) {
                $workingDirectory = Convert-PowerShell7RuntimeReference -Text $workingDirectory -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $replacement
            }
        }
        if ($workingDirectory -cne [string]$action.WorkingDirectory) { $hasMatch = $true; $actionChanged = $true }
        $definitions.Add([pscustomobject]@{ Id=[string]$action.Id; Execute=$execute; Argument=$arguments; WorkingDirectory=$workingDirectory })
    }
    $requiresCredential = $hasMatch -and ([string]$principal.LogonType -eq 'Password')
    $requiresUserAlias = $hasMatch -and -not $isSystem -and [string]::IsNullOrWhiteSpace($UserPwshAlias)
    $changed = $hasMatch -and -not $requiresCredential -and -not $requiresUserAlias
    return [pscustomobject]@{
        Changed = $changed
        RequiresCredential = $requiresCredential
        RequiresUserAlias = $requiresUserAlias
        ReplacementPath = if ($hasMatch) { $newPath } else { $null }
        Actions = if ($changed) { $definitions.ToArray() } else { @($Task.Actions) }
    }
}

function Convert-PowerShell7RuntimeReference {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$LegacyPwshPath,
          [Parameter(Mandatory)][string]$SystemPwshPath)
    $legacyDirectory = Split-Path -Parent $LegacyPwshPath
    $systemDirectory = Split-Path -Parent $SystemPwshPath
    $updated = [regex]::Replace($Text, [regex]::Escape($LegacyPwshPath), [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $SystemPwshPath }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $updated = [regex]::Replace($updated, [regex]::Escape($legacyDirectory), [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $systemDirectory }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $updated = [regex]::Replace($updated, '(?i)%ProgramFiles%\\PowerShell\\7(?:\\pwsh\.exe)?', [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Value -match '(?i)\\pwsh\.exe$') { return $SystemPwshPath }
        return $systemDirectory
    })
    $updated = [regex]::Replace($updated, '(?i)\$env:ProgramFiles\\PowerShell\\7(?:\\pwsh\.exe)?', [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Value -match '(?i)\\pwsh\.exe$') { return $SystemPwshPath }
        return $systemDirectory
    })
    # Bound the match to a single path token; never swallow neighboring command arguments.
    $packagePathPattern = '(?i)(?<folder>[A-Z]:\\(?:Program Files\\)?WindowsApps\\Microsoft\.PowerShell_[^\\;"\s]+)(?<exe>\\pwsh\.exe)?'
    return [regex]::Replace($updated, $packagePathPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Groups['exe'].Success) { return $SystemPwshPath }
        return $systemDirectory
    })
}

function Get-PowerShell7RuntimeReferenceSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Texts, [Parameter(Mandatory)][string]$LegacyPwshPath)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $references = New-Object 'System.Collections.Generic.List[string]'
    $patterns = @(
        [regex]::Escape($LegacyPwshPath),
        '(?i)%ProgramFiles%\\PowerShell\\7\\pwsh\.exe',
        '(?i)\$env:ProgramFiles\\PowerShell\\7\\pwsh\.exe',
        '(?i)[A-Z]:\\(?:Program Files\\)?WindowsApps\\Microsoft\.PowerShell_[^\\;"\s]+\\pwsh\.exe'
    )
    foreach ($text in $Texts) {
        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches([string]$text, $pattern)) {
                if ($seen.Add($match.Value)) { $references.Add($match.Value) }
            }
        }
    }
    return $references.ToArray()
}

function Get-PowerShell7UserProfiles {
    $profiles = @()
    foreach ($profile in @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath })) {
        $root = [Environment]::ExpandEnvironmentVariables([string]$profile.LocalPath)
        $profiles += [pscustomobject]@{
            Sid = [string]$profile.SID
            Root = $root
            Alias = Join-Path $root 'AppData\Local\Microsoft\WindowsApps\pwsh.exe'
            LocalAppData = Join-Path $root 'AppData\Local'
        }
    }
    return $profiles
}

function Open-PowerShell7ProfileEnvironmentKey {
    param([Parameter(Mandatory)]$Profile,[switch]$Writable)
    $mountName = $null
    $path = "$($Profile.Sid)\Environment"
    $key = if ($Writable) { [Microsoft.Win32.Registry]::Users.OpenSubKey($path,$true) } else { [Microsoft.Win32.Registry]::Users.OpenSubKey($path) }
    if (-not $key) {
        $hivePath = Join-Path $Profile.Root 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $hivePath -PathType Leaf)) { return $null }
        $mountName = '_BootUpdateCycle_' + [guid]::NewGuid().ToString('N')
        & reg.exe load "HKU\$mountName" $hivePath 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $path = "$mountName\Environment"
        $key = if ($Writable) { [Microsoft.Win32.Registry]::Users.OpenSubKey($path,$true) } else { [Microsoft.Win32.Registry]::Users.OpenSubKey($path) }
    }
    if (-not $key) {
        if ($mountName) { & reg.exe unload "HKU\$mountName" 2>$null | Out-Null }
        return $null
    }
    return [pscustomobject]@{ Key=$key; MountName=$mountName }
}

function Close-PowerShell7ProfileEnvironmentKey {
    param([Parameter(Mandatory)]$Handle)
    if ($Handle.Key) { $Handle.Key.Dispose() }
    if ($Handle.MountName) { & reg.exe unload "HKU\$($Handle.MountName)" 2>$null | Out-Null }
}

function Write-PowerShell7RuntimeLog {
    param([Parameter(Mandatory)][string]$LogPath, [Parameter(Mandatory)][string]$Message)
    $directory = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    Add-Content -LiteralPath $LogPath -Value ('{0:u} {1}' -f [DateTime]::UtcNow,$Message) -Encoding UTF8
}

function Update-PowerShell7TerminalProfiles {
    param([Parameter(Mandatory)][object[]]$Profiles, [Parameter(Mandatory)][string]$LegacyPwshPath,
          [Parameter(Mandatory)][string]$LogPath)
    $updated = 0
    foreach ($profile in $Profiles) {
        $settingsPaths = @(
            (Join-Path $profile.LocalAppData 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $profile.LocalAppData 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $profile.LocalAppData 'Microsoft\Windows Terminal\settings.json')
        )
        foreach ($settingsPath in $settingsPaths) {
            if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { continue }
            $result = Update-PowerShell7TerminalSettingsFile -Path $settingsPath -OldPath $LegacyPwshPath -NewPath $profile.Alias -LogPath $LogPath
            if ($result.Changed) { $updated++ }
        }
    }
    return $updated
}

function Resolve-PowerShell7TaskAlias {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][object[]]$Profiles)
    $userId = [string]$Task.Principal.UserId
    if ($userId -match '^S-1-') { $sid = $userId }
    else {
        try { $sid = ([Security.Principal.NTAccount]$userId).Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { return $null }
    }
    return ($Profiles | Where-Object { $_.Sid -eq $sid } | Select-Object -First 1).Alias
}

function Update-PowerShell7ScheduledTaskReferences {
    param([Parameter(Mandatory)][object[]]$Profiles, [Parameter(Mandatory)][string]$SystemPwshPath,
          [Parameter(Mandatory)][string]$LegacyPwshPath, [Parameter(Mandatory)][string]$LogPath)
    foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
        $isSystem = ([string]$task.Principal.LogonType -eq 'ServiceAccount') -or ([string]$task.Principal.UserId -match '^(?i)(SYSTEM|NT AUTHORITY\\SYSTEM|S-1-5-18|LOCAL SERVICE|NT AUTHORITY\\LOCAL SERVICE|NETWORK SERVICE|NT AUTHORITY\\NETWORK SERVICE)$')
        $alias = if ($isSystem) { $SystemPwshPath } else { Resolve-PowerShell7TaskAlias -Task $task -Profiles $Profiles }
        if (-not $alias) { $alias = '' }
        $plan = Get-PowerShell7TaskActionMigration -Task $task -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $SystemPwshPath -UserPwshAlias $alias
        $beforeReferences = @(Get-PowerShell7RuntimeReferenceSummary -Texts @($task.Actions | ForEach-Object { [string]$_.Execute; [string]$(if ($_.PSObject.Properties['Arguments']) { $_.Arguments } else { $_.Argument }); [string]$_.WorkingDirectory }) -LegacyPwshPath $LegacyPwshPath)
        if ($plan.RequiresCredential) {
            Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "TASK MANUAL UPDATE REQUIRED: $($task.TaskPath)$($task.TaskName); before=$($beforeReferences -join ';'); replacement=$($plan.ReplacementPath)"
            continue
        }
        if ($plan.RequiresUserAlias) {
            Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "TASK MIGRATION BLOCKED: $($task.TaskPath)$($task.TaskName); before=$($beforeReferences -join ';'); reason=user profile alias could not be resolved"
            throw "Cannot map scheduled task $($task.TaskPath)$($task.TaskName) to a user profile alias; its PowerShell action cannot be safely changed."
        }
        if (-not $plan.Changed) { continue }
        if (-not $alias) { throw "Cannot map scheduled task $($task.TaskPath)$($task.TaskName) to a user profile; its PowerShell action cannot be safely changed." }
        $actions = foreach ($action in $plan.Actions) {
            if ($action.ClassId) { $action; continue }
            $actionParameters = @{ Execute = $action.Execute }
            if ($action.Argument) { $actionParameters.Argument = $action.Argument }
            if ($action.WorkingDirectory) { $actionParameters.WorkingDirectory = $action.WorkingDirectory }
            if ($action.Id) { $actionParameters.Id = $action.Id }
            New-ScheduledTaskAction @actionParameters
        }
        Set-ScheduledTask -InputObject $task -Action @($actions) -ErrorAction Stop | Out-Null
        Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "TASK ACTION UPDATED: $($task.TaskPath)$($task.TaskName); before=$($beforeReferences -join ';'); after=$($plan.ReplacementPath)"
    }
}

function Update-PowerShell7SystemRegistryReferences {
    param([Parameter(Mandatory)][string]$LegacyPwshPath, [Parameter(Mandatory)][string]$SystemPwshPath,
          [Parameter(Mandatory)][string]$LogPath)
    $targets = @(
        @{ Key='SOFTWARE\OpenSSH'; Values=@('DefaultShell') },
        @{ Key='SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe'; Values=@('', 'Path') }
    )
    $views = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
    foreach ($view in $views) {
        try { $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view) }
        catch { continue }
        try {
            foreach ($target in $targets) {
                $key = $base.OpenSubKey($target.Key, $true)
                if (-not $key) { continue }
                try {
                    foreach ($name in $target.Values) {
                        if ($key.GetValueNames() -notcontains $name) { continue }
                        $before = [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                        if (-not $before) { continue }
                        $after = Convert-PowerShell7RuntimeReference -Text $before -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $SystemPwshPath
                        if ($after -ceq $before) { continue }
                        $kind = $key.GetValueKind($name)
                        $key.SetValue($name, $after, $kind)
                        Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "REGISTRY UPDATED: HKLM\$($target.Key)\$name ($view); before=$before; after=$after"
                    }
                } finally { $key.Dispose() }
            }
        } finally { $base.Dispose() }
    }
}

function Update-PowerShell7MachinePath {
    param([Parameter(Mandatory)][string]$LegacyPwshPath, [Parameter(Mandatory)][string]$SystemPwshPath,
          [Parameter(Mandatory)][string]$LogPath)
    $before = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (-not $before) { return }
    $after = Get-PowerShell7MachinePathUpdate -CurrentPath $before -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $SystemPwshPath
    if ($after -cne $before) {
        [Environment]::SetEnvironmentVariable('Path', $after, 'Machine')
        Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "MACHINE PATH UPDATED: before=$before; after=$after"
    }
}

function Get-PowerShell7MachinePathUpdate {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CurrentPath,
          [Parameter(Mandatory)][string]$LegacyPwshPath, [Parameter(Mandatory)][string]$SystemPwshPath)
    $legacyDirectory = (Split-Path -Parent $LegacyPwshPath).TrimEnd('\')
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $CurrentPath.Split(';')) {
        $value = $entry.Trim().Trim('"')
        $expanded = [Environment]::ExpandEnvironmentVariables($value)
        $isPowerShellPath = $false
        if ($value -and $expanded.TrimEnd('\') -ieq $legacyDirectory) {
            $isPowerShellPath = $true
            $prefix = if ($entry.TrimStart().StartsWith('"')) { '"' } else { '' }
            $suffix = if ($entry.TrimEnd().EndsWith('"')) { '"' } else { '' }
            $value = $prefix + (Split-Path -Parent $SystemPwshPath) + $suffix
        } elseif ($value -and $expanded.TrimEnd('\') -ieq $LegacyPwshPath) {
            continue
        } elseif ($expanded -match '(?i)\\WindowsApps\\Microsoft\.PowerShell_[^\\]+(?:\\pwsh\.exe)?$') {
            $isPowerShellPath = $true
            $prefix = if ($entry.TrimStart().StartsWith('"')) { '"' } else { '' }
            $suffix = if ($entry.TrimEnd().EndsWith('"')) { '"' } else { '' }
            $value = Convert-PowerShell7RuntimeReference -Text $expanded -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $SystemPwshPath
            $value = $prefix + $value + $suffix
        } else { $value = $entry }
        if ($isPowerShellPath) {
            if ($seen.Add($value)) { $entries.Add($value) }
        } else { $entries.Add($value) }
    }
    return ($entries.ToArray() -join ';')
}

function Get-PowerShell7UserPathUpdate {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CurrentPath,
          [Parameter(Mandatory)][string]$LegacyPwshPath,
          [Parameter(Mandatory)][string]$UserPwshAlias)
    $legacyDirectory = (Split-Path -Parent $LegacyPwshPath).TrimEnd('\')
    $aliasDirectory = (Split-Path -Parent $UserPwshAlias).TrimEnd('\')
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $addedAlias = $false
    foreach ($entry in $CurrentPath.Split(';')) {
        $value = $entry.Trim().Trim('"')
        $expanded = [Environment]::ExpandEnvironmentVariables($value).TrimEnd('\')
        $isRuntime = $false
        if ($expanded -ieq $legacyDirectory -or $expanded -ieq $aliasDirectory -or
            $expanded -match '(?i)\\WindowsApps\\Microsoft\.PowerShell_[^\\]+(?:\\pwsh\.exe)?$') {
            $isRuntime = $true
            if (-not $addedAlias) { $null = $seen.Add($aliasDirectory); $entries.Add($aliasDirectory); $addedAlias = $true }
        } elseif ($expanded -ieq $LegacyPwshPath -or $expanded -match '(?i)\\WindowsApps\\Microsoft\.PowerShell_[^\\]+\\pwsh\.exe$') {
            $isRuntime = $true
            if (-not $addedAlias) { $null = $seen.Add($aliasDirectory); $entries.Add($aliasDirectory); $addedAlias = $true }
        }
        if (-not $isRuntime -and $entry -and $seen.Add($entry.Trim().Trim('"'))) { $entries.Add($entry) }
    }
    return ($entries.ToArray() -join ';')
}

function Get-PowerShell7RuntimeRepairSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    $manual = @($Findings | Where-Object { $_.Manual })
    $repairable = @($Findings | Where-Object { -not $_.Manual })
    return [pscustomobject]@{ RepairableCount=$repairable.Count; ManualCount=$manual.Count; Manual=$manual; Repairable=$repairable }
}

function Get-PowerShell7RuntimeReferenceFindings {
    param([Parameter(Mandatory)][string]$InstalledPwshPath,
          [Parameter(Mandatory)][object[]]$Profiles,
          [Parameter(Mandatory)][string]$LegacyPwshPath)
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $packagePattern = '(?i)[A-Z]:\\(?:Program Files\\)?WindowsApps\\Microsoft\.PowerShell_[^\\;"\s]+\\pwsh\.exe'
    foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $system = ([string]$task.Principal.LogonType -eq 'ServiceAccount') -or ([string]$task.Principal.UserId -match '^(?i)(SYSTEM|NT AUTHORITY\\SYSTEM|S-1-5-18|LOCAL SERVICE|NT AUTHORITY\\LOCAL SERVICE|NETWORK SERVICE|NT AUTHORITY\\NETWORK SERVICE)$')
        $alias = if ($system) { $InstalledPwshPath } else { Resolve-PowerShell7TaskAlias -Task $task -Profiles $Profiles }
        foreach ($action in @($task.Actions)) {
            $argument = if ($action.PSObject.Properties['Arguments']) { [string]$action.Arguments } else { [string]$action.Argument }
            foreach ($text in @([string]$action.Execute,$argument,[string]$action.WorkingDirectory)) {
                $matches = [regex]::Matches($text, [regex]::Escape($LegacyPwshPath) + '|' + $packagePattern)
                foreach ($match in $matches) {
                    if ($match.Value -ieq $InstalledPwshPath) { continue }
                    $findings.Add([pscustomobject]@{ Kind='Task'; Text=$match.Value; Manual=([string]$task.Principal.LogonType -eq 'Password'); ReplacementPath=$alias; TaskName="$($task.TaskPath)$($task.TaskName)" })
                }
            }
        }
    }
    foreach ($profile in $Profiles) {
        $handle = $null
        try { $handle = Open-PowerShell7ProfileEnvironmentKey -Profile $profile } catch { }
        if ($handle) {
            try { $value = [string]$handle.Key.GetValue('Path',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
            finally { Close-PowerShell7ProfileEnvironmentKey -Handle $handle }
            if ($value) {
                $replacement = Get-PowerShell7UserPathUpdate -CurrentPath $value -LegacyPwshPath $LegacyPwshPath -UserPwshAlias $profile.Alias
                if ($replacement -cne $value) { $findings.Add([pscustomobject]@{ Kind='User PATH'; Text=$value; Manual=$false; ReplacementPath=$replacement; ProfileSid=$profile.Sid }) }
            }
        }
    }
    $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
    if ($machinePath) {
        $replacement = Get-PowerShell7MachinePathUpdate -CurrentPath $machinePath -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $InstalledPwshPath
        if ($replacement -cne $machinePath) { $findings.Add([pscustomobject]@{ Kind='Machine PATH'; Text=$machinePath; Manual=$false; ReplacementPath=$replacement }) }
    }
    foreach ($keyPath in @('SOFTWARE\OpenSSH','SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe')) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) {
            $base = $null; $key = $null
            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
                $key = $base.OpenSubKey($keyPath)
                if (-not $key) { continue }
                foreach ($name in $key.GetValueNames()) {
                    $value = [string]$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if (-not $value) { continue }
                    $replacement = Convert-PowerShell7RuntimeReference -Text $value -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $InstalledPwshPath
                    if ($replacement -cne $value) { $findings.Add([pscustomobject]@{ Kind='HKLM registry'; Text=$value; Manual=$false; ReplacementPath=$replacement; RegistryPath="HKLM\$keyPath\$name ($view)" }) }
                }
            } catch { }
            finally { if ($key) { $key.Dispose() }; if ($base) { $base.Dispose() } }
        }
    }
    foreach ($profile in $Profiles) {
        foreach ($settings in @((Join-Path $profile.LocalAppData 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),(Join-Path $profile.LocalAppData 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),(Join-Path $profile.LocalAppData 'Microsoft\Windows Terminal\settings.json'))) {
            if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) { continue }
            $text = [IO.File]::ReadAllText($settings)
            foreach ($match in [regex]::Matches($text, '(?i)(?:[A-Z]:\\(?:Program Files\\)?WindowsApps\\Microsoft\.PowerShell_[^\\"\s]+\\pwsh\.exe|[A-Z]:\\Program Files\\PowerShell\\7\\pwsh\.exe)')) {
                if ($match.Value -ieq $InstalledPwshPath) { continue }
                $findings.Add([pscustomobject]@{ Kind='Windows Terminal'; Text=$match.Value; Manual=$false; ReplacementPath=$profile.Alias; SettingsPath=$settings })
            }
        }
    }
    return $findings.ToArray()
}

function Update-PowerShell7UserPaths {
    param([Parameter(Mandatory)][object[]]$Profiles,[Parameter(Mandatory)][string]$LegacyPwshPath,[Parameter(Mandatory)][string]$LogPath)
    foreach ($profile in $Profiles) {
        $handle = $null
        try { $handle = Open-PowerShell7ProfileEnvironmentKey -Profile $profile -Writable } catch { }
        if (-not $handle) { continue }
        try {
            $key = $handle.Key
            $before = [string]$key.GetValue('Path',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if (-not $before) { continue }
            $after = Get-PowerShell7UserPathUpdate -CurrentPath $before -LegacyPwshPath $LegacyPwshPath -UserPwshAlias $profile.Alias
            if ($after -ceq $before) { continue }
            $kind = $key.GetValueKind('Path')
            $key.SetValue('Path',$after,$kind)
            Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "USER PATH UPDATED: profile=$($profile.Sid); before=$before; after=$after"
        } finally { Close-PowerShell7ProfileEnvironmentKey -Handle $handle }
    }
}

function Move-PowerShell7LegacyContent {
    param([Parameter(Mandatory)][string]$LogPath,
          [string]$LegacyRoot = (Join-Path $env:ProgramFiles 'PowerShell\7'),
          [string]$TargetRoot = (Join-Path $env:ProgramFiles 'PowerShell'),
          [string]$BundledModulesRoot = '')
    foreach ($kind in @('Modules','Scripts')) {
        $source = Join-Path $legacyRoot $kind
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
        $target = Join-Path $targetRoot $kind
        $null = New-Item -ItemType Directory -Path $target -Force
        foreach ($file in @(Get-ChildItem -LiteralPath $source -File -Recurse -Force -ErrorAction Stop)) {
            $relative = $file.FullName.Substring($source.Length).TrimStart('\')
            $destination = Join-Path $target $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
            $moduleName = ($relative -split '\\',2)[0]
            if ($kind -eq 'Modules' -and $BundledModulesRoot -and (Test-Path -LiteralPath (Join-Path $BundledModulesRoot $moduleName) -PathType Container)) {
                $conflict = Join-Path $targetRoot (Join-Path ('LegacyMsiConflicts\' + $kind) $relative)
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $conflict) -Force
                if (Test-Path -LiteralPath $conflict) { throw "Legacy PowerShell content conflict already exists at $conflict; original content was left in place." }
                Move-Item -LiteralPath $file.FullName -Destination $conflict
                Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "LEGACY CONTENT CONFLICT PRESERVED: $($file.FullName) -> $conflict; MSIX bundles this module"
                continue
            }
            if (-not (Test-Path -LiteralPath $destination)) {
                Move-Item -LiteralPath $file.FullName -Destination $destination -Force
                Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "LEGACY CONTENT MOVED: $($file.FullName) -> $destination"
                continue
            }
            $same = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            if ($same) {
                Remove-Item -LiteralPath $file.FullName -Force
                continue
            }
            $conflict = Join-Path $targetRoot (Join-Path ('LegacyMsiConflicts\' + $kind) $relative)
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $conflict) -Force
            if (Test-Path -LiteralPath $conflict) { throw "Legacy PowerShell content conflict already exists at $conflict; original content was left in place." }
            Move-Item -LiteralPath $file.FullName -Destination $conflict
            Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "LEGACY CONTENT CONFLICT PRESERVED: $($file.FullName) -> $conflict; destination already had different content"
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $source -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
            if (-not @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue).Count) {
                Remove-Item -LiteralPath $directory.FullName -Force
            }
        }
        $remaining = @(Get-ChildItem -LiteralPath $source -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count) { throw "Legacy PowerShell $kind content could not be moved completely; $($remaining.Count) item(s) remain at $source." }
        Remove-Item -LiteralPath $source -Force
    }
    if (Test-Path -LiteralPath $legacyRoot -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $legacyRoot -Force -ErrorAction SilentlyContinue)
        if (-not $remaining.Count) { Remove-Item -LiteralPath $legacyRoot -Force }
    }
}

function Update-PowerShell7References {
    param([Parameter(Mandatory)]$Installed)
    $logPath = Join-Path $env:ProgramData 'BootUpdateCycle\PowerShellRuntimeUpgrade.log'
    $profiles = @(Get-PowerShell7UserProfiles)
    $systemPath = [string]$Installed.PwshPath
    $terminalCount = Update-PowerShell7TerminalProfiles -Profiles $profiles -LegacyPwshPath $script:LegacyPwshPath -LogPath $logPath
    Write-PowerShell7RuntimeLog -LogPath $logPath -Message "TERMINAL MIGRATION COMPLETE: $terminalCount settings file(s) changed; user profiles=$($profiles.Count); package=$systemPath"
    Update-PowerShell7ScheduledTaskReferences -Profiles $profiles -SystemPwshPath $systemPath -LegacyPwshPath $script:LegacyPwshPath -LogPath $logPath
    Update-PowerShell7SystemRegistryReferences -LegacyPwshPath $script:LegacyPwshPath -SystemPwshPath $systemPath -LogPath $logPath
    Update-PowerShell7MachinePath -LegacyPwshPath $script:LegacyPwshPath -SystemPwshPath $systemPath -LogPath $logPath
    Update-PowerShell7UserPaths -Profiles $profiles -LegacyPwshPath $script:LegacyPwshPath -LogPath $logPath
}
