#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceDirectory = (Join-Path $env:ProgramData 'BootUpdateCycle'),
    [string]$OutputDirectory = $(
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) { $desktop } else { [IO.Path]::GetTempPath() }
    ),
    [string[]]$AdditionalRedaction = @()
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

if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "Boot Update Cycle data directory was not found: $SourceDirectory"
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
}

$sensitive = @(Get-BootUpdateSensitiveValues -Additional $AdditionalRedaction)
$logs = @(Get-ChildItem -LiteralPath $SourceDirectory -File -ErrorAction Stop |
    Where-Object { $_.Name -match '^BootUpdateCycle(?:\.(?:providers|aws))?(?:\.\d{8}-\d{6})?\.log$' } |
    Sort-Object LastWriteTimeUtc)
if (-not $logs.Count) { throw 'No Boot Update Cycle log files were found to export.' }

$stage = Join-Path ([IO.Path]::GetTempPath()) ('boot-upd-diagnostics-{0}' -f [guid]::NewGuid().ToString('N'))
$stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmssZ')
$zipPath = Join-Path $OutputDirectory "BootUpdateCycle-diagnostics-$stamp.zip"
try {
    $null = New-Item -ItemType Directory -Path $stage
    $sections = [Collections.Generic.List[string]]::new()
    foreach ($log in $logs) {
        $raw = Get-Content -LiteralPath $log.FullName -Raw -ErrorAction Stop
        $safe = Protect-BootUpdateDiagnosticText -Text $raw -SensitiveValues $sensitive
        Assert-BootUpdateDiagnosticIsSanitized -Text $safe -SensitiveValues $sensitive
        $sections.Add("===== $($log.Name) =====`r`n$safe")
    }
    $sanitizedPath = Join-Path $stage 'BootUpdateCycle.sanitized.log'
    [IO.File]::WriteAllText($sanitizedPath, ($sections -join "`r`n`r`n"), [Text.UTF8Encoding]::new($true))
    $manifest = [ordered]@{
        FormatVersion = 1
        GeneratedUtc = [datetime]::UtcNow.ToString('o')
        Sanitized = $true
        SourceLogCount = $logs.Count
        SanitizedLogSHA256 = (Get-FileHash -LiteralPath $sanitizedPath -Algorithm SHA256).Hash
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
    Compress-Archive -LiteralPath $sanitizedPath,(Join-Path $stage 'manifest.json') -DestinationPath $zipPath -CompressionLevel Optimal -Force
    Enable-NtfsCompression -Path $zipPath
    Write-Host "Sanitized diagnostic bundle: $zipPath" -ForegroundColor Green
    return Get-Item -LiteralPath $zipPath
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
