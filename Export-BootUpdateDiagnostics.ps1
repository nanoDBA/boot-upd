#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceDirectory = (Join-Path $env:ProgramData 'BootUpdateCycle'),
    [string]$OutputDirectory = $(
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) { $desktop } else { [IO.Path]::GetTempPath() }
    ),
    [string[]]$AdditionalRedaction = @(),
    [switch]$NoClipboard
)

$ErrorActionPreference = 'Stop'

function Get-BootUpdateSensitiveValues {
    param([string[]]$Additional = @())
    $values = [Collections.Generic.List[string]]::new()
    foreach ($name in @('USERNAME','USERDOMAIN','USERDNSDOMAIN','COMPUTERNAME','USERPROFILE','HOMEPATH','OneDrive','OneDriveCommercial','OneDriveConsumer')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value.Length -ge 3) { $values.Add($value) }
    }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($identity) { $values.Add($identity) }
    } catch { }
    foreach ($value in $Additional) {
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value.Length -ge 3) { $values.Add($value) }
    }
    # De-duplicate values themselves, not the Length sort key. Sort-Object
    # -Property Length -Unique would silently keep only one value per length.
    return @($values | Select-Object -Unique | Sort-Object Length -Descending)
}

function Protect-BootUpdateDiagnosticText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$SensitiveValues = @()
    )
    $safe = $Text
    $protectVersion = {
        param($match)
        $token = $match.Groups[2].Value
        $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($token))
        $hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 12)
        $placeholder = "<VERSION_$hash>"
        return $match.Groups[1].Value + $placeholder
    }
    # Preserve equality/change evidence for dotted four-part versions in labeled
    # provider output with stable placeholders before the broad IPv4 rule runs.
    $safe = [regex]::Replace($safe, '(?i)(\b(?:Version|Available|Installed|Target)\s*[:=]?\s*)(\d+(?:\.\d+){3,})', $protectVersion)

    # Winget's fixed-width table has unlabeled version columns. Use the header
    # offsets to protect only Version/Available fields.
    $tableLines = [regex]::Split($safe, '(\r?\n)')
    $versionStart = -1
    $sourceStart = -1
    for ($lineIndex = 0; $lineIndex -lt $tableLines.Count; $lineIndex++) {
        $line = $tableLines[$lineIndex]
        if ($line -match '(?i)\bName\s{2,}Id\s{2,}Version\s{2,}Available\s{2,}Source\b') {
            $versionStart = $line.IndexOf('Version')
            $sourceStart = $line.IndexOf('Source', $versionStart)
            continue
        }
        if ($versionStart -lt 0 -or $sourceStart -le $versionStart -or $line -notmatch '(?i)\bwinget\s*$') { continue }
        if ($line.Length -le $versionStart) { continue }
        $end = [math]::Min($sourceStart, $line.Length)
        $prefix = $line.Substring(0, $versionStart)
        $fields = $line.Substring($versionStart, $end - $versionStart)
        $suffix = if ($end -lt $line.Length) { $line.Substring($end) } else { '' }
        $fields = [regex]::Replace($fields, '(?<![\d.])(\d+(?:\.\d+){3,})(?![\d.])', {
            param($match)
            $token = $match.Groups[1].Value
            $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($token))
            $hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 12)
            $placeholder = "<VERSION_$hash>"
            return $placeholder
        })
        $tableLines[$lineIndex] = $prefix + $fields + $suffix
    }
    $safe = $tableLines -join ''
    foreach ($value in $SensitiveValues) {
        $safe = $safe -replace [regex]::Escape($value), '<REDACTED>'
    }
    $safe = $safe -replace '(?i)S-1-5-(?:\d+-){1,14}\d+', '<SID>'
    $safe = $safe -replace '(?i)\b[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\b', '<GUID>'
    $safe = $safe -replace '(?i)\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b', '<MAC>'
    $safe = $safe -replace '(?i)\b(?:\d{1,3}\.){3}\d{1,3}\b', '<IP>'
    $safe = $safe -replace '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '<EMAIL>'
    $safe = $safe -replace '(?i)https?://[^\s''"<>]+', '<URL>'
    $safe = $safe -replace '(?i)\\\\[^\s\\]+\\[^\r\n\s]+', '<UNC_PATH>'
    $safe = $safe -replace '(?i)\b(?:HKLM|HKCU|HKCR|HKU|HKCC):\\[^\r\n]+', '<REGISTRY_PATH>'
    # Fail toward privacy: an absolute drive path consumes the remainder of its
    # line. Diagnostic level/code/timestamp data before the path is preserved.
    $safe = $safe -replace '(?i)(?<![A-Z0-9_])[A-Z]:\\[^\r\n]+', '<PATH>'
    $safe = $safe -replace '(?i)\b[A-Z0-9._-]+\\[A-Z0-9.$_-]+\b', '<DOMAIN>\<USER>'
    return $safe
}

function Read-BootUpdateDiagnosticText {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $encodingName = 'UTF-8 (no BOM)'
    $warning = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $offset = 3; $encodingName = 'UTF-8 (BOM)'; $encoding = [Text.UTF8Encoding]::new($false, $true)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $offset = 2; $encodingName = 'UTF-16LE (BOM)'; $encoding = [Text.UnicodeEncoding]::new($false, $false, $true)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $offset = 2; $encodingName = 'UTF-16BE (BOM)'; $encoding = [Text.UnicodeEncoding]::new($true, $false, $true)
    } else {
        $encoding = [Text.UTF8Encoding]::new($false, $true)
    }
    try {
        $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    } catch {
        $encodingName = 'system default (invalid UTF-8 fallback)'
        $warning = "Invalid byte sequence in '$([IO.Path]::GetFileName($Path))'; decoded with the system default encoding."
        $text = [Text.Encoding]::Default.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    return [pscustomobject]@{ Text=$text; Encoding=$encodingName; Warning=$warning }
}

function Copy-BootUpdateDiagnosticSnapshot {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [int]$MaxAttempts = 3
    )
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $before = Get-Item -LiteralPath $Source.FullName -Force -ErrorAction Stop
            $inputStream = [IO.File]::Open($Source.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $output = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $inputStream.CopyTo($output) } finally { $output.Dispose() }
            } finally { $inputStream.Dispose() }
            $after = Get-Item -LiteralPath $Source.FullName -Force -ErrorAction Stop
            $stable = ($before.Length -eq $after.Length -and $before.LastWriteTimeUtc -eq $after.LastWriteTimeUtc)
            $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            if ($stable -or $attempt -eq $MaxAttempts) {
                return [pscustomobject]@{
                    Name=$Source.Name; CapturedLength=(Get-Item -LiteralPath $Destination).Length
                    LastWriteTimeUtc=$after.LastWriteTimeUtc.ToString('o'); SHA256=$hash
                    Stable=$stable; Attempts=$attempt; Error=$lastError
                }
            }
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -eq $MaxAttempts) { throw }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Could not snapshot diagnostic source '$($Source.FullName)'."
}

function Get-BootUpdateDiagnosticActivity {
    param([Parameter(Mandatory)][string]$Text)
    $completed = $Text -match '(?im)^\s*(?:\[[^\]]+\]\s*)*BOOT UPDATE CYCLE COMPLETE\b'
    $started = $Text -match '(?im)^\s*(?:\[[^\]]+\]\s*)*BOOT UPDATE CYCLE (?:STARTED|RESUMED)\b'
    $active = if ($completed) { $false } elseif ($started) { $true } else { $null }
    $phase = $null
    $iteration = $null
    $phaseMatches = [regex]::Matches(
        $Text,
        '(?im)^\s*(?:\[[^\]]+\]\s*)*(?:Current\s+)?Phase\s*[:#=]\s*(?<value>[A-Za-z][A-Za-z0-9 _-]{1,40})\s*$'
    )
    if ($phaseMatches.Count -gt 0) { $phase = $phaseMatches[$phaseMatches.Count - 1].Groups['value'].Value.Trim() }
    $iterationMatches = [regex]::Matches(
        $Text,
        '(?im)(?:^|\|)\s*(?:\[[^\]]+\]\s*)*(?:Pass|Iteration)\s*[:=]\s*(?<value>\d+)\b'
    )
    if ($iterationMatches.Count -gt 0) { $iteration = [int]$iterationMatches[$iterationMatches.Count - 1].Groups['value'].Value }
    return [pscustomobject]@{ ActiveAtCapture=$active; Phase=$phase; Iteration=$iteration }
}

function Get-BootUpdateDiagnosticCleanupSummary {
    param([Parameter(Mandatory)][string]$Text)
    $contexts = [ordered]@{}
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '(?i)Pending-file cleanup \[(?<context>[^\]]+)\]:\s*(?<categories>[A-Za-z][A-Za-z0-9]*(?:\s*=\s*\d+)?(?:\s*,\s*[A-Za-z][A-Za-z0-9]*\s*=\s*\d+)*)') {
            $context = $Matches['context'].Trim()
            if (-not $contexts.Contains($context)) {
                $contexts[$context] = [ordered]@{ Categories=[ordered]@{}; Fingerprints=@() }
            }
            foreach ($category in ($Matches['categories'] -split ',')) {
                if ($category.Trim() -match '^(?<name>[A-Za-z][A-Za-z0-9]*)\s*=\s*(?<count>\d+)$') {
                    $contexts[$context].Categories[$Matches['name']] = [int]$Matches['count']
                }
            }
        }
        if ($line -match '(?i)Pending-file cleanup detail \[(?<context>[^\]]+)\]:\s*id=(?<ids>[A-F0-9, ]+)') {
            $context = $Matches['context'].Trim()
            if (-not $contexts.Contains($context)) {
                $contexts[$context] = [ordered]@{ Categories=[ordered]@{}; Fingerprints=@() }
            }
            $contexts[$context].Fingerprints = @($Matches['ids'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
    $before = if ($contexts.Contains('before mutation')) { [pscustomobject]$contexts['before mutation'] } else { $null }
    $after = if ($contexts.Contains('after updates')) { [pscustomobject]$contexts['after updates'] } else { $null }
    $persistent = $null
    if ($before -and $after) {
        $beforeCategories = ($before.Categories.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ','
        $afterCategories = ($after.Categories.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ','
        $persistent = $beforeCategories -eq $afterCategories -and
            (($before.Fingerprints | Sort-Object) -join ',') -eq (($after.Fingerprints | Sort-Object) -join ',')
    }
    return [pscustomobject]@{
        BeforeMutation = $before
        AfterUpdates = $after
        Persistent = $persistent
    }
}

function Assert-BootUpdateDiagnosticIsSanitized {
    param([Parameter(Mandatory)][string]$Text,[string[]]$SensitiveValues = @())
    foreach ($value in $SensitiveValues) {
        if ($Text.IndexOf($value,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw 'Sanitized diagnostic verification failed: a protected identity value remains.'
        }
    }
    foreach ($pattern in @(
        '(?i)S-1-5-(?:\d+-){1,14}\d+',
        '(?i)\b[A-Z]:\\',
        '(?i)\\\\',
        '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
    )) {
        if ($Text -match $pattern) { throw 'Sanitized diagnostic verification failed: a sensitive pattern remains.' }
    }
}

function Enable-NtfsCompression {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Get-Command compact.exe -ErrorAction SilentlyContinue)) { return }
    try { $null = & compact.exe /C /I /Q $Path 2>$null } catch { }
}

function Set-BootUpdateClipboardText {
    param([Parameter(Mandatory)][string]$Text)
    try {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $Text -ErrorAction Stop
            return $true
        }
        if (Get-Command clip.exe -ErrorAction SilentlyContinue) {
            $Text | & clip.exe
            return ($LASTEXITCODE -eq 0)
        }
    } catch { }
    return $false
}

if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "Boot Update Cycle data directory was not found: $SourceDirectory"
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
}

$sensitive = @(Get-BootUpdateSensitiveValues -Additional $AdditionalRedaction)
$logs = @(Get-ChildItem -LiteralPath $SourceDirectory -File -ErrorAction Stop |
    Where-Object { $_.Name -match '^BootUpdateCycle(?:\.(?:providers|aws))?(?:\.\d{8}-\d{6})?\.log$' -or $_.Name -in @('BootUpdateCycle-repair-plan.txt','BootUpdateCycle-winget-quarantine.json','BootUpdateCycle-winget-resolved-absent.json','BootUpdateCycle.wu-assessment.json') } |
    Sort-Object LastWriteTimeUtc)
if (-not $logs.Count) { throw 'No Boot Update Cycle log files were found to export.' }

$stage = Join-Path ([IO.Path]::GetTempPath()) ('boot-upd-diagnostics-{0}' -f [guid]::NewGuid().ToString('N'))
$stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmssZ')
$zipPath = Join-Path $OutputDirectory "BootUpdateCycle-diagnostics-$stamp.zip"
try {
    $null = New-Item -ItemType Directory -Path $stage
    $snapshotDirectory = Join-Path $stage 'snapshots'
    $null = New-Item -ItemType Directory -Path $snapshotDirectory
    $sections = [Collections.Generic.List[string]]::new()
    $sourceRecords = [Collections.Generic.List[object]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $coreText = $null
    foreach ($log in $logs) {
        $snapshotPath = Join-Path $snapshotDirectory $log.Name
        $record = Copy-BootUpdateDiagnosticSnapshot -Source $log -Destination $snapshotPath
        $sourceRecords.Add($record)
        if (-not $record.Stable) {
            $warnings.Add("Source '$($log.Name)' changed while it was captured; the final snapshot may represent an active run.")
        }
        $decoded = Read-BootUpdateDiagnosticText -Path $snapshotPath
        if ($decoded.Warning) { $warnings.Add($decoded.Warning) }
        $raw = $decoded.Text
        if ($log.Name -eq 'BootUpdateCycle.log') { $coreText = $raw }
        $safe = Protect-BootUpdateDiagnosticText -Text $raw -SensitiveValues $sensitive
        Assert-BootUpdateDiagnosticIsSanitized -Text $safe -SensitiveValues $sensitive
        $sections.Add("===== $($log.Name) =====`r`n$safe")
    }
    $activity = if ($coreText) { Get-BootUpdateDiagnosticActivity -Text $coreText } else {
        [pscustomobject]@{ ActiveAtCapture=$null; Phase=$null; Iteration=$null }
    }
    $cleanupSummary = if ($coreText) { Get-BootUpdateDiagnosticCleanupSummary -Text $coreText } else { $null }
    $snapshotComplete = @($sourceRecords | Where-Object { -not $_.Stable }).Count -eq 0
    $captureState = if (-not $snapshotComplete) { 'unstable-snapshot' } elseif ($activity.ActiveAtCapture -eq $true) { 'active-at-capture' } elseif ($activity.ActiveAtCapture -eq $false) { 'completed' } else { 'unknown' }
    $sanitizedPath = Join-Path $stage 'BootUpdateCycle.sanitized.log'
    [IO.File]::WriteAllText($sanitizedPath, ($sections -join "`r`n`r`n"), [Text.UTF8Encoding]::new($true))
    $manifest = [ordered]@{
        FormatVersion = 2
        GeneratedUtc = [datetime]::UtcNow.ToString('o')
        Sanitized = $true
        SourceLogCount = $logs.Count
        CaptureState = $captureState
        ActiveAtCapture = $activity.ActiveAtCapture
        Phase = $activity.Phase
        Iteration = $activity.Iteration
        PendingFileCleanup = $cleanupSummary
        SnapshotComplete = $snapshotComplete
        SourceFiles = @($sourceRecords)
        Warnings = @($warnings)
        SanitizedLogSHA256 = (Get-FileHash -LiteralPath $sanitizedPath -Algorithm SHA256).Hash
    }
    if ($warnings.Count) { Write-Warning ($warnings -join ' ') }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
    Compress-Archive -LiteralPath $sanitizedPath,(Join-Path $stage 'manifest.json') -DestinationPath $zipPath -CompressionLevel Optimal -Force
    Enable-NtfsCompression -Path $zipPath
    $fullZipPath = (Get-Item -LiteralPath $zipPath).FullName
    $clipboardCopied = if ($NoClipboard) { $false } else { Set-BootUpdateClipboardText -Text $fullZipPath }
    Write-Host 'Sanitized diagnostic ZIP:' -ForegroundColor Green
    Write-Host $fullZipPath -ForegroundColor Cyan
    if ($clipboardCopied) {
        Write-Host 'Full ZIP path copied to the clipboard.' -ForegroundColor DarkGray
    } elseif (-not $NoClipboard) {
        Write-Warning 'The ZIP was created, but its path could not be copied to the clipboard.'
    }
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
