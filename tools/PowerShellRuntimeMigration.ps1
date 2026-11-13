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
    $packagePathPattern = '(?i)[A-Z]:\\[^"\r\n]*?WindowsApps\\Microsoft\.PowerShell_[^\\"]+\\pwsh\.exe'
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
    $definitions = @()
    $hasMatch = $false
    foreach ($action in @($Task.Actions)) {
        $execute = [string]$action.Execute
        $arguments = [string]$action.Argument
        $newExecute = Convert-PowerShell7RuntimeReference -Text $execute -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $SystemPwshPath
        $newArguments = Convert-PowerShell7RuntimeReference -Text $arguments -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $SystemPwshPath
        if ($newExecute -cne $execute -or $newArguments -cne $arguments) { $hasMatch = $true }
        $execute = if ($isSystem) { $newExecute } else { Convert-PowerShell7RuntimeReference -Text $execute -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $UserPwshAlias }
        $arguments = if ($isSystem) { $newArguments } else { Convert-PowerShell7RuntimeReference -Text $arguments -LegacyPwshPath $LegacyPwshPath -SystemPwshPath $UserPwshAlias }
        $definitions += [pscustomobject]@{ Execute=$execute; Argument=$arguments; WorkingDirectory=[string]$action.WorkingDirectory }
    }
    $requiresCredential = $hasMatch -and ([string]$principal.LogonType -eq 'Password')
    $changed = $hasMatch -and -not $requiresCredential
    return [pscustomobject]@{
        Changed = $changed
        RequiresCredential = $requiresCredential
        ReplacementPath = if ($hasMatch) { $newPath } else { $null }
        Actions = if ($changed) { $definitions } else { @($Task.Actions) }
    }
}

function Convert-PowerShell7RuntimeReference {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$LegacyPwshPath,
          [Parameter(Mandatory)][string]$SystemPwshPath)
    $legacyDirectory = Split-Path -Parent $LegacyPwshPath
    $systemDirectory = Split-Path -Parent $SystemPwshPath
    $updated = [regex]::Replace($Text, [regex]::Escape($LegacyPwshPath), [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $SystemPwshPath }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $updated = [regex]::Replace($updated, [regex]::Escape($legacyDirectory), [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $systemDirectory }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $packagePathPattern = '(?i)(?<folder>[A-Z]:\\[^\r\n]*?WindowsApps\\Microsoft\.PowerShell_[^\\]+)(?<exe>\\pwsh\.exe)?'
    return [regex]::Replace($updated, $packagePathPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Groups['exe'].Success) { return $SystemPwshPath }
        return $systemDirectory
    })
}

function Get-PowerShell7RuntimeReferenceSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Texts, [Parameter(Mandatory)][string]$LegacyPwshPath)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $references = New-Object 'System.Collections.Generic.List[string]'
    $patterns = @(
        [regex]::Escape($LegacyPwshPath),
        '(?i)[A-Z]:\\[^"\r\n]*?WindowsApps\\Microsoft\.PowerShell_[^\\"]+\\pwsh\.exe'
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
        $beforeReferences = @(Get-PowerShell7RuntimeReferenceSummary -Texts @($task.Actions | ForEach-Object { [string]$_.Execute; [string]$_.Argument }) -LegacyPwshPath $LegacyPwshPath)
        if ($plan.RequiresCredential) {
            Write-PowerShell7RuntimeLog -LogPath $LogPath -Message "TASK MANUAL UPDATE REQUIRED: $($task.TaskPath)$($task.TaskName); before=$($beforeReferences -join ';'); replacement=$($plan.ReplacementPath)"
            continue
        }
        if (-not $plan.Changed) { continue }
        if (-not $alias) { throw "Cannot map scheduled task $($task.TaskPath)$($task.TaskName) to a user profile; its PowerShell action cannot be safely changed." }
        $actions = foreach ($action in $plan.Actions) {
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

function Move-PowerShell7LegacyContent {
    param([Parameter(Mandatory)][string]$LogPath,
          [string]$LegacyRoot = (Join-Path $env:ProgramFiles 'PowerShell\7'),
          [string]$TargetRoot = (Join-Path $env:ProgramFiles 'PowerShell'))
    foreach ($kind in @('Modules','Scripts')) {
        $source = Join-Path $legacyRoot $kind
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
        $target = Join-Path $targetRoot $kind
        $null = New-Item -ItemType Directory -Path $target -Force
        foreach ($file in @(Get-ChildItem -LiteralPath $source -File -Recurse -Force -ErrorAction Stop)) {
            $relative = $file.FullName.Substring($source.Length).TrimStart('\')
            $destination = Join-Path $target $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
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
    Move-PowerShell7LegacyContent -LogPath $logPath
}
