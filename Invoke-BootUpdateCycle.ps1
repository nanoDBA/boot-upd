#requires -Version 7.0
#requires -RunAsAdministrator
# ------------------------------------------------------------------------------
# File:        Invoke-BootUpdateCycle.ps1
# Description: Boot-time update orchestrator with automatic reboot loop
# Purpose:     Runs at Windows startup to systematically update all package
#              managers and Windows itself, rebooting as needed until no pending
#              reboots remain.  Self-removes when done.
# Created:     2025-01-10
# Modified:    2026-05-02
# ------------------------------------------------------------------------------
<#
.SYNOPSIS
    Updates everything, reboots if needed, repeats until done.

.DESCRIPTION
    Each boot it:
    1. Runs pre-flight checks (disk, network, battery, conflicts)
    2. Updates Winget (user + machine scope), Chocolatey, Windows Update
    3. Updates pip, npm, Office 365, PowerShell modules, Scoop, dotnet tools, VS Code extensions
    4. Reboots if any updates require it
    5. Cleans up and self-destructs when no pending reboots remain

    Safety: max iteration limit prevents infinite reboot loops.
    Smart timeouts: kills idle processes but lets busy installs finish.

.PARAMETER MaxIterations
    Maximum reboot cycles before giving up.  Default 5.

.PARAMETER PackageTimeoutMinutes
    Hard timeout ceiling per package manager.  Default 30.

.PARAMETER RebootDelaySec
    Seconds before forced reboot (no user abort window).  Default 0 (immediate, forced).

.PARAMETER Force
    Skip confirmation prompts and override pre-flight warnings.

.PARAMETER WhatIf
    Show what would happen without making any changes.  No packages are updated,
    no reboots are triggered, no scheduled tasks are registered.

.PARAMETER OutputMode
    Initial console detail: Quiet, Normal, Verbose, or Debug. Normal is the
    default. During interactive runs, press v to cycle modes without restarting.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$MaxIterations = 5,
    [int]$PackageTimeoutMinutes = 30,
    [int]$RebootDelaySec = 0,
    [switch]$SkipPip,
    [switch]$SkipNpm,
    [switch]$SkipOffice365,
    [switch]$SkipAwsTooling,
    [switch]$SkipPowerShellModules,
    [switch]$SkipScoop,
    [switch]$SkipDotnetTools = $true,
    [switch]$SkipVscode,
    [switch]$SkipDefender,                # Defender signature update (default: runs)
    [switch]$IncludeDriverUpdates,        # Driver updates via PSWindowsUpdate (default: opt-in, off)
    [switch]$IncludeFirmwareUpdates,      # Firmware updates via PSWindowsUpdate (default: opt-in, off)
    [switch]$UpdateWsl,                   # WSL kernel + distro updates (default: opt-in, off)
    [switch]$UpdateContainers,            # Docker/Podman image refresh + prune (default: opt-in, off)
    [switch]$SkipRestorePoint,
    [switch]$SkipHealthCheck,
    [switch]$SkipBitLocker,
    [switch]$StagedRollout,           # Run one package manager per boot instead of all at once
    [switch]$Force,
    [ValidateScript({ $_ -eq '' -or $_ -match '^https://' })]
    [string]$WebhookUrl       = '',   # Teams/Slack/Discord incoming webhook URL
    [string]$NotifyEmail      = '',   # SMTP recipient email address
    [string]$SmtpServer       = '',   # SMTP relay hostname (e.g., smtp.office365.com)
    [pscredential]$SmtpCredential = $null,  # SMTP credential (PSCredential object for authenticated relay)
    [string[]]$ExcludePatterns = @(),  # Package name/ID patterns to skip (substring, or wildcard if * / ? present; case-insensitive)
    [string[]]$IncludePatterns = @(),  # Allowlist mode: when non-empty, ONLY matching packages update (winget/choco/pip filtered paths)
    [ValidateRange(-1, 23)]
    [int]$MaintenanceWindowStart = -1,  # Hour of day (0-23) when updates may begin. -1 = no window enforced.
    [ValidateRange(-1, 23)]
    [int]$MaintenanceWindowEnd   = -1,  # Hour of day when updates must stop. -1 = no window enforced.
    [switch]$AllowMetered,               # Allow updates on metered connections (cellular hotspot). Default: abort on metered.
    [ValidateSet('Full','SuccessOnly','ErrorsOnly','None')]
    [string]$NotificationLevel = 'Full', # Gate toast/webhook/email noise: Full | SuccessOnly | ErrorsOnly | None (event log always written)
    [string]$PreCycleScript  = '',       # Path to a .ps1 hook executed after pre-flight, before the first phase (74r)
    [string]$PostCycleScript = '',       # Path to a .ps1 hook executed after the final phase, before reboot decision (74r)
    [string]$HooksConfig     = (Join-Path $PSScriptRoot 'hooks.psd1'),  # Sidecar PSD1 with per-phase hook scriptblocks (b3w)
    [switch]$DisableSelfUpdate,          # Suppress self-update from GitHub releases (lz1). Default: self-update runs.
    [ValidateScript({ $_ -eq '' -or $_ -match '^https?://' })]
    [string]$ConfigUrl       = '',       # URL for remote JSON config overrides (jzw). Empty = disabled.
    [string]$ExcludePatternsBase64 = '', # Internal scheduled-resume transport (UTF-8 JSON array).
    [string]$IncludePatternsBase64 = '', # Internal scheduled-resume transport (UTF-8 JSON array).
    [ValidateSet('Quiet','Normal','Verbose','Debug')]
    [string]$OutputMode      = 'Normal', # Console detail; press v during an interactive run to cycle modes.
    [switch]$PreviewSplash               # Render all splash themes and exit (no updates). Also via `upd splash`.
)

$ErrorActionPreference = 'Stop'
$script:ScriptBoundParams = @{} + $PSBoundParameters
$decodePatternArray = {
    param([string]$Encoded, [string[]]$Fallback)
    if ([string]::IsNullOrWhiteSpace($Encoded)) { return @($Fallback) }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded))
        return @($json | ConvertFrom-Json -NoEnumerate)
    } catch { throw 'Scheduled resume contains an invalid encoded package-pattern list.' }
}
$ExcludePatterns = @(& $decodePatternArray $ExcludePatternsBase64 $ExcludePatterns)
$IncludePatterns = @(& $decodePatternArray $IncludePatternsBase64 $IncludePatterns)
$script:WebhookSecretPath     = Join-Path $env:ProgramData 'BootUpdateCycle\webhook-url.secret'

function Set-BootUpdateInstallDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    if (-not $IsWindows) { throw 'BootUpdateCycle ACL protection requires Windows.' }
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')

    foreach ($sid in @($administrators, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, $propagation, $allow
        ))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $users, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance, $propagation, $allow
    ))
    $acl.SetOwner($administrators)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-BootUpdateRestrictedFileAcl {
    param([Parameter(Mandatory)][string]$Path)

    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    foreach ($sid in @($administrators, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl, $allow
        ))
    }
    $acl.SetOwner($administrators)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Resolve-BootUpdateTrustedFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TrustRoot,
        [Parameter(Mandatory)][string[]]$AllowedExtension
    )

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        $resolvedRoot = (Resolve-Path -LiteralPath $TrustRoot -ErrorAction Stop).Path.TrimEnd('\')
        $pathWithSeparator = "$resolvedPath\"
        $rootWithSeparator = "$resolvedRoot\"
        if (-not $pathWithSeparator.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        if ([IO.Path]::GetExtension($resolvedPath) -notin $AllowedExtension) { return $null }

        $trustedOwnerSids = @('S-1-5-18', 'S-1-5-32-544')
        $broadWriteSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
        $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor
            [Security.AccessControl.FileSystemRights]::Modify -bor
            [Security.AccessControl.FileSystemRights]::FullControl -bor
            [Security.AccessControl.FileSystemRights]::Delete -bor
            [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [Security.AccessControl.FileSystemRights]::TakeOwnership

        $current = $resolvedPath
        while ($true) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }

            $acl = Get-Acl -LiteralPath $current -ErrorAction Stop
            $ownerSid = if ($acl.Owner -is [Security.Principal.SecurityIdentifier]) {
                $acl.Owner.Value
            } else {
                ([Security.Principal.NTAccount]$acl.Owner).Translate(
                    [Security.Principal.SecurityIdentifier]
                ).Value
            }
            if ($ownerSid -notin $trustedOwnerSids) { return $null }

            foreach ($rule in $acl.Access) {
                if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
                $sid = if ($rule.IdentityReference -is [Security.Principal.SecurityIdentifier]) {
                    $rule.IdentityReference.Value
                } else {
                    $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
                }
                if ($sid -in $broadWriteSids -and (($rule.FileSystemRights -band $writeMask) -ne 0)) {
                    return $null
                }
            }

            if ($current.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
            $current = Split-Path -Parent $current
            if ([string]::IsNullOrWhiteSpace($current)) { return $null }
        }
        return $resolvedPath
    } catch {
        return $null
    }
}

function Set-BootUpdateWebhookSecret {
    param([Parameter(Mandatory)][ValidatePattern('^https://')][string]$Url)

    $secretDir = Split-Path -Parent $script:WebhookSecretPath
    Set-BootUpdateInstallDirectoryAcl -Path $secretDir
    $tempPath = Join-Path $secretDir ('.webhook-url.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType File -Path $tempPath -Force
        Set-BootUpdateRestrictedFileAcl -Path $tempPath
        [IO.File]::WriteAllText($tempPath, $Url, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $script:WebhookSecretPath -Force
        Set-BootUpdateRestrictedFileAcl -Path $script:WebhookSecretPath
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-BootUpdateWebhookSecret {
    if (-not (Test-Path -LiteralPath $script:WebhookSecretPath)) { return '' }
    $trustedPath = Resolve-BootUpdateTrustedFile `
        -Path $script:WebhookSecretPath `
        -TrustRoot (Split-Path -Parent $script:WebhookSecretPath) `
        -AllowedExtension @('.secret')
    if (-not $trustedPath) { throw 'Webhook secret file failed its path or ACL trust check.' }
    $url = (Get-Content -LiteralPath $trustedPath -Raw -Encoding UTF8).Trim()
    if ($url -notmatch '^https://') { throw 'Webhook secret must contain an HTTPS URL.' }
    return $url
}

$script:LogPath               = Join-Path $PSScriptRoot 'BootUpdateCycle.log'
$script:StatePath             = Join-Path $PSScriptRoot 'BootUpdateCycle.state.json'
$script:HistoryPath           = Join-Path $PSScriptRoot 'BootUpdateCycle.history.json'
$script:MaxLogSizeMB          = 5
$script:MaxHistoryEntries     = 50
$script:PackageTimeoutMinutes = $PackageTimeoutMinutes
$script:RebootDelaySec        = $RebootDelaySec
$script:MaxIterations         = $MaxIterations
$script:SkipPip               = $SkipPip
$script:SkipNpm               = $SkipNpm
$script:SkipOffice365         = $SkipOffice365
$script:SkipAwsTooling        = $SkipAwsTooling
$script:SkipPowerShellModules = $SkipPowerShellModules
$script:SkipScoop             = $SkipScoop
$script:SkipDotnetTools       = $SkipDotnetTools
$script:SkipVscode            = $SkipVscode
$script:SkipDefender          = $SkipDefender
$script:IncludeDriverUpdates  = $IncludeDriverUpdates
$script:IncludeFirmwareUpdates = $IncludeFirmwareUpdates
$script:UpdateWsl             = $UpdateWsl
$script:UpdateContainers      = $UpdateContainers
$script:SkipRestorePoint      = $SkipRestorePoint
$script:SkipHealthCheck       = $SkipHealthCheck
$script:SkipBitLocker         = $SkipBitLocker
$script:StagedRollout         = $StagedRollout.IsPresent
$script:BootUpdateMutex       = $null
$script:ExcludePatterns       = $ExcludePatterns
$script:IncludePatterns       = $IncludePatterns
$script:NotificationLevel     = $NotificationLevel
$script:WebhookUrl            = $WebhookUrl
$script:NotifyEmail           = $NotifyEmail
$script:SmtpServer            = $SmtpServer
$script:SmtpCredential        = $SmtpCredential
$script:MaintenanceWindowStart = $MaintenanceWindowStart
$script:MaintenanceWindowEnd   = $MaintenanceWindowEnd
$script:AllowMetered           = $AllowMetered
$script:PreCycleScript         = $PreCycleScript
$script:PostCycleScript        = $PostCycleScript
$script:HooksConfig            = $HooksConfig
$script:PhaseHooks             = @{}
$script:DisableSelfUpdate      = $DisableSelfUpdate
$script:ConfigUrl              = $ConfigUrl
$script:OutputMode             = $OutputMode

if ($PSBoundParameters.ContainsKey('WebhookUrl')) {
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        if (Test-Path -LiteralPath $script:WebhookSecretPath) {
            Remove-Item -LiteralPath $script:WebhookSecretPath -Force
        }
        $script:WebhookUrl = ''
    } else {
        Set-BootUpdateWebhookSecret -Url $WebhookUrl
        $script:WebhookUrl = Get-BootUpdateWebhookSecret
    }
} elseif (Test-Path -LiteralPath $script:WebhookSecretPath) {
    try {
        $script:WebhookUrl = Get-BootUpdateWebhookSecret
    } catch {
        Write-Host "[WARN] Webhook secret unavailable: $_"
        $script:WebhookUrl = ''
    }
}

<# Load per-phase hooks sidecar (hooks.psd1) at script start.
   Evaluated as a scriptblock so values remain actual scriptblocks. The file must
   remain inside the orchestrator directory and pass the full path/ACL trust check. #>
if (-not [string]::IsNullOrWhiteSpace($script:HooksConfig) -and (Test-Path $script:HooksConfig)) {
    try {
        $trustedHooksConfig = Resolve-BootUpdateTrustedFile `
            -Path $script:HooksConfig -TrustRoot $PSScriptRoot -AllowedExtension @('.psd1')
        if (-not $trustedHooksConfig) { throw 'hooks.psd1 failed its path or ACL trust check.' }
        $script:PhaseHooks = & ([scriptblock]::Create((Get-Content $trustedHooksConfig -Raw)))
        if ($script:PhaseHooks -isnot [hashtable]) {
            Write-Host "[WARN] hooks.psd1 did not return a hashtable — hooks disabled."
            $script:PhaseHooks = @{}
        }
    } catch {
        Write-Host "[WARN] hooks.psd1 failed to load: $_ — per-phase hooks disabled."
        $script:PhaseHooks = @{}
    }
}

Set-Variable -Name 'BootUpdateStateSchemaVersion' -Value 3 -Option ReadOnly -Scope Script -ErrorAction SilentlyContinue
Set-Variable -Name 'BootUpdateCycleVersion' -Value '2.5.28' -Option ReadOnly -Scope Script -ErrorAction SilentlyContinue
Set-Variable -Name 'RebootSignalSettleSeconds' -Value 20 -Option ReadOnly -Scope Script -ErrorAction SilentlyContinue
$script:ExplicitRebootRequests = [System.Collections.Generic.List[object]]::new()

<# Force UTF-8 console I/O so box-drawing/block chars (BBS splash) render in cmd.exe regardless of system code page.
   chcp 65001 sets conhost interpretation; [Console]::OutputEncoding makes .NET write proper UTF-8 bytes. #>
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding           = [System.Text.UTF8Encoding]::new($false)
    & chcp.com 65001 > $null 2>&1
} catch { <# no console attached (SYSTEM scheduled task) — ignore #> }

#region Console UX
$script:OutputModes = @('Quiet', 'Normal', 'Verbose', 'Debug')
$script:TuiInteractive = $false
$script:TuiProgressActive = $false
$script:TuiSpinnerIndex = 0
$script:TuiSpinnerFrames = @('|', '/', '-', '\')

function New-BootUpdateNeonGradient {
    param([ValidateRange(4,64)][int]$StepsPerSegment = 12)

    # Closed loop through the splash palette. Interpolation keeps every 100 ms
    # tick close to its neighbor instead of flashing between saturated anchors.
    $anchors = @(
        [int[]]@(80, 255, 230),  # cyan
        [int[]]@(95, 115, 255),  # blue
        [int[]]@(255, 90, 205),  # magenta
        [int[]]@(75, 255, 145)   # acid green
    )
    $gradient = [Collections.Generic.List[string]]::new()
    for ($segment = 0; $segment -lt $anchors.Count; $segment++) {
        $start = $anchors[$segment]
        $end = $anchors[($segment + 1) % $anchors.Count]
        for ($step = 0; $step -lt $StepsPerSegment; $step++) {
            $amount = $step / $StepsPerSegment
            $channels = for ($channel = 0; $channel -lt 3; $channel++) {
                [math]::Round($start[$channel] + (($end[$channel] - $start[$channel]) * $amount))
            }
            $gradient.Add(($channels -join ';'))
        }
    }
    return $gradient.ToArray()
}

$script:TuiNeonPalette = New-BootUpdateNeonGradient
$script:TuiColorIndex = 0
$script:TuiRefreshMilliseconds = 100
$script:TuiSupportsVirtualTerminal = $false
$script:TuiRenderedWidth = 0
$script:TuiRenderedConsoleWidth = 0
$script:TuiCursorWasVisible = $true
$script:TuiCursorHidden = $false
$script:TuiInProgressTick = $false

function Initialize-BootUpdateConsole {
    try {
        $isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
        $script:TuiInteractive = [Environment]::UserInteractive -and -not $isSystem -and
            -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and
            $Host.Name -eq 'ConsoleHost'
        if ($script:TuiInteractive) {
            $script:TuiSupportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal
        }
    } catch {
        $script:TuiInteractive = $false
    }
}

function Test-BootUpdateOutputAtLeast {
    param([Parameter(Mandatory)][ValidateSet('Quiet','Normal','Verbose','Debug')][string]$Minimum)
    return [array]::IndexOf($script:OutputModes, $script:OutputMode) -ge
        [array]::IndexOf($script:OutputModes, $Minimum)
}

function Switch-BootUpdateOutputMode {
    $current = [array]::IndexOf($script:OutputModes, $script:OutputMode)
    $script:OutputMode = $script:OutputModes[($current + 1) % $script:OutputModes.Count]
    $script:ScriptBoundParams['OutputMode'] = $script:OutputMode
    if ($script:OutputMode -eq 'Quiet') { Clear-BootUpdateProgressLine }
    if (-not $script:TuiInProgressTick) {
        Clear-BootUpdateProgressLine
        Write-Host "  output mode: $($script:OutputMode)  (press v to cycle)" -ForegroundColor DarkCyan
    }
}

function Read-BootUpdateUiKeys {
    if (-not $script:TuiInteractive) { return }
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -notin @('v', 'V')) { continue }
            Switch-BootUpdateOutputMode
        }
    } catch {
        # Key polling is an optional enhancement. Disable it if the host detaches.
        Clear-BootUpdateProgressLine
        $script:TuiInteractive = $false
    }
}

function Limit-BootUpdateConsoleText {
    param(
        [AllowEmptyString()][string]$Text,
        [ValidateRange(4,4096)][int]$MaxLength
    )
    if ($Text.Length -le $MaxLength) { return $Text }
    $builder = [Text.StringBuilder]::new()
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = $elements.GetTextElement()
        if (($builder.Length + $element.Length) -gt ($MaxLength - 3)) { break }
        $null = $builder.Append($element)
    }
    return "$builder..."
}

function Get-BootUpdateProgressText {
    param(
        [Parameter(Mandatory)][string]$Frame,
        [Parameter(Mandatory)][string]$Activity,
        [AllowEmptyString()][string]$Status = '',
        [ValidateRange(-1,100)][int]$PercentComplete = -1,
        [ValidateRange(20,4096)][int]$MaxWidth = 88
    )
    $unsafeControls = '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]+'
    $safeActivity = (($Activity -replace $unsafeControls, ' ') -replace '\s+', ' ').Trim()
    $safeActivity = (($safeActivity -replace '^Boot Update Cycle\s*', '') -replace '[^\x20-\x7e]', '?').Trim()
    if (-not $safeActivity) { $safeActivity = 'cycle' }
    $safeStatus = (($Status -replace $unsafeControls, ' ') -replace '\s+', ' ').Trim()
    $safeStatus = ($safeStatus -replace '[^\x20-\x7e]', '?').Trim()
    if (-not $safeStatus) { $safeStatus = 'working' }
    $filled = if ($PercentComplete -ge 0) { [math]::Min(10, [math]::Floor($PercentComplete / 10)) } else { 0 }
    $meter = ('#' * $filled) + ('-' * (10 - $filled))
    $percent = if ($PercentComplete -ge 0) { " $PercentComplete%" } else { '' }
    $line = " BOOT//PULSE [$Frame] $safeActivity :: $safeStatus :: [$meter]$percent :: v:$($script:OutputMode.ToUpperInvariant())"
    return Limit-BootUpdateConsoleText -Text $line -MaxLength $MaxWidth
}

function Clear-BootUpdateProgressLine {
    if (-not $script:TuiProgressActive -and -not $script:TuiCursorHidden) { return }
    try {
        if ($script:TuiSupportsVirtualTerminal) {
            $escape = [char]27
            [Console]::Write("$escape[0m`r$escape[2K")
        } else {
            $width = [math]::Max(1, $script:TuiRenderedWidth)
            try { $width = [math]::Min($width, [math]::Max(1, [Console]::WindowWidth - 1)) } catch { }
            [Console]::Write("`r$(' ' * $width)`r")
        }
    } catch {
        $script:TuiInteractive = $false
    } finally {
        if ($script:TuiCursorHidden) {
            try { [Console]::CursorVisible = $script:TuiCursorWasVisible } catch { }
        }
        $script:TuiProgressActive = $false
        $script:TuiRenderedWidth = 0
        $script:TuiRenderedConsoleWidth = 0
        $script:TuiCursorHidden = $false
    }
}

function Write-BootUpdateLiveText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$PaletteIndex = 0
    )
    try {
        if (-not $script:TuiProgressActive) {
            try {
                $script:TuiCursorWasVisible = [Console]::CursorVisible
                [Console]::CursorVisible = $false
                $script:TuiCursorHidden = $true
            } catch { $script:TuiCursorHidden = $false }
        }
        $availableWidth = 88
        try { $availableWidth = [math]::Max(20, [math]::Min(120, [Console]::WindowWidth - 1)) } catch { }
        $Text = Limit-BootUpdateConsoleText -Text $Text -MaxLength $availableWidth
        if ($script:TuiSupportsVirtualTerminal) {
            $escape = [char]27
            $rgb = $script:TuiNeonPalette[[math]::Abs($PaletteIndex % $script:TuiNeonPalette.Count)]
            $erase = if ($script:TuiRenderedConsoleWidth -gt 0 -and
                $script:TuiRenderedConsoleWidth -ne $availableWidth) { "$escape[2K" } else { '' }
            $paddingCount = [math]::Max(0, $script:TuiRenderedWidth - $Text.Length)
            $paddingCount = [math]::Min($paddingCount, [math]::Max(0, $availableWidth - $Text.Length))
            [Console]::Write("`r$erase$escape[1;38;2;${rgb}m$Text$(' ' * $paddingCount)$escape[0m")
        } else {
            $paddingCount = [math]::Max(0, $script:TuiRenderedWidth - $Text.Length)
            $paddingCount = [math]::Min($paddingCount, [math]::Max(0, $availableWidth - $Text.Length))
            [Console]::Write("`r$Text$(' ' * $paddingCount)")
        }
        $script:TuiRenderedWidth = $Text.Length
        $script:TuiRenderedConsoleWidth = $availableWidth
        $script:TuiProgressActive = $true
    } catch {
        Clear-BootUpdateProgressLine
        $script:TuiInteractive = $false
    }
}

function Write-BootUpdateProgress {
    param(
        [string]$Activity = 'Boot Update Cycle',
        [string]$Status = '',
        [ValidateRange(-1,100)][int]$PercentComplete = -1,
        [switch]$Completed
    )
    $script:TuiInProgressTick = $true
    try { Read-BootUpdateUiKeys } finally { $script:TuiInProgressTick = $false }
    if ($Completed) {
        Clear-BootUpdateProgressLine
        return
    }
    if (-not $script:TuiInteractive -or $script:OutputMode -eq 'Quiet') { return }

    $frame = $script:TuiSpinnerFrames[$script:TuiSpinnerIndex]
    $paletteIndex = $script:TuiColorIndex
    $script:TuiSpinnerIndex = ($script:TuiSpinnerIndex + 1) % $script:TuiSpinnerFrames.Count
    $script:TuiColorIndex = ($script:TuiColorIndex + 1) % $script:TuiNeonPalette.Count
    $maxWidth = 88
    try { $maxWidth = [math]::Max(20, [math]::Min(120, [Console]::WindowWidth - 1)) } catch { }
    $text = Get-BootUpdateProgressText -Frame $frame -Activity $Activity -Status $Status `
        -PercentComplete $PercentComplete -MaxWidth $maxWidth
    Write-BootUpdateLiveText -Text $text -PaletteIndex $paletteIndex
}

function Wait-BootUpdateUiInterval {
    param(
        [Parameter(Mandatory)][ValidateRange(0,86400)][double]$Seconds,
        [string]$Activity = 'Boot Update Cycle',
        [string]$Status = 'Working',
        [ValidateRange(-1,100)][int]$PercentComplete = -1
    )
    if (-not $script:TuiInteractive) {
        Start-Sleep -Milliseconds ([math]::Ceiling($Seconds * 1000))
        return
    }
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        Write-BootUpdateProgress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
        $remainingMs = [math]::Max(0, [math]::Min(
            $script:TuiRefreshMilliseconds,
            ($deadline - [datetime]::UtcNow).TotalMilliseconds
        ))
        if ($remainingMs -gt 0) { Start-Sleep -Milliseconds $remainingMs }
    } while ([datetime]::UtcNow -lt $deadline)
}

function Wait-BootUpdateJobsWithProgress {
    param(
        [Parameter(Mandatory)][object[]]$Jobs,
        [Parameter(Mandatory)][ValidateRange(0,86400)][double]$TimeoutSeconds,
        [string]$Activity = 'Boot Update Cycle',
        [string]$Status = 'Background work is running',
        [ValidateRange(-1,100)][int]$PercentComplete = -1
    )
    if ($Jobs.Count -eq 0) { return $true }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $pending = @($Jobs | Where-Object { $_.State -notin @('Completed','Failed','Stopped') })
        if ($pending.Count -eq 0) { return $true }
        $remainingSeconds = ($deadline - [datetime]::UtcNow).TotalSeconds
        if ($remainingSeconds -le 0) { break }
        Wait-BootUpdateUiInterval -Seconds ([math]::Min(0.2, $remainingSeconds)) `
            -Activity $Activity -Status $Status -PercentComplete $PercentComplete
    } while ([datetime]::UtcNow -lt $deadline)
    return $false
}

function Invoke-BootUpdateBackgroundOperation {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidateRange(0.01,1440)][double]$TimeoutMinutes = 60,
        [string]$Status = 'Background operation is running'
    )
    $result = Invoke-PackageManagerWithTimeout -Name $Name -ScriptBlock $ScriptBlock `
        -ArgumentList $ArgumentList -IdleTimeoutMinutes $TimeoutMinutes `
        -HardTimeoutMinutes $TimeoutMinutes -Status $Status
    return @{
        Output = $result.Output
        TimedOut = $result.TimedOut
        Failed = $result.Failed
        State = $result.Reason
        ExitCode = $result.ExitCode
    }
}

Initialize-BootUpdateConsole
#endregion

#region Logging
$script:LastLogMessage = $null
$script:LastLogRepeatCount = 0

function Invoke-LogRotation {
    if (-not (Test-Path $script:LogPath)) { return }
    $logFile = Get-Item $script:LogPath
    if ($logFile.Length -gt ($script:MaxLogSizeMB * 1MB)) {
        $archivePath = $script:LogPath -replace '\.log$', ".$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        Move-Item $script:LogPath $archivePath -Force
        Get-ChildItem (Split-Path $script:LogPath) -Filter 'BootUpdateCycle.*.log' |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Warn','Error')][string]$Level = 'Info',
        [ValidateSet('Verbose','Debug')][string]$Visibility = 'Verbose'
    )
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $trimmed = $Message.Trim()
    if ($trimmed -match '^[\|/\-\\]$') { return }
    if ($trimmed.Length -le 3 -and $trimmed -match '^[\|/\-\\]+$') { return }
    if ($Message -match '[\u2500-\u257F]|█|▒|░|\x08') { return }
    if ($Message -match 'Γûè|Γûê|ΓûÆ|Γöé|Γö') { return }
    if ($Message -match '^\s*(Downloading|Getting source|Refreshing source)') { return }
    if ($Message -match '^\s*[\d.]+\s*[KMG]?B\s*/\s*[\d.]+\s*[KMG]?B') { return }
    if ($Message -match '^\s+\d+(\.\d+)?\s*[KMG]?\s*(B|K|M)\s*\.{2,}$') { return }
    if ($Message -match '^-{5,}.*\d+\.\d+.*[KMG]?B.*eta') { return }
    if ($Message -match '^\s*━+|^\s*\|█+') { return }
    if ($Message -match '^\s*Progress:') { return }
    if ($Message -match 'is currently in use\.\s*Retry the operation after closing') { return }

    <# Collapse consecutive duplicate lines (installer progress spam that survives the
       pattern filters above). First occurrence logs normally; repeats are counted and
       summarized as one line when the message finally changes. #>
    $trimmedMsg = $Message.TrimEnd()
    if ($trimmedMsg -eq $script:LastLogMessage) {
        $script:LastLogRepeatCount++
        return
    }
    if ($script:LastLogRepeatCount -gt 0) {
        $repeatEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Info] (previous line repeated $($script:LastLogRepeatCount) more time$(if ($script:LastLogRepeatCount -ne 1) { 's' }))"
        Add-Content -Path $script:LogPath -Value $repeatEntry -Force
        if (Test-BootUpdateOutputAtLeast -Minimum Verbose) {
            Clear-BootUpdateProgressLine
            Write-Host $repeatEntry
        }
    }
    $script:LastLogMessage = $trimmedMsg
    $script:LastLogRepeatCount = 0

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $script:LogPath -Value $entry -Force
    Read-BootUpdateUiKeys
    switch ($Level) {
        'Info'  {
            if (Test-BootUpdateOutputAtLeast -Minimum $Visibility) {
                Clear-BootUpdateProgressLine
                Write-Host $entry
            }
        }
        'Warn'  {
            if (Test-BootUpdateOutputAtLeast -Minimum Normal) {
                Clear-BootUpdateProgressLine
                Write-Host $entry -ForegroundColor Yellow
            }
        }
        'Error' {
            Clear-BootUpdateProgressLine
            Write-Host $entry -ForegroundColor Red
        }
    }
}
#endregion

#region State Management
function Get-BootUpdateBootSessionId {
    <# A stable identifier for the current Windows boot. Unlike process time or the
       iteration counter, this changes only after Windows actually boots again. #>
    try {
        return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
    } catch {
        return [datetime]::UtcNow.AddMilliseconds(-[System.Environment]::TickCount64).ToString('yyyy-MM-ddTHH:mmZ')
    }
}

function Update-BootUpdateStateForBootSession {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string]$CurrentBootSessionId
    )
    if ($State.LastBootSessionId -and $State.LastBootSessionId -ne $CurrentBootSessionId) {
        if ($State.Phase -eq 'Rebooting') { $State.RebootCount = [int]$State.RebootCount + 1 }
        $State.ExplicitRebootRequests = @()
    }
    $State.LastBootSessionId = $CurrentBootSessionId
    return $State
}

function Resolve-BootUpdateCompletionDisposition {
    param([object[]]$IncompletePhases = @())
    $userDeferred = @($IncompletePhases | Where-Object { $_.UserCompletionDeferred })
    $retryable = @($IncompletePhases | Where-Object { -not $_.UserCompletionDeferred })
    if ($retryable.Count -gt 0) { return [pscustomobject]@{ Kind='Retry'; Phases=$retryable } }
    if ($userDeferred.Count -gt 0) { return [pscustomobject]@{ Kind='UserContext'; Phases=$userDeferred } }
    return [pscustomobject]@{ Kind='Complete'; Phases=@() }
}

function New-BootUpdateStateV2 {
    return [pscustomobject]@{
        StateVersion          = $script:BootUpdateStateSchemaVersion
        Iteration             = 0
        StartTime             = $null
        LastRun               = $null
        Phase                 = 'Init'
        StagedNextPhase       = $null
        LastPhaseStarted      = $null
        LastPhaseTimestamp     = $null
        WingetDone            = $false
        ChocolateyDone        = $false
        WindowsUpdateDone     = $false
        AwsToolingDone        = $false
        PipDone               = $false
        NpmDone               = $false
        Office365Done         = $false
        PowerShellModulesDone = $false
        ScoopDone             = $false
        DotnetToolsDone       = $false
        VscodeDone            = $false
        DefenderDone          = $false
        DriverFirmwareDone    = $false
        WslDone               = $false
        ContainersDone        = $false
        LastPreflightNetworkOk = $null
        LastPreflightNetworkAt = $null
        LastRebootSignals     = $null
        RebootCount           = 0
        LastBootSessionId     = $null
        ExplicitRebootRequests = @()
        ResumeUser            = $null
        Summary               = [pscustomobject]@{
            Winget = 0; Chocolatey = 0; WindowsUpdate = 0; Pip = 0; Npm = 0; Office365 = 0
            PowerShellModules = 0; Scoop = 0; DotnetTools = 0; Vscode = 0
            Defender = 0; DriverFirmware = 0; Wsl = 0; Containers = 0
            HealthFailed = 0
        }
    }
}

function Update-BootUpdateStateSchema {
    param([Parameter(Mandatory)][pscustomobject]$State)
    $props = $State.PSObject.Properties.Name
    $ver = if ($props -contains 'StateVersion') { [int]$State.StateVersion } else { 1 }

    <# Forward-compat guard: state written by a newer script version — back it up and warn #>
    if ($ver -gt $script:BootUpdateStateSchemaVersion) {
        $bakPath = $script:StatePath -replace '\.json$', ".future-v$ver.bak"
        Write-Log "WARNING: State file has schema version $ver but this script only knows v$($script:BootUpdateStateSchemaVersion). Saving backup to $bakPath before proceeding." -Level Warn
        try { Copy-Item -Path $script:StatePath -Destination $bakPath -Force -EA SilentlyContinue } catch { }
    }

    <# v1 -> v2: rename inconsistent phase flags #>
    if ($ver -lt 2) {
        if (($props -contains 'WindowsUpdate') -and ($props -notcontains 'WindowsUpdateDone')) {
            $State | Add-Member -NotePropertyName 'WindowsUpdateDone' -NotePropertyValue ([bool]$State.WindowsUpdate) -Force
        }
        if ($props -contains 'WindowsUpdate') { $State.PSObject.Properties.Remove('WindowsUpdate') }
        if (($props -contains 'AwsTooling') -and ($props -notcontains 'AwsToolingDone')) {
            $State | Add-Member -NotePropertyName 'AwsToolingDone' -NotePropertyValue ([bool]$State.AwsTooling) -Force
        }
        if ($props -contains 'AwsTooling') { $State.PSObject.Properties.Remove('AwsTooling') }
    }

    <# v2 -> v3: add Defender, DriverFirmware, Wsl, Containers phase flags #>
    if ($ver -lt 3) {
        $props = $State.PSObject.Properties.Name
        foreach ($f in @('DefenderDone','DriverFirmwareDone','WslDone','ContainersDone')) {
            if ($props -notcontains $f) { $State | Add-Member -NotePropertyName $f -NotePropertyValue $false -Force }
        }
    }

    $props = $State.PSObject.Properties.Name
    <# Add-if-missing: crash recovery, new phase flags, network-check cache #>
    foreach ($f in @('LastPhaseStarted','LastPhaseTimestamp','StagedNextPhase','LastPreflightNetworkOk','LastPreflightNetworkAt','LastRebootSignals','LastBootSessionId','ResumeUser')) {
        if ($props -notcontains $f) { $State | Add-Member -NotePropertyName $f -NotePropertyValue $null -Force }
    }
    if ($props -notcontains 'RebootCount') { $State | Add-Member -NotePropertyName 'RebootCount' -NotePropertyValue ([math]::Max(0, [int]$State.Iteration - 1)) -Force }
    if ($props -notcontains 'ExplicitRebootRequests') { $State | Add-Member -NotePropertyName 'ExplicitRebootRequests' -NotePropertyValue @() -Force }
    foreach ($f in @('WindowsUpdateDone','AwsToolingDone','PowerShellModulesDone','ScoopDone','DotnetToolsDone','VscodeDone','DefenderDone','DriverFirmwareDone','WslDone','ContainersDone')) {
        if ($props -notcontains $f) { $State | Add-Member -NotePropertyName $f -NotePropertyValue $false -Force }
    }

    <# Normalise Summary #>
    if ($null -eq $State.Summary) {
        $State.Summary = [pscustomobject]@{
            Winget = 0; Chocolatey = 0; WindowsUpdate = 0; Pip = 0; Npm = 0; Office365 = 0
            PowerShellModules = 0; Scoop = 0; DotnetTools = 0; Vscode = 0
            Defender = 0; DriverFirmware = 0; Wsl = 0; Containers = 0
            HealthFailed = 0
        }
    } elseif ($State.Summary -is [hashtable]) {
        $ht = $State.Summary
        $State.Summary = [pscustomobject]@{
            Winget = [int]($ht['Winget'] ?? 0); Chocolatey = [int]($ht['Chocolatey'] ?? 0)
            WindowsUpdate = [int]($ht['WindowsUpdate'] ?? 0); Pip = [int]($ht['Pip'] ?? 0)
            Npm = [int]($ht['Npm'] ?? 0); Office365 = [int]($ht['Office365'] ?? 0)
            PowerShellModules = [int]($ht['PowerShellModules'] ?? 0); Scoop = [int]($ht['Scoop'] ?? 0)
            DotnetTools = [int]($ht['DotnetTools'] ?? 0); Vscode = [int]($ht['Vscode'] ?? 0)
            Defender = [int]($ht['Defender'] ?? 0); DriverFirmware = [int]($ht['DriverFirmware'] ?? 0)
            Wsl = [int]($ht['Wsl'] ?? 0); Containers = [int]($ht['Containers'] ?? 0)
            HealthFailed = [int]($ht['HealthFailed'] ?? 0)
        }
    } else {
        $sp = $State.Summary.PSObject.Properties.Name
        foreach ($k in @('PowerShellModules','Scoop','DotnetTools','Vscode','Defender','DriverFirmware','Wsl','Containers')) {
            if ($sp -notcontains $k) { $State.Summary | Add-Member -NotePropertyName $k -NotePropertyValue 0 -Force }
        }
        if ($null -eq $State.Summary.HealthFailed) {
            $State.Summary | Add-Member -NotePropertyName 'HealthFailed' -NotePropertyValue 0 -Force
        }
    }

    if ($props -notcontains 'StateVersion') {
        $State | Add-Member -NotePropertyName 'StateVersion' -NotePropertyValue $script:BootUpdateStateSchemaVersion -Force
    } else { $State.StateVersion = $script:BootUpdateStateSchemaVersion }
    return $State
}

function Get-BootUpdateState {
    if (-not (Test-Path $script:StatePath)) { return New-BootUpdateStateV2 }
    try {
        $raw = Get-Content -Path $script:StatePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { Write-Log 'State file empty, starting fresh.' -Level Warn; return New-BootUpdateStateV2 }
        $state = $raw | ConvertFrom-Json -ErrorAction Stop
        return (Update-BootUpdateStateSchema -State $state)
    } catch {
        Write-Log "State file corrupted: $_  Starting fresh." -Level Warn
        $corruptPath = $script:StatePath -replace '\.json$', ".corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        try { Move-Item -Path $script:StatePath -Destination $corruptPath -Force -EA SilentlyContinue } catch { }
        return New-BootUpdateStateV2
    }
}

function Set-BootUpdateState {
    param([Parameter(Mandatory)][pscustomobject]$State)
    <# Skip disk writes in WhatIf mode — state is read-only during dry runs #>
    if ($WhatIfPreference) { return }
    $State.LastRun = (Get-Date).ToUniversalTime().ToString('o')
    $tmpPath = $script:StatePath + '.tmp'
    <# Remove any pre-existing .tmp left by a prior failed write #>
    if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -EA SilentlyContinue }
    try {
        $json = $State | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.Encoding]::UTF8)
        try {
            Move-Item -Path $tmpPath -Destination $script:StatePath -Force -ErrorAction Stop
        } catch {
            Write-Log "Failed to promote state file (Move-Item): $_" -Level Error
            if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -EA SilentlyContinue }
            throw
        }
    } catch {
        Write-Log "Failed to write state: $_" -Level Error
        if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -EA SilentlyContinue }
        throw
    }
}

function Clear-BootUpdateState {
    <# Skip disk writes in WhatIf mode #>
    if ($WhatIfPreference) { return }
    $tmpPath = $script:StatePath + '.tmp'
    if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -EA SilentlyContinue }
    if (Test-Path $script:StatePath) { Remove-Item $script:StatePath -Force }
}

function Test-CrashRecovery {
    param([Parameter(Mandatory)][pscustomobject]$State)
    if ([string]::IsNullOrWhiteSpace($State.LastPhaseStarted)) { return $false }
    $phaseToFlag = @{
        Winget='WingetDone'; Chocolatey='ChocolateyDone'; WindowsUpdate='WindowsUpdateDone'
        AwsTooling='AwsToolingDone'; Pip='PipDone'; Npm='NpmDone'; Office365='Office365Done'
        PowerShellModules='PowerShellModulesDone'; Scoop='ScoopDone'; DotnetTools='DotnetToolsDone'; Vscode='VscodeDone'
        Defender='DefenderDone'; DriverFirmware='DriverFirmwareDone'; Wsl='WslDone'; Containers='ContainersDone'
    }
    <# 'ParallelCohort' is a sentinel written when the five-phase parallel cohort starts.
       Crash recovery for this group is handled per-phase (each has its own *Done flag);
       the cohort re-launches only phases where Done=false, so no special recovery is needed. #>
    if ($State.LastPhaseStarted -eq 'ParallelCohort' -or $State.LastPhaseStarted -eq 'CohortDone') {
        Write-Log "Crash recovery: previous run was in parallel cohort — individual phase flags will gate re-execution." -Level Warn
        return $false
    }
    $flagName = $phaseToFlag[$State.LastPhaseStarted]
    if (-not $flagName) {
        Write-Log "Crash recovery: unknown phase '$($State.LastPhaseStarted)' in state file — ignoring." -Level Warn
        return $false
    }
    $isDone = if ($flagName -and ($State.PSObject.Properties.Name -contains $flagName)) { [bool]$State.$flagName } else { $false }
    if (-not $isDone) {
        $time = if ($State.LastPhaseTimestamp) { try { ([datetime]$State.LastPhaseTimestamp).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } catch { $State.LastPhaseTimestamp } } else { '(unknown)' }
        Write-Log "Previous run crashed during [$($State.LastPhaseStarted)] at [$time]. Restarting that phase." -Level Warn
        return $true
    }
    return $false
}

function Save-CycleHistory {
    param([pscustomobject]$State, [timespan]$Duration)
    <# Skip disk writes in WhatIf mode #>
    if ($WhatIfPreference) { return }
    $s = $State.Summary
    $entry = [pscustomobject]@{
        Timestamp = Get-Date -Format 'o'
        Iterations = $State.Iteration
        DurationMinutes = [math]::Round($Duration.TotalMinutes, 1)
        Winget = $s.Winget; Chocolatey = $s.Chocolatey; WindowsUpdate = $s.WindowsUpdate
        Pip = $s.Pip; Npm = $s.Npm; Office365 = $s.Office365
        PowerShellModules = $s.PowerShellModules; Scoop = $s.Scoop; DotnetTools = $s.DotnetTools; Vscode = $s.Vscode
        HealthFailed = if ($null -ne $s.HealthFailed) { [int]$s.HealthFailed } else { 0 }
        Total = $s.Winget + $s.Chocolatey + $s.WindowsUpdate + $s.Pip + $s.Npm + $s.Office365 + $s.PowerShellModules + $s.Scoop + $s.DotnetTools + $s.Vscode
    }
    $history = @()
    if (Test-Path $script:HistoryPath) {
        try {
            $history = @(Get-Content $script:HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            Write-Log "History file unreadable, starting fresh: $_" -Level Warn
            $history = @()
        }
    }
    $history = @($entry) + $history | Select-Object -First $script:MaxHistoryEntries
    $histTmpPath = $script:HistoryPath + '.tmp'
    if (Test-Path $histTmpPath) { Remove-Item $histTmpPath -Force -EA SilentlyContinue }
    $history | ConvertTo-Json -Depth 5 | Set-Content $histTmpPath -Force
    Move-Item -Path $histTmpPath -Destination $script:HistoryPath -Force
}
#endregion

#region Pre-flight Checks
function Test-PreFlightChecks {
    [CmdletBinding()]
    param(
        [switch]$Force,
        [pscustomobject]$State = $null
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()
    function Add-Warning { param([string]$Msg) $warnings.Add($Msg); Write-Log $Msg -Level Warn }
    function Add-Error   { param([string]$Msg) $errors.Add($Msg);   Write-Log $Msg -Level Error }

    Write-Log 'Pre-flight checks starting...'

    <# Disk space #>
    try {
        $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        Write-Log "Disk: $env:SystemDrive has $freeGB GB free"
        if ($freeGB -lt 5) { Add-Error "ABORT: $env:SystemDrive has only ${freeGB}GB free (minimum 5 GB)" }
        elseif ($freeGB -lt 10) { Add-Warning "LOW DISK: ${freeGB}GB free on $env:SystemDrive (recommend 10+)" }
    } catch { Add-Warning "Disk check failed: $_" }

    <# Network — with 5-minute within-cycle cache to avoid 5-10s TCP probes on every iteration.
       Cache is cleared on reboot (LastPreflightNetworkAt reset in phase-reset block) so a fresh
       boot always re-probes. Failures are never cached — we want fast retry on transient drops. #>
    $networkCacheHit = $false
    if ($null -ne $State) {
        $cachedAt  = if ($State.LastPreflightNetworkAt) { try { [datetime]$State.LastPreflightNetworkAt } catch { $null } } else { $null }
        $cachedOk  = if ($null -ne $State.LastPreflightNetworkOk) { [bool]$State.LastPreflightNetworkOk } else { $false }
        if ($cachedAt -and $cachedOk -and ((Get-Date) - $cachedAt) -lt [TimeSpan]::FromMinutes(5)) {
            Write-Log "Pre-flight network: cached OK from $($cachedAt.ToString('HH:mm:ss')) (skipping probes)"
            $networkCacheHit = $true
        }
    }

    if (-not $networkCacheHit) {
        $networkProbeOk = $false
        try {
            $dnsOk = $false
            try { $null = [System.Net.Dns]::GetHostAddresses('github.com'); $dnsOk = $true; Write-Log 'Network: DNS OK' }
            catch { Add-Warning "Network: DNS failed ($_)" }
            $allTcpOk = $true
            if ($dnsOk) {
                foreach ($target in @(@{H='chocolatey.org';P=443}, @{H='github.com';P=443})) {
                    try {
                        $tcp = [System.Net.Sockets.TcpClient]::new()
                        $connected = $tcp.ConnectAsync($target.H, $target.P).Wait(5000)
                        $tcp.Close()
                        if ($connected) { Write-Log "Network: $($target.H):$($target.P) OK" }
                        else { Add-Warning "Network: $($target.H) unreachable"; $allTcpOk = $false }
                    } catch { Add-Warning "Network: $($target.H) error: $_"; $allTcpOk = $false }
                }
            }
            $networkProbeOk = $dnsOk -and $allTcpOk
        } catch { Add-Warning "Network checks failed: $_" }

        <# Persist probe result only when OK — failed results are not cached so next iteration re-probes #>
        if ($null -ne $State -and $networkProbeOk) {
            $State.LastPreflightNetworkOk = $true
            $State.LastPreflightNetworkAt = (Get-Date).ToString('o')
            Set-BootUpdateState -State $State
        }
    }

    <# Metered connection detection — abort by default; $AllowMetered overrides.
       WinRT API is preferred; falls back to CIM on Server Core where WinRT may be unavailable. #>
    $meteredDetected = $false
    $meteredDetectionFailed = $false
    try {
        $null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime]
        $cp   = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if ($cp) {
            $cost = $cp.GetConnectionCost()
            $meteredDetected = $cost.NetworkCostType -ne 'Unrestricted'
        }
    } catch {
        <# WinRT load failed (Server Core, older build, or no COM registration) — fall back to CIM #>
        try {
            $profiles = Get-NetConnectionProfile -EA Stop | Where-Object { $_.IPv4Connectivity -eq 'Internet' -or $_.IPv6Connectivity -eq 'Internet' }
            foreach ($prof in $profiles) {
                $cimProf = Get-CimInstance -Namespace root\StandardCimv2 -ClassName MSFT_NetConnectionProfile `
                    -Filter "Name='$($prof.Name)'" -EA SilentlyContinue
                <# NetworkCategory 1 = Private, 2 = DomainAuthenticated, 3 = Public; metered is a separate IsMetered field #>
                if ($cimProf -and $cimProf.PSObject.Properties['IsMetered'] -and $cimProf.IsMetered) {
                    $meteredDetected = $true; break
                }
            }
        } catch {
            Write-Log "Metered connection check failed (both WinRT and CIM): $_ — skipping check" -Level Warn
            $meteredDetectionFailed = $true
        }
    }

    if (-not $meteredDetectionFailed -and $meteredDetected) {
        if ($script:AllowMetered) {
            Write-Log 'Network: metered connection detected — proceeding anyway (-AllowMetered)' -Level Warn
        } else {
            Add-Error 'Network: metered connection detected — deferring to avoid cellular data usage. Use -AllowMetered to override.'
        }
    } elseif (-not $meteredDetectionFailed) {
        Write-Log 'Network: connection is unmetered'
    }

    <# Conflicting installers #>
    try {
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($name in @('msiexec','TrustedInstaller','TiWorker')) {
            $procs = Get-Process -Name $name -EA SilentlyContinue
            if ($procs) { $found.Add("$name (PID $(($procs.Id) -join ','))") }
        }
        if ($found.Count -gt 0) { Add-Warning "Installers running: $($found -join '; ')" }
        else { Write-Log 'Installer check: no conflicts' }
    } catch { Add-Warning "Installer check failed: $_" }

    <# Windows Update service #>
    try {
        $svc = Get-Service wuauserv -ErrorAction Stop
        if ($svc.StartType -eq 'Disabled') { Add-Error 'Windows Update service is Disabled' }
        elseif ($svc.Status -ne 'Running') {
            try { Start-Service wuauserv -ErrorAction Stop; Write-Log 'WU service: started' }
            catch { Add-Warning "WU service could not start: $_" }
        }
    } catch { Add-Warning "WU service check failed: $_" }

    <# Battery #>
    try {
        $bat = Get-CimInstance Win32_Battery -EA Stop
        if ($bat) {
            $onBattery = ($bat.BatteryStatus -eq 1)
            $charge = $bat.EstimatedChargeRemaining
            Write-Log "Battery: ${charge}%, on battery: $onBattery"
            if ($onBattery -and $charge -lt 30) { Add-Warning "BATTERY LOW: ${charge}% on battery — plug in before updating" }
            elseif ($onBattery) { Add-Warning "On battery (${charge}%) — recommend plugging in" }
        } else { Write-Log 'Battery: none detected (desktop/VM)' }
    } catch { Add-Warning "Battery check failed: $_" }

    <# PS version #>
    if ($PSVersionTable.PSVersion.Major -lt 7) { Add-Error "PowerShell 7+ required; running $($PSVersionTable.PSVersion)" }

    $canProceed = ($errors.Count -eq 0) -and (($warnings.Count -eq 0) -or $Force.IsPresent)
    $summary = if ($errors.Count -gt 0) { "BLOCKED ($($errors.Count) error(s))" }
               elseif ($warnings.Count -gt 0 -and -not $Force) { "BLOCKED ($($warnings.Count) warning(s)); use -Force to override" }
               elseif ($warnings.Count -gt 0) { "PROCEEDING with $($warnings.Count) warning(s) (-Force)" }
               else { 'ALL CHECKS PASSED' }
    Write-Log "Pre-flight: $summary"
    return [PSCustomObject]@{ CanProceed = $canProceed; Warnings = $warnings.ToArray(); Errors = $errors.ToArray() }
}
#endregion

#region Restore Point
function New-SystemRestorePoint {
    <#
    .SYNOPSIS
        Creates a Windows System Restore point before running updates.
    .NOTES
        Best-effort: failure logs a warning and returns $false — does NOT abort the cycle.
        Skipped automatically under SYSTEM context (Checkpoint-Computer requires interactive session).
        Skipped on Server SKUs where System Restore service is absent or disabled.
        Skipped in WhatIf mode.
    #>
    if ($WhatIfPreference) {
        Write-Log '  [WHATIF] Would create System Restore point'
        return $false
    }
    if ($script:SkipRestorePoint) {
        Write-Log 'System restore point: skipped (-SkipRestorePoint)'
        return $false
    }

    <# SYSTEM context check: Checkpoint-Computer requires interactive/user session on Windows 11 #>
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($currentIdentity.Name -match 'SYSTEM') {
        Write-Log 'System restore point: skipped (running as SYSTEM — Checkpoint-Computer requires interactive session)' -Level Warn
        return $false
    }

    <# SystemRestore service check: absent/disabled on Server SKUs #>
    try {
        $srSvc = Get-Service -Name 'SDRSVC' -ErrorAction Stop
        if ($srSvc.StartType -eq 'Disabled') {
            Write-Log 'System restore point: skipped (System Restore service is Disabled — likely Server SKU)' -Level Warn
            return $false
        }
    } catch {
        Write-Log "System restore point: skipped (System Restore service not found — likely Server SKU: $_)" -Level Warn
        return $false
    }

    <# Enable System Protection on the system drive (idempotent, safe) #>
    try {
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction Stop
        Write-Log "System restore: protection enabled on $env:SystemDrive"
    } catch {
        Write-Log "System restore: Enable-ComputerRestore failed (non-fatal): $_" -Level Warn
        <# Do not return — Checkpoint-Computer may still work if protection was already on #>
    }

    <# Create the restore point #>
    try {
        $description = "BootUpdateCycle pre-update $(Get-Date -Format 'yyyy-MM-dd')"
        Checkpoint-Computer -Description $description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log "System restore point created: $description"
        return $true
    } catch {
        Write-Log "System restore point creation failed (non-fatal): $_" -Level Warn
        return $false
    }
}
#endregion

#region Package Filtering
function Test-PackageExcluded {
    <#
    .SYNOPSIS
        Central exclude/include filter for package names/IDs.
    .OUTPUTS
        The reason string when the package should be SKIPPED, else $null.
    .NOTES
        ExcludePatterns: wildcard match (-like) when the pattern contains * or ?,
        legacy case-insensitive substring otherwise. IncludePatterns (allowlist),
        when non-empty, skips anything that matches no include pattern.
    #>
    param([Parameter(Mandatory)][string]$Name)
    foreach ($pattern in $script:ExcludePatterns) {
        if ($pattern -match '[\*\?]') {
            if ($Name -like $pattern) { return "excluded by pattern '$pattern'" }
        } elseif ($Name.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return "excluded by pattern '$pattern'"
        }
    }
    if ($script:IncludePatterns.Count -gt 0) {
        foreach ($pattern in $script:IncludePatterns) {
            if ($pattern -match '[\*\?]') {
                if ($Name -like $pattern) { return $null }
            } elseif ($Name.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $null
            }
        }
        return 'not in IncludePatterns allowlist'
    }
    return $null
}
#endregion

#region Notification Gating
function Test-NotificationAllowed {
    <# Gates BurntToast/webhook/email noise by -NotificationLevel. Windows Event Log
       entries are NOT gated — they remain the always-on audit trail. #>
    param([Parameter(Mandatory)][ValidateSet('Success','Error','Progress')][string]$Kind)
    switch ($script:NotificationLevel) {
        'None'        { return $false }
        'ErrorsOnly'  { return ($Kind -eq 'Error') }
        'SuccessOnly' { return ($Kind -eq 'Success') }
        default       { return $true }
    }
}
#endregion

#region Pending Reboot Detection
function Test-PendingReboot {
    <# Comprehensive pending-reboot detection based on Boxstarter/Brian Wilhite's
       Get-PendingReboot approach.  Checks every OS-level signal that a reboot is
       needed and reports per-signal detail (the "why") so stale signals — the
       classic cause of reboot loops — are diagnosable straight from the log. #>
    $results = [System.Collections.Generic.List[object]]::new()
    $report = { param($Source, $Detail) $results.Add([pscustomobject]@{ Source = $Source; Status = 'Pending'; Detail = $Detail }) }

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        & $report 'CBS' 'Component Based Servicing: RebootPending key present'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') {
        & $report 'CBS-Packages' 'Component Based Servicing: PackagesPending key present (servicing stack has staged packages)'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        & $report 'WU' 'Windows Update: RebootRequired key present'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting') {
        & $report 'WU-PostReboot' 'Windows Update: PostRebootReporting key present (WU wants a post-reboot report pass)'
    }
    $val = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -EA Ignore
    if ($val -and $val.PendingFileRenameOperations.Count -gt 0) {
        $entries = @($val.PendingFileRenameOperations | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $sample = @($entries | Select-Object -First 3 | ForEach-Object { $_ -replace '^[!*\d]*\\\?\?\\', '' })
        & $report 'FileRename' "$($entries.Count) pending file rename op(s); e.g. $($sample -join '; ')"
    }
    $r = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -EA Ignore
    $a = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -EA Ignore
    if ($r -and $a -and $r.ComputerName -ne $a.ComputerName) {
        & $report 'ComputerRename' "active '$($a.ComputerName)' -> pending '$($r.ComputerName)'"
    }
    if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name 'JoinDomain' -EA Ignore) -or
        (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name 'AvoidSpnSet' -EA Ignore)) {
        & $report 'JoinDomain' 'Netlogon JoinDomain/AvoidSpnSet value present (pending domain join)'
    }
    try {
        $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' `
            -MethodName 'DetermineIfRebootPending' -EA Stop
        if ($ccm -and ($ccm.ReturnValue -eq 0) -and ($ccm.IsHardRebootPending -or $ccm.RebootPending)) {
            & $report 'SCCM' "CCM client: hard=$($ccm.IsHardRebootPending) soft=$($ccm.RebootPending)"
        }
    } catch { }  <# SCCM client not installed — expected on most workstations #>

    return @($results)
}

function Get-ConfirmedPendingReboot {
    <# Reboot indicators are not guaranteed to appear synchronously with an installer
       returning. A clean result is therefore provisional: keep the live UI moving,
       allow CBS/WU/installers to settle, then require a second independent clean read.
       Explicit 3010/1641 evidence is durable for the process and bypasses the wait. #>
    if ($script:ExplicitRebootRequests.Count -gt 0) {
        return @($script:ExplicitRebootRequests)
    }

    $first = @(Test-PendingReboot)
    if ($first.Count -gt 0) { return $first }

    Write-Log "Final verification: first reboot probe is clean; allowing $($script:RebootSignalSettleSeconds)s for delayed servicing signals." -Visibility Verbose
    Wait-BootUpdateUiInterval -Seconds $script:RebootSignalSettleSeconds `
        -Activity 'VERIFY//SETTLE' -Status 'Watching for delayed Windows reboot signals' -PercentComplete 99

    $second = @(Test-PendingReboot)
    if ($script:ExplicitRebootRequests.Count -gt 0) {
        return @($script:ExplicitRebootRequests) + $second
    }
    return $second
}
#endregion

#region Smart Timeout
function Get-ProcessTreeActivity {
    param([Parameter(Mandatory)][int]$ParentPid)
    $allProcs = Get-CimInstance Win32_Process -EA SilentlyContinue
    if (-not $allProcs) { return [pscustomobject]@{ TotalCpuTime = [timespan]::Zero; ProcessCount = 0; HandleCount = 0 } }

    $byPid = @{}; $childMap = @{}
    foreach ($p in $allProcs) {
        $byPid[$p.ProcessId] = $p
        if (-not $childMap.ContainsKey($p.ParentProcessId)) { $childMap[$p.ParentProcessId] = [System.Collections.Generic.List[int]]::new() }
        $childMap[$p.ParentProcessId].Add($p.ProcessId)
    }

    $queue = [System.Collections.Generic.Queue[int]]::new(); $visited = [System.Collections.Generic.HashSet[int]]::new()
    $queue.Enqueue($ParentPid)
    $totalCpuMs = [int64]0; $procCount = 0; $handles = 0

    while ($queue.Count -gt 0) {
        $procId = $queue.Dequeue()
        if (-not $visited.Add($procId)) { continue }
        $cim = $byPid[$procId]
        if ($cim) {
            $totalCpuMs += ([int64]$cim.KernelModeTime + [int64]$cim.UserModeTime) / 10000
            $handles += [int]$cim.HandleCount; $procCount++
        }
        if ($childMap.ContainsKey($procId)) { foreach ($c in $childMap[$procId]) { if (-not $visited.Contains($c)) { $queue.Enqueue($c) } } }
    }
    return [pscustomobject]@{ TotalCpuTime = [timespan]::FromMilliseconds($totalCpuMs); ProcessCount = $procCount; HandleCount = $handles }
}

function Wait-ProcessWithIdleTimeout {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [string]$ActivityName = 'Package manager',
        [string]$Status = 'Operation is running',
        [double]$IdleTimeoutMinutes = 5, [double]$HardTimeoutMinutes = 60,
        [ValidateRange(0.2,30)][double]$PollIntervalSeconds = 1
    )
    $startTime = [datetime]::UtcNow; $lastCpuIncrease = $startTime; $lastCpuTime = [timespan]::Zero; $finalCpu = [timespan]::Zero
    $hardLimit = [timespan]::FromMinutes($HardTimeoutMinutes); $idleLimit = [timespan]::FromMinutes($IdleTimeoutMinutes)

    function Remove-ProcessTree { param([int]$RootPid)
        $rootProcess = Get-Process -Id $RootPid -EA SilentlyContinue
        if ($rootProcess -and -not $rootProcess.HasExited) {
            try {
                $rootProcess.Kill($true)
                $null = $rootProcess.WaitForExit(5000)
                Write-Log "Killed process tree rooted at PID $RootPid ($($rootProcess.ProcessName))" -Level Warn
                return
            } catch {
                Write-Log "Process-tree kill API failed for PID $RootPid; using CIM fallback: $_" -Level Warn
            }
        }
        $all = Get-CimInstance Win32_Process -EA SilentlyContinue; if (-not $all) { return }
        $cm = @{}; foreach ($p in $all) { if (-not $cm.ContainsKey($p.ParentProcessId)) { $cm[$p.ParentProcessId] = [System.Collections.Generic.List[int]]::new() }; $cm[$p.ParentProcessId].Add($p.ProcessId) }
        $ordered = [System.Collections.Generic.List[int]]::new(); $q = [System.Collections.Generic.Queue[int]]::new(); $v = [System.Collections.Generic.HashSet[int]]::new()
        $q.Enqueue($RootPid)
        while ($q.Count -gt 0) { $id = $q.Dequeue(); if (-not $v.Add($id)) { continue }; $ordered.Add($id); if ($cm.ContainsKey($id)) { foreach ($c in $cm[$id]) { $q.Enqueue($c) } } }
        $ordered.Reverse()
        foreach ($id in $ordered) { $p = Get-Process -Id $id -EA SilentlyContinue; if ($p -and -not $p.HasExited) { try { $p.Kill(); Write-Log "Killed PID $id ($($p.ProcessName))" -Level Warn } catch { } } }
    }

    while ($true) {
        $Process.Refresh()
        if ($Process.HasExited) {
            $elapsed = [datetime]::UtcNow - $startTime
            Write-Log "Process PID $($Process.Id) exited normally ($([math]::Round($elapsed.TotalMinutes,1))m)"
            return @{ Reason = 'Completed'; Elapsed = $elapsed; FinalCpuTime = $finalCpu; ExitCode = $Process.ExitCode }
        }
        $elapsed = [datetime]::UtcNow - $startTime
        if ($elapsed -ge $hardLimit) {
            Write-Log "HARD TIMEOUT: PID $($Process.Id) exceeded $HardTimeoutMinutes min. Killing." -Level Error
            $tree = Get-ProcessTreeActivity -ParentPid $Process.Id
            Write-Log "  Tree at kill: $($tree.ProcessCount) processes, CPU=$([math]::Round($tree.TotalCpuTime.TotalSeconds,1))s, handles=$($tree.HandleCount)" -Level Warn
            Remove-ProcessTree -RootPid $Process.Id
            return @{ Reason = 'HardTimeout'; Elapsed = $elapsed; FinalCpuTime = $tree.TotalCpuTime; ExitCode = $null }
        }
        $activity = Get-ProcessTreeActivity -ParentPid $Process.Id; $finalCpu = $activity.TotalCpuTime
        if ($activity.TotalCpuTime -gt $lastCpuTime) { $lastCpuTime = $activity.TotalCpuTime; $lastCpuIncrease = [datetime]::UtcNow }
        $idleFor = [datetime]::UtcNow - $lastCpuIncrease
        if ($idleFor -ge $idleLimit) {
            Write-Log "IDLE TIMEOUT: PID $($Process.Id) idle $([math]::Round($idleFor.TotalMinutes,1))m (threshold: ${IdleTimeoutMinutes}m), final CPU=$([math]::Round($activity.TotalCpuTime.TotalSeconds,1))s. Killing." -Level Error
            Write-Log "  Tree at kill: $($activity.ProcessCount) processes, handles=$($activity.HandleCount)" -Level Warn
            Remove-ProcessTree -RootPid $Process.Id
            return @{ Reason = 'IdleTimeout'; Elapsed = $elapsed; FinalCpuTime = $finalCpu; ExitCode = $null }
        }
        $progressStatus = "$Status | CPU $([math]::Round($activity.TotalCpuTime.TotalSeconds,1))s | $($activity.ProcessCount) proc | idle $([math]::Round($idleFor.TotalMinutes,1))m | elapsed $([math]::Round($elapsed.TotalMinutes,1))m"
        $percent = [math]::Min(99, [math]::Floor(($elapsed.TotalSeconds / $hardLimit.TotalSeconds) * 100))
        Write-Log "  heartbeat: CPU=$([math]::Round($activity.TotalCpuTime.TotalSeconds,1))s procs=$($activity.ProcessCount) idle=$([math]::Round($idleFor.TotalMinutes,1))m elapsed=$([math]::Round($elapsed.TotalMinutes,1))m" -Visibility Debug
        Wait-BootUpdateUiInterval -Seconds $PollIntervalSeconds -Activity $ActivityName -Status $progressStatus -PercentComplete $percent
    }
}

function Invoke-PackageManagerWithTimeout {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [double]$IdleTimeoutMinutes = 5, [double]$HardTimeoutMinutes = 60,
        [string]$Status = 'Operation is running'
    )
    $pwshPath = (Get-Command pwsh -EA SilentlyContinue)?.Source
    if (-not $pwshPath) { $pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
    if (-not (Test-Path $pwshPath)) { throw "pwsh not found for '$Name'" }

    $outputFile = [System.IO.Path]::GetTempFileName()
    $sbText = $ScriptBlock.ToString()
    $argsJson = $ArgumentList | ConvertTo-Json -Compress -Depth 5
    $childScript = @"
`$sb = [scriptblock]::Create(@'
$sbText
'@)
`$argList = (`'$argsJson`' | ConvertFrom-Json -NoEnumerate)
if (`$argList -isnot [array]) { `$argList = @(`$argList) }
try {
    `$global:LASTEXITCODE = `$null
    & `$sb @argList 2>&1 | ForEach-Object { `$_.ToString() } | Out-File -FilePath '$($outputFile -replace "'","''")' -Encoding UTF8 -Append
    if (`$null -ne `$LASTEXITCODE) {
        "BOOTUPDATE_NATIVE_EXIT|`$LASTEXITCODE" | Out-File -FilePath '$($outputFile -replace "'","''")' -Encoding UTF8 -Append
    }
} catch {
    "BOOTUPDATE_ERROR|`$(`$_.Exception.Message)" | Out-File -FilePath '$($outputFile -replace "'","''")' -Encoding UTF8 -Append
    exit 1
}
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
    Write-Log "${Name}: Starting (idle: ${IdleTimeoutMinutes}m, hard: ${HardTimeoutMinutes}m)"

    $si = [System.Diagnostics.ProcessStartInfo]@{
        FileName = $pwshPath; Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
        UseShellExecute = $false; RedirectStandardOutput = $false; RedirectStandardError = $false; CreateNoWindow = $true
    }
    $proc = [System.Diagnostics.Process]::Start($si)
    if (-not $proc) {
        Write-Log "${Name}: Failed to start." -Level Error
        return @{ Output = @(); TimedOut = $false; Failed = $true; Reason = 'StartFailed'; Elapsed = [timespan]::Zero; ExitCode = $null }
    }
    Write-Log "${Name}: PID $($proc.Id)" -Visibility Debug
    $result = Wait-ProcessWithIdleTimeout -Process $proc -ActivityName $Name -Status $Status `
        -IdleTimeoutMinutes $IdleTimeoutMinutes -HardTimeoutMinutes $HardTimeoutMinutes -PollIntervalSeconds 1

    $output = @()
    if (Test-Path $outputFile) { $output = @(Get-Content $outputFile -Encoding UTF8 -EA SilentlyContinue); Remove-Item $outputFile -Force -EA SilentlyContinue }
    $nativeExitCode = $null
    $visibleOutput = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $output) {
        if ($line -match '^BOOTUPDATE_NATIVE_EXIT\|(-?\d+)$') {
            $nativeExitCode = [int]$Matches[1]
            continue
        }
        $visibleOutput.Add($line)
    }
    $effectiveExitCode = if ($null -ne $nativeExitCode) { $nativeExitCode } else { $result.ExitCode }
    $rebootRequired = $effectiveExitCode -in @(1641, 3010)
    if ($rebootRequired) {
        $rebootEvidence = [pscustomobject]@{
            Source = "$Name-exit-$effectiveExitCode"
            Status = 'Pending'
            Detail = "$Name requested a reboot (native exit code $effectiveExitCode)"
        }
        $script:ExplicitRebootRequests.Add($rebootEvidence)
        if ($script:CurrentState) {
            $script:CurrentState.ExplicitRebootRequests = @($script:ExplicitRebootRequests)
            Set-BootUpdateState -State $script:CurrentState
        }
        Write-Log "$Name requested a reboot (native exit code $effectiveExitCode)." -Level Warn
    }
    $timedOut = $result.Reason -in @('IdleTimeout','HardTimeout')
    $failed = $timedOut -or $result.Reason -ne 'Completed' -or $effectiveExitCode -notin @(0, 1641, 3010)
    if ($timedOut) { Write-Log "${Name}: Killed ($($result.Reason)) after $([math]::Round($result.Elapsed.TotalMinutes,1))m. Will retry next boot." -Level Warn }
    elseif ($failed) { Write-Log "${Name}: child process exited with code $effectiveExitCode." -Level Warn }
    else { Write-Log "${Name}: Done in $([math]::Round($result.Elapsed.TotalMinutes,1))m" }
    return @{ Output = $visibleOutput.ToArray(); TimedOut = $timedOut; Failed = $failed; Reason = $result.Reason; Elapsed = $result.Elapsed; ExitCode = $effectiveExitCode; RebootRequired = $rebootRequired }
}
#endregion

#region Package Manager Updates
function Update-WingetPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $TimeoutMinutes = $script:PackageTimeoutMinutes
    $wingetPath = $null
    $wg = Get-Command winget -EA SilentlyContinue
    if ($wg) { $wingetPath = $wg.Source }
    else {
        $candidates = @(
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'),
            (Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        )
        foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $wingetPath = $c; break } }
    }
    if (-not $wingetPath) { Write-Log 'Winget not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log "Using winget: $wingetPath"

    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) { $scopes = @('machine'); Write-Log 'SYSTEM context: machine scope only' }
    else { $scopes = @('user', 'machine'); Write-Log 'User context: updating BOTH user + machine scopes' }

    $totalCount = 0; $anyTimeout = $false

    <# ── Fast path (no ExcludePatterns): run user + machine scopes in parallel via ThreadJob ──
       Each job launches winget upgrade --all in a child pwsh.exe and captures output to a temp
       file (same technique as Invoke-PackageManagerWithTimeout).  Results are collected on the
       parent thread after both jobs complete or the combined hard timeout fires.
       The filtered path (ExcludePatterns active) stays sequential — per-package iteration is
       order-sensitive and scopes cannot safely enumerate the same winget DB concurrently. #>
    if ($script:ExcludePatterns.Count -eq 0 -and $script:IncludePatterns.Count -eq 0 -and $scopes.Count -gt 1) {
        Write-Log 'Winget: running user + machine scopes in parallel (no package filters)'
        if ($PSCmdlet.ShouldProcess('Winget (user + machine parallel)', 'Run Winget upgrades for both scopes concurrently')) {
            $hardTimeoutSec = $TimeoutMinutes * 60

            <# Launch one ThreadJob per scope.  Each job: spawns a child pwsh.exe, waits for it,
               returns @{ Scope; Lines; TimedOut; Count }.  The child writes output to a temp file
               to avoid interleaved console writes between the two parallel jobs. #>
            $wingetJobSb = {
                param($Scope, $WingetPath, $TimeoutSec)
                $tmpOut = [System.IO.Path]::GetTempFileName()
                $childScript = @"
`$global:LASTEXITCODE = `$null
& '$($WingetPath -replace "'","''")' upgrade --all --scope $Scope --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1 | ForEach-Object { `$_.ToString() } | Out-File -FilePath '$($tmpOut -replace "'","''")' -Encoding UTF8 -Append
if (`$null -ne `$LASTEXITCODE) { "BOOTUPDATE_NATIVE_EXIT|`$LASTEXITCODE" | Out-File -FilePath '$($tmpOut -replace "'","''")' -Encoding UTF8 -Append }
"@
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
                $pw = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
                if (-not $pw) { $pw = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
                $proc = [System.Diagnostics.Process]::Start([System.Diagnostics.ProcessStartInfo]@{
                    FileName        = $pw
                    Arguments       = "-NoProfile -NonInteractive -EncodedCommand $encoded"
                    UseShellExecute = $false
                    CreateNoWindow  = $true
                })
                $timedOut = $false
                if ($proc) {
                    $exited = $proc.WaitForExit($TimeoutSec * 1000)
                    if (-not $exited) {
                        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
                        $timedOut = $true
                    }
                }
                $lines = @()
                if (Test-Path $tmpOut) {
                    $lines = @(Get-Content $tmpOut -Encoding UTF8 -ErrorAction SilentlyContinue)
                    Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
                }
                $nativeExit = $null
                $visibleLines = [System.Collections.Generic.List[string]]::new()
                foreach ($line in $lines) {
                    if ($line -match '^BOOTUPDATE_NATIVE_EXIT\|(-?\d+)$') { $nativeExit = [int]$Matches[1] }
                    else { $visibleLines.Add($line) }
                }
                $lines = $visibleLines.ToArray()
                $count = @($lines | Where-Object { $_ -match 'Successfully installed' }).Count
                return @{ Scope = $Scope; Lines = $lines; TimedOut = $timedOut; Count = $count; ExitCode = $nativeExit; RebootRequired = ($nativeExit -in @(1641,3010)) }
            }
            $scopeJobs = foreach ($sc in $scopes) {
                Start-ThreadJob -ScriptBlock $wingetJobSb -ArgumentList $sc, $wingetPath, $hardTimeoutSec
            }

            <# Wait for both jobs; combined ceiling = hard timeout + 60s grace #>
            $combinedTimeoutSec = $hardTimeoutSec + 60
            $null = Wait-BootUpdateJobsWithProgress -Jobs $scopeJobs -TimeoutSeconds $combinedTimeoutSec `
                -Activity 'Updating Winget scopes' -Status 'User and machine upgrades are running'

            foreach ($job in $scopeJobs) {
                $jr = $null
                try { $jr = Receive-Job -Job $job -ErrorAction SilentlyContinue } catch { }
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

                if ($null -eq $jr) {
                    Write-Log 'Winget parallel job returned no result (likely timed out at Wait-Job level)' -Level Warn
                    $anyTimeout = $true
                    continue
                }

                $sc = $jr.Scope
                Write-Log "--- Winget upgrade (--scope $sc) [parallel] ---"
                $installBlocked = $false
                foreach ($line in $jr.Lines) {
                    if ($line -match 'install.+in progress|in progress.+install|0x8A15') { $installBlocked = $true; Write-Log $line -Level Warn }
                    elseif ($line -match 'Successfully installed') { Write-Log $line }
                    else { Write-Log $line }
                }
                if ($jr.TimedOut) {
                    Write-Log "Winget ($sc): Hard timeout ($TimeoutMinutes min). Will retry next boot." -Level Warn
                    $anyTimeout = $true
                }
                if ($jr.RebootRequired) {
                    $rebootEvidence = [pscustomobject]@{ Source="Winget-$sc-exit-$($jr.ExitCode)"; Status='Pending'; Detail="Winget $sc scope requested a reboot (native exit code $($jr.ExitCode))" }
                    $script:ExplicitRebootRequests.Add($rebootEvidence)
                    if ($script:CurrentState) { $script:CurrentState.ExplicitRebootRequests = @($script:ExplicitRebootRequests); Set-BootUpdateState -State $script:CurrentState }
                    Write-Log $rebootEvidence.Detail -Level Warn
                } elseif ($null -ne $jr.ExitCode -and $jr.ExitCode -ne 0) {
                    Write-Log "Winget ($sc) exited with code $($jr.ExitCode); retry required." -Level Error
                    $anyTimeout = $true
                }
                <# Retry if blocked — sequential, after parallel phase completes #>
                if ($installBlocked -and -not $jr.TimedOut) {
                    Write-Log "Winget ($sc) blocked by another install. Waiting 30s, retrying once..." -Level Warn
                    Wait-BootUpdateUiInterval -Seconds 30 -Activity "Updating Winget $sc" `
                        -Status 'Another installer is active; waiting to retry'
                    $retryResult = Invoke-PackageManagerWithTimeout -Name "Winget-$sc-retry" -ScriptBlock {
                        param($wp, $sc2)
                        & $wp upgrade --all --scope $sc2 --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1
                    } -ArgumentList @($wingetPath, $sc) -IdleTimeoutMinutes 5 -HardTimeoutMinutes $TimeoutMinutes
                    $retryCount = 0
                    foreach ($line in $retryResult.Output) { if ($line -match 'Successfully installed') { $retryCount++ }; Write-Log $line }
                    $totalCount += $retryCount
                    if ($retryResult.TimedOut) { $anyTimeout = $true }
                }
                $totalCount += $jr.Count
                Write-Log "--- Winget ($sc): $($jr.Count) package(s) updated ---"
            }
        } else {
            Write-Log '  [WHATIF] Would run: winget upgrade --all --scope user (parallel)'
            Write-Log '  [WHATIF] Would run: winget upgrade --all --scope machine (parallel)'
        }
        return @{ Success = (-not $anyTimeout); Count = $totalCount }
    }

    <# ── Sequential path: single scope (SYSTEM: machine only) OR ExcludePatterns active ── #>
    foreach ($scope in $scopes) {
        Write-Log "--- Winget upgrade (--scope $scope) ---"
        if ($PSCmdlet.ShouldProcess("Winget ($scope)", "Run Winget $scope-scope upgrades")) {

            if ($script:ExcludePatterns.Count -eq 0 -and $script:IncludePatterns.Count -eq 0) {
                <# Fast path: no package filters — use --all for best performance #>
                $result = Invoke-PackageManagerWithTimeout -Name "Winget-$scope" -ScriptBlock {
                    param($wp, $sc)
                    & $wp upgrade --all --scope $sc --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1
                } -ArgumentList @($wingetPath, $scope) -IdleTimeoutMinutes 5 -HardTimeoutMinutes $TimeoutMinutes

                $count = 0; $installBlocked = $false
                foreach ($line in $result.Output) {
                    if ($line -match 'install.+in progress|in progress.+install|0x8A15') { $installBlocked = $true; Write-Log $line -Level Warn }
                    elseif ($line -match 'Successfully installed') { $count++; Write-Log $line }
                    else { Write-Log $line }
                }
                if ($result.TimedOut) { $anyTimeout = $true }

                <# One retry if blocked by another installer #>
                if ($installBlocked -and -not $result.TimedOut) {
                    Write-Log "Winget ($scope) blocked by another install. Waiting 30s, retrying once..." -Level Warn
                    Wait-BootUpdateUiInterval -Seconds 30 -Activity "Updating Winget $scope" `
                        -Status 'Another installer is active; waiting to retry'
                    $retry = Invoke-PackageManagerWithTimeout -Name "Winget-$scope-retry" -ScriptBlock {
                        param($wp, $sc)
                        & $wp upgrade --all --scope $sc --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1
                    } -ArgumentList @($wingetPath, $scope) -IdleTimeoutMinutes 5 -HardTimeoutMinutes $TimeoutMinutes
                    foreach ($line in $retry.Output) { if ($line -match 'Successfully installed') { $count++ }; Write-Log $line }
                    if ($retry.TimedOut) { $anyTimeout = $true }
                }
                $totalCount += $count

            } else {
                <# Filtered path: enumerate upgradeable packages, exclude by pattern, upgrade individually #>
                Write-Log "Winget ($scope): ExcludePatterns active ($($script:ExcludePatterns -join ', ')) — enumerating packages before upgrade"
                $listOutput = @()
                try {
                    $listOutput = @(& $wingetPath list --scope $scope --upgrade-available `
                        --accept-source-agreements --disable-interactivity --no-vt 2>&1 |
                        ForEach-Object { $_.ToString() })
                } catch {
                    Write-Log "Winget ($scope): Failed to enumerate upgradeable packages: $_" -Level Error
                    continue
                }

                <#
                    Parse the winget list table.  Locate the 'Id' column header by character offset,
                    then bound it against the next column header to know the field width.
                    Rows before and including the dashed separator are skipped.
                #>
                $packageIds = @()
                $headerLine = $listOutput | Where-Object { $_ -match '\bId\b' } | Select-Object -First 1
                if (-not $headerLine) {
                    Write-Log "Winget ($scope): Could not parse package list header — falling back to --all (no exclusion)" -Level Warn
                    $fbResult = Invoke-PackageManagerWithTimeout -Name "Winget-$scope" -ScriptBlock {
                        param($wp, $sc)
                        & $wp upgrade --all --scope $sc --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1
                    } -ArgumentList @($wingetPath, $scope) -IdleTimeoutMinutes 5 -HardTimeoutMinutes $TimeoutMinutes
                    $count = 0
                    foreach ($line in $fbResult.Output) { if ($line -match 'Successfully installed') { $count++ }; Write-Log $line }
                    if ($fbResult.TimedOut) { $anyTimeout = $true }
                    $totalCount += $count
                    continue
                }

                $idColStart    = $headerLine.IndexOf('Id')
                $afterIdStr    = $headerLine.Substring($idColStart + 2).TrimStart()
                $nextColName   = ($afterIdStr -split '\s{2,}' | Where-Object { $_ -ne '' } | Select-Object -First 1)
                $nextColOffset = if ($nextColName) { $headerLine.IndexOf($nextColName, $idColStart + 2) } else { -1 }
                $headerIndex   = [array]::IndexOf($listOutput, $headerLine)

                foreach ($row in ($listOutput | Select-Object -Skip ($headerIndex + 1))) {
                    if ($row.Length -le $idColStart) { continue }
                    if ($row -match '^[-\s]+$') { continue }   # dashed separator line
                    $idField = if ($nextColOffset -gt $idColStart) {
                        $row.Substring($idColStart, $nextColOffset - $idColStart).Trim()
                    } else {
                        ($row.Substring($idColStart) -split '\s+')[0].Trim()
                    }
                    if ($idField -and $idField -notmatch '^-+$') { $packageIds += $idField }
                }

                if ($packageIds.Count -eq 0) {
                    Write-Log "Winget ($scope): No upgradeable packages found."
                    continue
                }
                Write-Log "Winget ($scope): $($packageIds.Count) package(s) available for upgrade"

                <# Apply exclusion/allowlist filter #>
                $toUpgrade = @()
                foreach ($pkgId in $packageIds) {
                    $skipReason = Test-PackageExcluded -Name $pkgId
                    if ($skipReason) {
                        Write-Log "Skipped ($skipReason): $pkgId" -Level Info
                    } else {
                        $toUpgrade += $pkgId
                    }
                }
                Write-Log "Winget ($scope): $($toUpgrade.Count) package(s) to upgrade after exclusions"

                $count = 0
                foreach ($pkgId in $toUpgrade) {
                    Write-Log "Winget ($scope): Upgrading $pkgId"
                    $pkgResult = Invoke-PackageManagerWithTimeout -Name "Winget-$scope-$pkgId" -ScriptBlock {
                        param($wp, $id, $sc)
                        & $wp upgrade --id $id --scope $sc -e --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1
                    } -ArgumentList @($wingetPath, $pkgId, $scope) -IdleTimeoutMinutes 5 -HardTimeoutMinutes $TimeoutMinutes
                    foreach ($line in $pkgResult.Output) {
                        if ($line -match 'Successfully installed') { $count++ }
                        Write-Log $line
                    }
                    if ($pkgResult.TimedOut) { $anyTimeout = $true }
                }
                $totalCount += $count
            }

        } else {
            if ($script:ExcludePatterns.Count -eq 0 -and $script:IncludePatterns.Count -eq 0) {
                Write-Log "  [WHATIF] Would run: winget upgrade --all --scope $scope"
            } else {
                Write-Log "  [WHATIF] Would run: winget list --upgrade-available --scope $scope, then upgrade each non-excluded package individually"
                Write-Log "  [WHATIF] ExcludePatterns: $($script:ExcludePatterns -join ', ')"
            }
        }
        Write-Log "--- Winget ($scope): $totalCount package(s) updated so far ---"
    }
    return @{ Success = (-not $anyTimeout); Count = $totalCount }
}

function Update-ChocolateyPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $choco = Get-Command choco -EA SilentlyContinue
    if (-not $choco) { Write-Log 'Chocolatey not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    $chocoPath = $choco.Source
    Write-Log 'Updating Chocolatey packages...'
    $count = 0; $failed = $false
    if ($PSCmdlet.ShouldProcess('Chocolatey', 'Run choco upgrade all')) {
        if ($script:ExcludePatterns.Count -eq 0 -and $script:IncludePatterns.Count -eq 0) {
            <# Fast path: no package filters #>
            $result = Invoke-BootUpdateBackgroundOperation -Name 'Updating Chocolatey packages' `
                -Status 'choco upgrade all is running' -TimeoutMinutes $script:PackageTimeoutMinutes `
                -ScriptBlock { param($Path) & $Path upgrade all -y --no-progress 2>&1 } `
                -ArgumentList @($chocoPath)
            $result.Output | ForEach-Object {
                if ($_ -match 'upgraded (\d+)/\d+ package') { $count = [int]$Matches[1] }
                Write-Log $_
            }
            if ($result.Failed -or $result.TimedOut) { $failed = $true; Write-Log 'Chocolatey upgrade failed or timed out; retry required.' -Level Error }
        } else {
            <# Filtered path: enumerate outdated packages, exclude by pattern, upgrade individually #>
            Write-Log "Chocolatey: ExcludePatterns active ($($script:ExcludePatterns -join ', ')) — enumerating outdated packages"
            $outdatedLines = @()
            try {
                $listResult = Invoke-BootUpdateBackgroundOperation -Name 'Checking Chocolatey packages' `
                    -Status 'choco outdated is running' -TimeoutMinutes $script:PackageTimeoutMinutes `
                    -ScriptBlock { param($Path) & $Path outdated --limit-output 2>&1 } `
                    -ArgumentList @($chocoPath)
                $outdatedLines = @($listResult.Output | ForEach-Object { $_.ToString() })
                if ($listResult.Failed -or $listResult.TimedOut) {
                    Write-Log 'Chocolatey package enumeration failed or timed out.' -Level Error
                    return @{ Success = $false; Count = 0 }
                }
            } catch {
                Write-Log "Chocolatey: Failed to enumerate outdated packages: $_" -Level Error
                return @{ Success = $false; Count = 0 }
            }

            <#
                choco outdated --limit-output emits pipe-delimited lines: packageName|currentVersion|newVersion|pinned
                Skip any line that does not contain a pipe character (warnings, headers, etc.)
            #>
            $toUpgrade = @()
            foreach ($line in $outdatedLines) {
                if ($line -notmatch '\|') { continue }
                $pkgName = ($line -split '\|')[0].Trim()
                if (-not $pkgName) { continue }
                $skipReason = Test-PackageExcluded -Name $pkgName
                if ($skipReason) {
                    Write-Log "Skipped ($skipReason): $pkgName" -Level Info
                } else {
                    $toUpgrade += $pkgName
                }
            }
            Write-Log "Chocolatey: $($toUpgrade.Count) package(s) to upgrade after exclusions"

            foreach ($pkgName in $toUpgrade) {
                Write-Log "Chocolatey: Upgrading $pkgName"
                $result = Invoke-BootUpdateBackgroundOperation -Name "Updating Chocolatey $pkgName" `
                    -Status "$pkgName upgrade is running" -TimeoutMinutes $script:PackageTimeoutMinutes `
                    -ScriptBlock { param($Path, $Package) & $Path upgrade $Package -y --no-progress 2>&1 } `
                    -ArgumentList @($chocoPath, $pkgName)
                $result.Output | ForEach-Object {
                    if ($_ -match 'upgraded (\d+)/\d+ package|Software installed') { $count++ }
                    Write-Log $_
                }
                if ($result.Failed -or $result.TimedOut) { $failed = $true; Write-Log "Chocolatey $pkgName failed or timed out; retry required." -Level Error }
            }
        }
    } else {
        if ($script:ExcludePatterns.Count -eq 0 -and $script:IncludePatterns.Count -eq 0) {
            Write-Log '  [WHATIF] Would run: choco upgrade all -y --no-progress'
        } else {
            Write-Log '  [WHATIF] Would run: choco outdated --limit-output, then upgrade each non-excluded package individually'
            Write-Log "  [WHATIF] ExcludePatterns: $($script:ExcludePatterns -join ', ')"
        }
    }
    return @{ Success = (-not $failed); Count = $count }
}

function Repair-WindowsUpdateComponents {
    <#
    .SYNOPSIS
        Standard Windows Update component reset: stop WU services, rename
        SoftwareDistribution and catroot2, restart services.
    .NOTES
        Escalation remedy — invoked only after repeated consecutive WU phase
        failures (see Install-WindowsUpdates). DISM /RestoreHealth is deliberately
        NOT run automatically (can take 30+ min); the log says so if failures persist.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Log 'WU remediation: resetting Windows Update components (SoftwareDistribution / catroot2)...' -Level Warn
    if (-not $PSCmdlet.ShouldProcess('Windows Update components', 'Stop services, rename SoftwareDistribution/catroot2, restart')) { return }
    $svcs = @('wuauserv', 'cryptsvc', 'bits', 'msiserver')
    foreach ($s in $svcs) { try { Stop-Service $s -Force -ErrorAction SilentlyContinue } catch { } }
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    foreach ($dir in @("$env:windir\SoftwareDistribution", "$env:windir\System32\catroot2")) {
        if (Test-Path $dir) {
            try { Rename-Item $dir "$dir.$stamp.bak" -ErrorAction Stop; Write-Log "  renamed: $dir -> $dir.$stamp.bak" }
            catch { Write-Log "  could not rename ${dir}: $_" -Level Warn }
        }
    }
    foreach ($s in $svcs) { try { Start-Service $s -ErrorAction SilentlyContinue } catch { } }
    Write-Log 'WU remediation: component reset complete. If failures persist, run DISM /Online /Cleanup-Image /RestoreHealth manually.'
}

function Initialize-BootUpdateWindowsUpdateModule {
    if (Get-Module -ListAvailable PSWindowsUpdate) { return $true }
    if ($WhatIfPreference) {
        Write-Log '  [WHATIF] Would install PSWindowsUpdate for all users.'
        return $true
    }
    Write-Log 'Installing PSWindowsUpdate module...'
    $result = Invoke-BootUpdateBackgroundOperation -Name 'Installing PSWindowsUpdate' `
        -Status 'Downloading and installing the Windows Update module' `
        -TimeoutMinutes $script:PackageTimeoutMinutes -ScriptBlock {
            Install-Module PSWindowsUpdate -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        }
    if ($result.Failed -or $result.TimedOut) {
        Write-Log 'PSWindowsUpdate installation failed or timed out.' -Level Error
        return $false
    }
    return [bool](Get-Module -ListAvailable PSWindowsUpdate)
}

function Install-WindowsUpdates {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Initialize-BootUpdateWindowsUpdateModule)) {
        return @{ Success = $false; Count = 0 }
    }

    <# Consecutive-failure streak persists across reboots in a sidecar file (no state
       schema change). At 2+ consecutive failures, run the component reset once per
       streak; a successful pass clears both the streak and the remediated marker. #>
    $streakPath = Join-Path (Split-Path $script:StatePath) 'BootUpdateCycle.wu-failstreak.txt'
    $remediatedMarker = "$streakPath.remediated"
    $streak = 0
    if (Test-Path $streakPath) { try { $streak = [int](Get-Content $streakPath -ErrorAction Stop) } catch { $streak = 0 } }
    if ($streak -ge 2 -and -not (Test-Path $remediatedMarker)) {
        Write-Log "Windows Update has failed $streak consecutive time(s) — escalating to component reset." -Level Warn
        Repair-WindowsUpdateComponents
        if (-not $WhatIfPreference) { New-Item -ItemType File -Path $remediatedMarker -Force | Out-Null }
    }

    <# Collect the background prefetch job (2uj) before installing, if one is running #>
    if ($script:WuPrefetchJob) {
        Write-Log 'Waiting for background Windows Update download to finish...'
        $done = Wait-BootUpdateJobsWithProgress -Jobs @($script:WuPrefetchJob) `
            -TimeoutSeconds ($script:PackageTimeoutMinutes * 60) `
            -Activity 'Windows Update prefetch' -Status 'Finishing background downloads'
        if ($done) {
            $dlLines = @(Receive-Job $script:WuPrefetchJob -ErrorAction SilentlyContinue)
            $dlCount = @($dlLines | Where-Object { $_ -match 'Downloaded' }).Count
            Write-Log "Windows Update prefetch: complete ($dlCount downloaded while other phases ran)."
        } else {
            Write-Log 'Windows Update prefetch still running at install time — stopping it and proceeding.' -Level Warn
            Stop-Job $script:WuPrefetchJob -ErrorAction SilentlyContinue
        }
        Remove-Job $script:WuPrefetchJob -Force -ErrorAction SilentlyContinue
        $script:WuPrefetchJob = $null
    }

    Write-Log 'Checking for Windows Updates (excluding SQL Server)...'
    $params = @{
        AcceptAll = $true; Install = $true; NotTitle = ((@('SQL') + ($script:ExcludePatterns | ForEach-Object { [regex]::Escape($_) })) -join '|')
        RootCategories = @('Security Updates','Critical Updates','Definition Updates')
        AutoReboot = $false; Confirm = $false; IgnoreReboot = $true
    }
    $count = 0; $failed = $false
    if ($PSCmdlet.ShouldProcess('Windows Update', 'Install available updates')) {
        try {
            $result = Invoke-BootUpdateBackgroundOperation -Name 'Installing Windows Updates' `
                -Status 'Windows Update scan and installation are running' `
                -TimeoutMinutes $script:PackageTimeoutMinutes -ScriptBlock {
                    param($UpdateParams)
                    try {
                        Import-Module PSWindowsUpdate -Force
                        $updateHashtable = @{}
                        foreach ($property in $UpdateParams.PSObject.Properties) {
                            $updateHashtable[$property.Name] = $property.Value
                        }
                        Get-WindowsUpdate @updateHashtable -Verbose 4>&1 | ForEach-Object { $_.ToString() }
                    } catch {
                        "BOOTUPDATE_ERROR|$($_.Exception.Message)"
                    }
                } -ArgumentList (,$params)
            foreach ($item in $result.Output) {
                $line = $item.ToString()
                if ($line -eq 'System.__ComObject') { continue }
                if ($line -match '^BOOTUPDATE_ERROR\|(.+)$') {
                    $failed = $true
                    Write-Log "Windows Update error: $($Matches[1])" -Level Error
                    continue
                }
                if ($line -match 'Installed|Downloaded') { $count++ }
                Write-Log $line
            }
            if ($result.Failed -or $result.TimedOut) {
                $failed = $true
                Write-Log 'Windows Update operation failed or timed out.' -Level Error
            }
        } catch { $failed = $true; Write-Log "Windows Update error: $_" -Level Error }

        <# Update the failure streak (skipped in WhatIf — no real attempt was made) #>
        try {
            if ($failed) {
                Set-Content -Path $streakPath -Value ([string]($streak + 1)) -Force
                Write-Log "Windows Update failure streak: $($streak + 1)." -Level Warn
            } else {
                Remove-Item $streakPath, $remediatedMarker -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    } else {
        Write-Log '  [WHATIF] Would run: Get-WindowsUpdate (install all, exclude SQL)'
    }
    return @{ Success = (-not $failed); Count = $count }
}

function Test-WindowsUpdateConvergence {
    <# A successful install call is not convergence: dependency updates can become
       applicable immediately without setting a reboot flag. Require a fresh,
       read-only scan of the same configured category scope to return zero. #>
    if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
        return [pscustomobject]@{ Verified=$false; Count=-1; Detail='PSWindowsUpdate is unavailable for the final scan' }
    }
    $notTitle = ((@('SQL') + ($script:ExcludePatterns | ForEach-Object { [regex]::Escape($_) })) -join '|')
    $result = Invoke-BootUpdateBackgroundOperation -Name 'Verifying Windows Update convergence' `
        -Status 'Final read-only Windows Update scan is running' -TimeoutMinutes $script:PackageTimeoutMinutes `
        -ScriptBlock {
            param($ExcludedTitle)
            try {
                Import-Module PSWindowsUpdate -Force
                @(Get-WindowsUpdate -NotTitle $ExcludedTitle `
                    -RootCategories @('Security Updates','Critical Updates','Definition Updates') `
                    -IgnoreReboot -Confirm:$false -ErrorAction Stop) | ForEach-Object {
                        "BOOTUPDATE_APPLICABLE|$($_.KB)|$($_.Title)"
                    }
            } catch { "BOOTUPDATE_ERROR|$($_.Exception.Message)" }
        } -ArgumentList @($notTitle)
    $updates = @($result.Output | Where-Object { $_ -match '^BOOTUPDATE_APPLICABLE\|' })
    $errors = @($result.Output | Where-Object { $_ -match '^BOOTUPDATE_ERROR\|' })
    foreach ($line in $updates) { Write-Log "Final WU scan: $($line -replace '^BOOTUPDATE_APPLICABLE\|','')" -Level Warn }
    foreach ($line in $errors) { Write-Log "Final WU scan error: $($line -replace '^BOOTUPDATE_ERROR\|','')" -Level Error }
    $verified = -not $result.Failed -and -not $result.TimedOut -and $errors.Count -eq 0
    return [pscustomobject]@{ Verified=$verified; Count=$updates.Count; Detail=$(if($verified){"$($updates.Count) applicable update(s)"}else{'scan failed'}) }
}

function Install-DriverFirmwareUpdates {
    <#
    .SYNOPSIS
        Installs driver and/or firmware updates via PSWindowsUpdate.
    .NOTES
        Only runs if -IncludeDriverUpdates or -IncludeFirmwareUpdates is specified.
        Mirrors the PSWindowsUpdate load pattern used by Install-WindowsUpdates.
        Returns @{ Success=[bool]; Count=[int] }; enabled provider failures remain retryable.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $script:IncludeDriverUpdates -and -not $script:IncludeFirmwareUpdates) {
        Write-Log 'Driver/Firmware updates: skipped (neither -IncludeDriverUpdates nor -IncludeFirmwareUpdates specified).'
        return @{ Success = $true; Count = 0 }
    }
    if (-not (Initialize-BootUpdateWindowsUpdateModule)) {
        return @{ Success = $false; Count = 0 }
    }
    $count = 0; $failed = $false
    $excludeTitle = ((@('SQL') + ($script:ExcludePatterns | ForEach-Object { [regex]::Escape($_) })) -join '|')

    if ($script:IncludeDriverUpdates) {
        Write-Log 'Checking for Driver updates via PSWindowsUpdate...'
        if ($PSCmdlet.ShouldProcess('Windows Update - Drivers', 'Install driver updates')) {
            try {
                $result = Invoke-BootUpdateBackgroundOperation -Name 'Installing driver updates' `
                    -Status 'Windows driver updates are running' -TimeoutMinutes $script:PackageTimeoutMinutes `
                    -ScriptBlock {
                        param($NotTitle)
                        Import-Module PSWindowsUpdate -Force
                        Get-WindowsUpdate -Category 'Drivers' -AcceptAll -Install -IgnoreReboot `
                            -NotTitle $NotTitle -AutoReboot:$false -Confirm:$false -Verbose 4>&1 |
                            ForEach-Object { $_.ToString() }
                    } -ArgumentList @($excludeTitle)
                $result.Output | ForEach-Object {
                    $line = $_.ToString()
                    if ($line -eq 'System.__ComObject') { return }
                    if ($line -match 'Installed|Downloaded') { $count++ }
                    Write-Log $line
                }
                if ($result.Failed -or $result.TimedOut) { $failed = $true; Write-Log 'Driver updates failed or timed out.' -Level Error }
            } catch { $failed = $true; Write-Log "Driver updates error: $_" -Level Error }
        } else {
            Write-Log '  [WHATIF] Would run: Get-WindowsUpdate -Category Drivers -AcceptAll -Install -IgnoreReboot'
        }
    }

    if ($script:IncludeFirmwareUpdates) {
        Write-Log 'Checking for Firmware updates via PSWindowsUpdate...'
        if ($PSCmdlet.ShouldProcess('Windows Update - Firmware', 'Install firmware updates')) {
            try {
                $result = Invoke-BootUpdateBackgroundOperation -Name 'Installing firmware updates' `
                    -Status 'Windows firmware updates are running' -TimeoutMinutes $script:PackageTimeoutMinutes `
                    -ScriptBlock {
                        param($NotTitle)
                        Import-Module PSWindowsUpdate -Force
                        Get-WindowsUpdate -Category 'Firmware' -AcceptAll -Install -IgnoreReboot `
                            -NotTitle $NotTitle -AutoReboot:$false -Confirm:$false -Verbose 4>&1 |
                            ForEach-Object { $_.ToString() }
                    } -ArgumentList @($excludeTitle)
                $result.Output | ForEach-Object {
                    $line = $_.ToString()
                    if ($line -eq 'System.__ComObject') { return }
                    if ($line -match 'Installed|Downloaded') { $count++ }
                    Write-Log $line
                }
                if ($result.Failed -or $result.TimedOut) { $failed = $true; Write-Log 'Firmware updates failed or timed out.' -Level Error }
            } catch { $failed = $true; Write-Log "Firmware updates error: $_" -Level Error }
        } else {
            Write-Log '  [WHATIF] Would run: Get-WindowsUpdate -Category Firmware -AcceptAll -Install -IgnoreReboot'
        }
    }

    Write-Log "Driver/Firmware updates: $count installed."
    return @{ Success = (-not $failed); Count = $count }
}

function Update-DefenderSignatures {
    <#
    .SYNOPSIS
        Refreshes Windows Defender antivirus signatures from Microsoft Update Server.
    .NOTES
        Non-Windows or missing MpComputerStatus: skipped gracefully.
        A requested signature refresh failure remains pending for an automatic retry.
        Signatures do not trigger a reboot; Count=1 signals the phase ran.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($script:SkipDefender) {
        Write-Log 'Defender signature update: skipped (-SkipDefender).'
        return @{ Success = $true; Count = 0 }
    }
    if (-not $IsWindows) {
        Write-Log 'Defender signature update: skipped (not Windows).'
        return @{ Success = $true; Count = 0 }
    }
    $mpCmdRun = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (-not (Test-Path $mpCmdRun)) {
        Write-Log 'Defender signature update: skipped (MpCmdRun.exe not found — Defender may be disabled or absent).' -Level Warn
        return @{ Success = $true; Count = 0 }
    }
    Write-Log 'Updating Windows Defender signatures...'
    if ($PSCmdlet.ShouldProcess('Windows Defender', 'MpCmdRun.exe -SignatureUpdate -MMPC')) {
        try {
            $result = Invoke-BootUpdateBackgroundOperation -Name 'Updating Defender signatures' `
                -Status 'Microsoft Defender signature update is running' `
                -TimeoutMinutes $script:PackageTimeoutMinutes -ScriptBlock {
                    param($Path)
                    & $Path -SignatureUpdate -MMPC 2>&1
                    "BOOTUPDATE_EXIT|$LASTEXITCODE"
                } -ArgumentList @($mpCmdRun)
            $exitCode = -1
            foreach ($line in $result.Output) {
                if ($line -match '^BOOTUPDATE_EXIT\|(-?\d+)$') { $exitCode = [int]$Matches[1]; continue }
                Write-Log $line.ToString()
            }
            if ($result.Failed -or $result.TimedOut -or $exitCode -ne 0) {
                throw "Defender signature process failed, timed out, or exited with code $exitCode."
            }
            Write-Log 'Defender signatures updated.'
            return @{ Success = $true; Count = 1 }
        } catch {
            Write-Log "Defender signature update failed: $_" -Level Error
            return @{ Success = $false; Count = 0 }
        }
    } else {
        Write-Log '  [WHATIF] Would run: MpCmdRun.exe -SignatureUpdate -MMPC'
        return @{ Success = $true; Count = 0 }
    }
}

function Update-WslKernelAndDistros {
    <#
    .SYNOPSIS
        Updates the WSL kernel and runs package manager upgrades inside each distro.
    .NOTES
        Skipped under SYSTEM context (WSL is user-scoped).
        Skipped if wsl.exe is not found.
        Returns @{ Success=[bool]; Count=[int] } — Count = number of distros updated.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) {
        Write-Log 'WSL update: skipped (SYSTEM context — WSL is user-scoped).' -Level Warn
        return @{ Success = $true; Count = 0 }
    }
    if (-not $script:UpdateWsl) {
        Write-Log 'WSL update: skipped (use -UpdateWsl to enable).'
        return @{ Success = $true; Count = 0 }
    }
    $wslCommand = Get-Command wsl -EA SilentlyContinue
    if (-not $wslCommand) {
        Write-Log 'WSL update: wsl.exe not found — WSL not installed, skipping.'
        return @{ Success = $true; Count = 0 }
    }

    $failed = $false
    Write-Log 'Updating WSL kernel...'
    if ($PSCmdlet.ShouldProcess('WSL', 'wsl --update --no-distribution')) {
        try {
            $kernelResult = Invoke-BootUpdateBackgroundOperation -Name 'Updating WSL kernel' `
                -Status 'wsl --update is running' -TimeoutMinutes $script:PackageTimeoutMinutes `
                -ScriptBlock {
                    param($Path)
                    & $Path --update --no-distribution 2>&1
                    "BOOTUPDATE_EXIT|$LASTEXITCODE"
                } -ArgumentList @($wslCommand.Source)
            $kernelExit = -1
            foreach ($line in $kernelResult.Output) {
                if ($line -match '^BOOTUPDATE_EXIT\|(-?\d+)$') { $kernelExit = [int]$Matches[1]; continue }
                Write-Log $line.ToString()
            }
            if ($kernelResult.Failed -or $kernelResult.TimedOut -or $kernelExit -ne 0) {
                $failed = $true
                Write-Log "WSL kernel update failed, timed out, or exited with code $kernelExit." -Level Error
            } else {
                Write-Log 'WSL kernel update completed.'
            }
        } catch {
            $failed = $true
            Write-Log "WSL kernel update error: $_" -Level Error
        }
    } else {
        Write-Log '  [WHATIF] Would run: wsl --update --no-distribution'
    }

    <# Enumerate distros #>
    $distros = @()
    try {
        $listResult = Invoke-BootUpdateBackgroundOperation -Name 'Enumerating WSL distributions' `
            -Status 'wsl --list is running' -TimeoutMinutes 5 `
            -ScriptBlock { param($Path) & $Path --list --quiet 2>&1; "BOOTUPDATE_EXIT|$LASTEXITCODE" } `
            -ArgumentList @($wslCommand.Source)
        $listExit = -1
        $distros = @($listResult.Output | ForEach-Object {
            $line = $_.ToString().Trim()
            if ($line -match '^BOOTUPDATE_EXIT\|(-?\d+)$') { $listExit = [int]$Matches[1]; return }
            $line
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($listResult.Failed -or $listResult.TimedOut -or $listExit -ne 0) {
            Write-Log "WSL distro enumeration failed or timed out (exit $listExit)." -Level Error
            return @{ Success = $false; Count = 0 }
        }
    } catch {
        Write-Log "WSL distro enumeration failed: $_" -Level Error
        return @{ Success = $false; Count = 0 }
    }

    if ($distros.Count -eq 0) {
        Write-Log 'WSL: no distros found.'
        return @{ Success = $true; Count = 0 }
    }
    Write-Log "WSL: found $($distros.Count) distro(s): $($distros -join ', ')"

    $updatedCount = 0
    foreach ($distro in $distros) {
        Write-Log "WSL: updating distro [$distro]..."
        if (-not $PSCmdlet.ShouldProcess("WSL distro: $distro", 'Run package manager upgrade')) {
            Write-Log "  [WHATIF] Would run package upgrades in distro: $distro"
            continue
        }
        try {
            $distroResult = Invoke-BootUpdateBackgroundOperation -Name "Updating WSL $distro" `
                -Status "Linux package updates are running in $distro" `
                -TimeoutMinutes $script:PackageTimeoutMinutes -ScriptBlock {
                    param($Path, $Distro)
                    & $Path -d $Distro -u root -- which apt-get *> $null
                    if ($LASTEXITCODE -eq 0) {
                        'BOOTUPDATE_PM|apt-get'
                        & $Path -d $Distro -u root -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y' 2>&1
                        "BOOTUPDATE_EXIT|$LASTEXITCODE"
                        return
                    }
                    & $Path -d $Distro -u root -- which dnf *> $null
                    if ($LASTEXITCODE -eq 0) {
                        'BOOTUPDATE_PM|dnf'
                        & $Path -d $Distro -u root -- dnf upgrade -y 2>&1
                        "BOOTUPDATE_EXIT|$LASTEXITCODE"
                        return
                    }
                    & $Path -d $Distro -u root -- which pacman *> $null
                    if ($LASTEXITCODE -eq 0) {
                        'BOOTUPDATE_PM|pacman'
                        & $Path -d $Distro -u root -- pacman -Syu --noconfirm 2>&1
                        "BOOTUPDATE_EXIT|$LASTEXITCODE"
                        return
                    }
                    'BOOTUPDATE_PM|none'
                } -ArgumentList @($wslCommand.Source, $distro)
            $manager = 'none'; $exitCode = -1
            foreach ($line in $distroResult.Output) {
                if ($line -match '^BOOTUPDATE_PM\|(.+)$') { $manager = $Matches[1]; continue }
                if ($line -match '^BOOTUPDATE_EXIT\|(-?\d+)$') { $exitCode = [int]$Matches[1]; continue }
                Write-Log "  [$distro] $($line.ToString())"
            }
            if ($manager -eq 'none') {
                Write-Log "  [$distro] No recognized package manager (apt-get/dnf/pacman) found — skipping." -Level Warn
            } elseif (-not $distroResult.Failed -and -not $distroResult.TimedOut -and $exitCode -eq 0) {
                Write-Log "  [$distro] $manager update completed."
                $updatedCount++
            } else {
                $failed = $true
                Write-Log "  [$distro] $manager update failed or timed out." -Level Error
            }
        } catch {
            $failed = $true
            Write-Log "  [$distro] Update error: $_" -Level Error
        }
    }

    Write-Log "WSL: $updatedCount distro(s) updated."
    return @{ Success = (-not $failed); Count = $updatedCount }
}

function Update-ContainerImages {
    <#
    .SYNOPSIS
        Pulls updated images for all running/known Docker or Podman images, then prunes dangling layers.
    .NOTES
        Skipped under SYSTEM context (Docker/Podman are user-scoped in common setups).
        Detects docker first, then podman — uses the first one found.
        Returns @{ Success=[bool]; Count=[int] } — Count = successful pulls.
        Never throws.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) {
        Write-Log 'Container image update: skipped (SYSTEM context).' -Level Warn
        return @{ Success = $true; Count = 0 }
    }
    if (-not $script:UpdateContainers) {
        Write-Log 'Container image update: skipped (use -UpdateContainers to enable).'
        return @{ Success = $true; Count = 0 }
    }

    <# Detect runtime: docker first, then podman #>
    $runtime = $null
    $dockerCmd = Get-Command docker -EA SilentlyContinue
    if ($dockerCmd) { $runtime = 'docker'; $runtimePath = $dockerCmd.Source }
    else {
        $podmanCmd = Get-Command podman -EA SilentlyContinue
        if ($podmanCmd) { $runtime = 'podman'; $runtimePath = $podmanCmd.Source }
    }
    if (-not $runtime) {
        Write-Log 'Container image update: neither docker nor podman found — skipping.'
        return @{ Success = $true; Count = 0 }
    }
    Write-Log "Container image update: using [$runtime]"

    $successfulPulls = 0; $failed = $false
    try {
        <# Enumerate unique non-<none> images #>
        $imageList = @()
        try {
            $listResult = Invoke-BootUpdateBackgroundOperation -Name "Enumerating $runtime images" `
                -Status "$runtime image inventory is running" -TimeoutMinutes 5 `
                -ScriptBlock { param($Path) & $Path images --format '{{.Repository}}:{{.Tag}}' 2>&1; "BOOTUPDATE_EXIT|$LASTEXITCODE" } `
                -ArgumentList @($runtimePath)
            $listExit = -1
            $imageList = @($listResult.Output |
                ForEach-Object { $line = $_.ToString().Trim(); if ($line -match '^BOOTUPDATE_EXIT\|(-?\d+)$') { $listExit = [int]$Matches[1]; return }; $line } |
                Where-Object { $_ -notmatch '<none>' -and -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique)
            if ($listResult.Failed -or $listResult.TimedOut -or $listExit -ne 0) {
                Write-Log "Container image enumeration failed or timed out (exit $listExit)." -Level Error
                return @{ Success = $false; Count = 0 }
            }
        } catch {
            Write-Log "Container image enumeration failed: $_" -Level Error
            return @{ Success = $false; Count = 0 }
        }

        if ($imageList.Count -eq 0) {
            Write-Log "Container image update: no images found."
            return @{ Success = $true; Count = 0 }
        }
        Write-Log "Container image update: $($imageList.Count) image(s) to refresh"

        foreach ($image in $imageList) {
            if (-not $PSCmdlet.ShouldProcess($image, "$runtime pull")) {
                Write-Log "  [WHATIF] Would run: $runtime pull $image"
                continue
            }
            Write-Log "  Pulling: $image"
            try {
                $pullResult = Invoke-BootUpdateBackgroundOperation -Name "Pulling $image" `
                    -Status "$runtime pull is running" -TimeoutMinutes $script:PackageTimeoutMinutes `
                    -ScriptBlock {
                        param($Path, $Image)
                        & $Path pull $Image 2>&1
                        "BOOTUPDATE_EXIT|$LASTEXITCODE"
                    } -ArgumentList @($runtimePath, $image)
                $pullExit = -1
                foreach ($line in $pullResult.Output) {
                    if ($line -match '^BOOTUPDATE_EXIT\|(-?\d+)$') { $pullExit = [int]$Matches[1]; continue }
                    Write-Log "    $($line.ToString())"
                }
                if (-not $pullResult.Failed -and -not $pullResult.TimedOut -and $pullExit -eq 0) {
                    $successfulPulls++
                } else {
                    $failed = $true
                    Write-Log "  Pull failed or timed out for $image (exit $pullExit)." -Level Error
                }
            } catch {
                $failed = $true
                Write-Log "  Pull error for ${image}: $_" -Level Error
            }
        }

        <# Prune dangling layers — best-effort, ignore exit code #>
        if ($PSCmdlet.ShouldProcess('container system', "$runtime system prune -f")) {
            Write-Log "Container prune: $runtime system prune -f"
            try {
                $pruneResult = Invoke-BootUpdateBackgroundOperation -Name "Pruning $runtime images" `
                    -Status "$runtime system prune is running" -TimeoutMinutes 15 `
                    -ScriptBlock { param($Path) & $Path system prune -f 2>&1 } `
                    -ArgumentList @($runtimePath)
                $pruneResult.Output | ForEach-Object { Write-Log "  $($_.ToString())" }
            } catch { }
        } else {
            Write-Log "  [WHATIF] Would run: $runtime system prune -f"
        }
    } catch {
        $failed = $true
        Write-Log "Container image update: unexpected error: $_" -Level Error
    }

    Write-Log "Container image update: $successfulPulls image(s) successfully refreshed."
    return @{ Success = (-not $failed); Count = $successfulPulls }
}

function Update-PipPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $pip = Get-Command pip -EA SilentlyContinue
    if (-not $pip) { Write-Log 'pip not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    $python = Get-Command python -EA SilentlyContinue
    if (-not $python) { Write-Log 'python not found, skipping pip updates.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating pip packages...'
    $count = 0; $failed = $false
    if ($PSCmdlet.ShouldProcess('pip', 'Upgrade pip and outdated packages')) {
        $pipSelf = Invoke-BootUpdateBackgroundOperation -Name 'Updating pip' -Status 'pip self-update is running' `
            -TimeoutMinutes $script:PackageTimeoutMinutes `
            -ScriptBlock { param($Python) & $Python -m pip install --upgrade pip 2>&1 } `
            -ArgumentList @($python.Source)
        $pipSelf.Output | ForEach-Object { Write-Log $_ }
        if ($pipSelf.Failed -or $pipSelf.TimedOut) { $failed = $true; Write-Log 'pip self-update failed or timed out; retry required.' -Level Error }
        $listResult = Invoke-BootUpdateBackgroundOperation -Name 'Checking pip packages' `
            -Status 'pip package inventory is running' -TimeoutMinutes 5 `
            -ScriptBlock { param($Pip) & $Pip list --outdated --format=json 2>$null } `
            -ArgumentList @($pip.Source)
        if ($listResult.Failed -or $listResult.TimedOut) {
            Write-Log 'pip package inventory failed or timed out.' -Level Error
            return @{ Success = $false; Count = 0 }
        }
        $outdated = @(($listResult.Output -join "`n") | ConvertFrom-Json -EA SilentlyContinue)
        foreach ($pkg in $outdated) {
            $skipReason = Test-PackageExcluded -Name $pkg.name
            if ($skipReason) {
                Write-Log "Pip: skipping $($pkg.name) ($skipReason)"
                continue
            }
            Write-Log "Upgrading: $($pkg.name)"
            $result = Invoke-BootUpdateBackgroundOperation -Name "Updating pip $($pkg.name)" `
                -Status "$($pkg.name) upgrade is running" -TimeoutMinutes $script:PackageTimeoutMinutes `
                -ScriptBlock { param($Pip, $Package) & $Pip install --upgrade $Package 2>&1 } `
                -ArgumentList @($pip.Source, $pkg.name)
            $result.Output | ForEach-Object { Write-Log $_ }
            if ($result.Failed -or $result.TimedOut) {
                $failed = $true
                Write-Log "pip update failed or timed out for $($pkg.name)." -Level Error
            } else { $count++ }
        }
    } else {
        Write-Log '  [WHATIF] Would run: pip install --upgrade <outdated packages>'
    }
    return @{ Success = (-not $failed); Count = $count }
}

function Update-NpmPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $npm = Get-Command npm -EA SilentlyContinue
    if (-not $npm) { Write-Log 'npm not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating npm global packages...'
    $count = 0
    if ($PSCmdlet.ShouldProcess('npm', 'Run npm update -g')) {
        $result = Invoke-BootUpdateBackgroundOperation -Name 'Updating npm packages' `
            -Status 'npm update -g is running' -TimeoutMinutes $script:PackageTimeoutMinutes `
            -ScriptBlock { param($Path) & $Path update -g 2>&1 } -ArgumentList @($npm.Source)
        $result.Output | ForEach-Object { if ($_ -match 'added|updated') { $count++ }; Write-Log $_ }
        if ($result.Failed -or $result.TimedOut) { Write-Log 'npm update failed or timed out.' -Level Error; return @{ Success = $false; Count = $count } }
    } else {
        Write-Log '  [WHATIF] Would run: npm update -g'
    }
    return @{ Success = $true; Count = $count }
}

function Update-Office365 {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $c2rClient = "${env:ProgramFiles}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    if (-not (Test-Path $c2rClient)) { Write-Log 'Office 365 C2R not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating Office 365 (Click-to-Run)...'
    if ($PSCmdlet.ShouldProcess('Office 365', 'Trigger OfficeC2RClient update')) {
        try {
            $result = Invoke-BootUpdateBackgroundOperation -Name 'Updating Office 365' `
                -Status 'Office Click-to-Run update is starting' -TimeoutMinutes $script:PackageTimeoutMinutes `
                -ScriptBlock {
                    param($Path)
                    & $Path /update user updatepromptuser=false forceappshutdown=true displaylevel=false 2>&1
                } -ArgumentList @($c2rClient)
            $result.Output | ForEach-Object { Write-Log $_ }
            if ($result.Failed -or $result.TimedOut) {
                Write-Log 'Office 365 update failed or timed out.' -Level Error
                return @{ Success = $false; Count = 0 }
            }
            Write-Log 'Office 365 update triggered (may complete in background)'
            return @{ Success = $true; Count = 1 }
        } catch { Write-Log "Office 365 error: $_" -Level Error; return @{ Success = $false; Count = 0 } }
    } else {
        Write-Log '  [WHATIF] Would run: OfficeC2RClient.exe /update user'
        return @{ Success = $true; Count = 0 }
    }
}

function Update-PowerShellModules {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Log 'Checking installed PowerShell modules...'
    $count = 0; $failed = $false
    $usePSResourceGet = [bool](Get-Command Update-PSResource -EA SilentlyContinue)

    if ($usePSResourceGet) {
        <# ── PSResourceGet path: single bulk call in child process (avoids file-lock issues) ── #>
        Write-Log 'Using PSResourceGet (Update-PSResource) for bulk module update...'
        $installed = Get-InstalledPSResource -Scope AllUsers -EA SilentlyContinue
        if (-not $installed) { $installed = Get-InstalledPSResource -EA SilentlyContinue }
        $moduleNames = @($installed | Where-Object {
            $_.Name -notlike 'Microsoft.PowerShell.*' -and
            $_.Name -notlike 'AWS.Tools.*' -and
            $_.Name -ne 'Az' -and
            $_.Type -eq 'Module'
        } | Select-Object -ExpandProperty Name -Unique)
        if (-not $moduleNames) { Write-Log 'No updatable modules found.'; return @{ Success = $true; Count = 0 } }
        Write-Log "Found $($moduleNames.Count) module(s) to update."
        if ($PSCmdlet.ShouldProcess("$($moduleNames.Count) modules", 'Update-PSResource')) {
            $throttle = [Math]::Min(8, [Math]::Max(2, [Environment]::ProcessorCount))
            Write-Log "Running parallel updates (throttle: $throttle)..."
            $job = Start-Job -ScriptBlock {
                param($Names, $Throttle)
                $Names | ForEach-Object -ThrottleLimit $Throttle -Parallel {
                    $n = $_
                    try {
                        $before = (Get-InstalledPSResource -Name $n -EA SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1).Version
                        Update-PSResource -Name $n -Scope AllUsers -TrustRepository -AcceptLicense -Quiet -EA Stop
                        $after = (Get-InstalledPSResource -Name $n -EA SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1).Version
                        if ($after -and $before -and $after -gt $before) {
                            "UPDATED|$n|$before|$after"
                        }
                    } catch {
                        "ERROR|$n|$_"
                    }
                }
            } -ArgumentList (,$moduleNames), $throttle
            $done = Wait-BootUpdateJobsWithProgress -Jobs @($job) `
                -TimeoutSeconds ($script:PackageTimeoutMinutes * 60) `
                -Activity 'Updating PowerShell modules' -Status 'PSResourceGet updates are running'
            if (-not $done) {
                $failed = $true
                Write-Log "TIMEOUT: PSResource bulk update exceeded ${script:PackageTimeoutMinutes}m" -Level Warn
                try { Get-Process -Id $job.ChildJobs[0].ProcessId -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue } catch { }
                $job | Stop-Job -PassThru | Remove-Job -Force
            } else {
                $results = @(Receive-Job $job -EA SilentlyContinue)
                $jobFailed = $job.State -eq 'Failed'
                Remove-Job $job -Force
                foreach ($line in $results) {
                    if ($line -is [string] -and $line -match '^UPDATED\|(.+)\|(.+)\|(.+)$') {
                        Write-Log "  $($Matches[1]): $($Matches[2]) -> $($Matches[3])"
                        $count++
                    } elseif ($line -is [string] -and $line -match '^ERROR\|(.+)\|(.+)$') {
                        $failed = $true
                        Write-Log "  $($Matches[1]) error: $($Matches[2])" -Level Warn
                    }
                }
                if ($jobFailed) { $failed = $true; Write-Log 'PSResource bulk update job reported failure' -Level Error }
            }
        } else {
            Write-Log "  [WHATIF] Would run: Update-PSResource for $($moduleNames.Count) modules"
        }
    } else {
        <# ── Legacy path: parallel Update-Module via ForEach-Object -Parallel inside one job ── #>
        Write-Log 'PSResourceGet not available — falling back to parallel Update-Module...'
        $installed = Get-InstalledModule -EA SilentlyContinue
        if (-not $installed) { Write-Log 'No user-installed modules found.' -Level Warn; return @{ Success = $true; Count = 0 } }
        $modules = @($installed | Where-Object {
            $_.Name -notlike 'Microsoft.PowerShell.*' -and
            $_.Name -notlike 'AWS.Tools.*' -and
            $_.Name -ne 'Az'
        })
        if (-not $modules) { Write-Log 'Only built-in modules found.'; return @{ Success = $true; Count = 0 } }
        Write-Log "Found $($modules.Count) module(s) to check."
        if ($PSCmdlet.ShouldProcess("$($modules.Count) modules", 'Update-Module')) {
            $throttle = [Math]::Min(8, [Math]::Max(2, [Environment]::ProcessorCount))
            $modulePairs = $modules | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version.ToString() } }
            Write-Log "Running parallel updates (throttle: $throttle)..."
            $job = Start-Job -ScriptBlock {
                param($Pairs, $Throttle)
                $Pairs | ForEach-Object -ThrottleLimit $Throttle -Parallel {
                    $n = $_.Name; $curVer = $_.Version
                    try {
                        Update-Module -Name $n -Force -EA Stop *> $null
                        $newVer = (Get-InstalledModule -Name $n -EA SilentlyContinue).Version.ToString()
                        if ($newVer -and ($newVer -ne $curVer)) {
                            "UPDATED|$n|$curVer|$newVer"
                        }
                    } catch {
                        if ($_ -match 'already the latest') { return }
                        "ERROR|$n|$_"
                    }
                }
            } -ArgumentList (,$modulePairs), $throttle
            $done = Wait-BootUpdateJobsWithProgress -Jobs @($job) `
                -TimeoutSeconds ($script:PackageTimeoutMinutes * 60) `
                -Activity 'Updating PowerShell modules' -Status 'Update-Module jobs are running'
            if (-not $done) {
                $failed = $true
                Write-Log "TIMEOUT: parallel module update exceeded ${script:PackageTimeoutMinutes}m" -Level Warn
                try { Get-Process -Id $job.ChildJobs[0].ProcessId -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue } catch { }
                $job | Stop-Job -PassThru | Remove-Job -Force
            } else {
                $results = @(Receive-Job $job -EA SilentlyContinue)
                $jobFailed = $job.State -eq 'Failed'
                Remove-Job $job -Force
                foreach ($line in $results) {
                    if ($line -is [string] -and $line -match '^UPDATED\|(.+)\|(.+)\|(.+)$') {
                        Write-Log "  $($Matches[1]): $($Matches[2]) -> $($Matches[3])"
                        $count++
                    } elseif ($line -is [string] -and $line -match '^ERROR\|(.+)\|(.+)$') {
                        $failed = $true
                        Write-Log "  $($Matches[1]) error: $($Matches[2])" -Level Warn
                    }
                }
                if ($jobFailed) { $failed = $true; Write-Log 'Parallel module update job reported failure' -Level Error }
            }
        } else {
            Write-Log "  [WHATIF] Would run: parallel Update-Module for $($modules.Count) modules"
        }
    }

    <# AWS.Tools modules: use the dedicated installer if available (both paths) #>
    $awsInstalled = if ($usePSResourceGet) {
        Get-InstalledPSResource -EA SilentlyContinue | Where-Object { $_.Name -like 'AWS.Tools.*' -and $_.Name -ne 'AWS.Tools.Installer' }
    } else {
        Get-InstalledModule -EA SilentlyContinue | Where-Object { $_.Name -like 'AWS.Tools.*' -and $_.Name -ne 'AWS.Tools.Installer' }
    }
    if ($awsInstalled -and (Get-Command Update-AWSToolsModule -EA SilentlyContinue)) {
        Write-Log "Updating $(@($awsInstalled).Count) AWS.Tools module(s) via Update-AWSToolsModule..."
        if ($PSCmdlet.ShouldProcess('AWS.Tools.*', 'Update-AWSToolsModule -CleanUp')) {
            try {
                $job = Start-Job -ScriptBlock { Update-AWSToolsModule -CleanUp -Force -Confirm:$false 2>&1 }
                $done = Wait-BootUpdateJobsWithProgress -Jobs @($job) `
                    -TimeoutSeconds ($script:PackageTimeoutMinutes * 60) `
                    -Activity 'Updating AWS.Tools modules' -Status 'AWS.Tools update is running'
                if (-not $done) {
                    $failed = $true
                    Write-Log 'TIMEOUT: AWS.Tools update exceeded timeout' -Level Warn
                    try { Get-Process -Id $job.ChildJobs[0].ProcessId -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue } catch { }
                    $job | Stop-Job -PassThru | Remove-Job -Force
                } else {
                    $awsJobFailed = $job.State -eq 'Failed'
                    $jobOutput = Receive-Job $job -EA SilentlyContinue
                    Remove-Job $job -Force
                    $jobOutput | ForEach-Object { Write-Log $_ }
                    $awsCount = @($jobOutput | Where-Object { $_ -match 'Installed|Updated' }).Count
                    if ($awsCount -gt 0) { Write-Log "  AWS.Tools: $awsCount module(s) updated"; $count += $awsCount }
                    else { Write-Log '  AWS.Tools: already latest' }
                    if ($awsJobFailed) { $failed = $true; Write-Log 'AWS.Tools update job reported failure.' -Level Error }
                }
            } catch { $failed = $true; Write-Log "AWS.Tools update error: $_" -Level Error }
        } else {
            Write-Log '  [WHATIF] Would run: Update-AWSToolsModule -CleanUp'
        }
    } elseif ($awsInstalled) {
        Write-Log "AWS.Tools modules found but Update-AWSToolsModule not available — skipping (install AWS.Tools.Installer)" -Level Warn
    }

    Write-Log "PS module updates: $count updated."
    return @{ Success = (-not $failed); Count = $count }
}

function Update-ScoopPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) { Write-Log 'Scoop skipped: SYSTEM context (user-scoped).' -Level Warn; return @{ Success = $true; Count = 0 } }
    $scoop = Get-Command scoop -EA SilentlyContinue
    if (-not $scoop) { Write-Log 'Scoop not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating Scoop...'
    if ($PSCmdlet.ShouldProcess('Scoop', 'Run scoop update and scoop update *')) {
        try {
            $scoopSelf = Invoke-BootUpdateBackgroundOperation -Name 'Updating Scoop' `
                -Status 'Scoop metadata update is running' -TimeoutMinutes $script:PackageTimeoutMinutes `
                -ScriptBlock { param($Path) & $Path update 2>&1 } -ArgumentList @($scoop.Source)
            $scoopSelf.Output | ForEach-Object { Write-Log $_ }
            if ($scoopSelf.Failed -or $scoopSelf.TimedOut) {
                Write-Log 'Scoop metadata update failed or timed out.' -Level Error
                return @{ Success = $false; Count = 0 }
            }
            Write-Log 'Updating all Scoop packages...'
            $count = 0
            $result = Invoke-BootUpdateBackgroundOperation -Name 'Updating Scoop packages' `
                -Status 'Scoop package updates are running' -TimeoutMinutes $script:PackageTimeoutMinutes `
                -ScriptBlock { param($Path) & $Path update '*' 2>&1 } -ArgumentList @($scoop.Source)
            $result.Output | ForEach-Object {
                if ($_ -match '^\s*\S+:\s+\S+\s+->\s+\S+') { $count++ }
                Write-Log $_
            }
            if ($result.Failed -or $result.TimedOut) { Write-Log 'Scoop package updates failed or timed out.' -Level Error; return @{ Success = $false; Count = $count } }
            Write-Log "Scoop: $count package(s) updated."
            return @{ Success = $true; Count = $count }
        } catch { Write-Log "Scoop error: $_" -Level Error; return @{ Success = $false; Count = 0 } }
    } else {
        Write-Log '  [WHATIF] Would run: scoop update && scoop update *'
        return @{ Success = $true; Count = 0 }
    }
}

function Update-DotnetTools {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $dotnet = Get-Command dotnet -EA SilentlyContinue
    if (-not $dotnet) { Write-Log 'dotnet not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log '*** DOTNET TOOLS UPDATE - HIGH RISK ***' -Level Warn
    Write-Log '    May break SDK-dependent builds. To disable: -SkipDotnetTools' -Level Warn
    try {
        $listResult = Invoke-BootUpdateBackgroundOperation -Name 'Checking .NET global tools' `
            -Status '.NET tool inventory is running' -TimeoutMinutes 5 `
            -ScriptBlock { param($Path) & $Path tool list --global 2>&1 } -ArgumentList @($dotnet.Source)
        $listOutput = $listResult.Output
        if ($listResult.Failed -or $listResult.TimedOut) {
            Write-Log '.NET global tool inventory failed or timed out.' -Level Error
            return @{ Success = $false; Count = 0 }
        }
        $tools = @($listOutput | Select-Object -Skip 2 | Where-Object { $_ -match '^\S' } | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($tools.Count -eq 0) { Write-Log 'No .NET global tools found.'; return @{ Success = $true; Count = 0 } }
        Write-Log "Found $($tools.Count) tool(s): $($tools -join ', ')"
        $count = 0; $failed = $false
        foreach ($tool in $tools) {
            Write-Log "Updating: $tool"
            if ($PSCmdlet.ShouldProcess($tool, 'dotnet tool update --global')) {
                try {
                    $result = Invoke-BootUpdateBackgroundOperation -Name "Updating .NET tool $tool" `
                        -Status "$tool update is running" -TimeoutMinutes $script:PackageTimeoutMinutes `
                        -ScriptBlock { param($Path, $Tool) & $Path tool update --global $Tool 2>&1 } `
                        -ArgumentList @($dotnet.Source, $tool)
                    $output = $result.Output
                    $output | ForEach-Object { Write-Log $_ }
                    if ($result.Failed -or $result.TimedOut) {
                        $failed = $true
                        Write-Log "  $tool update failed or timed out." -Level Error
                    } elseif ($output -match 'was successfully updated') { $count++ }
                } catch { $failed = $true; Write-Log "  $tool error: $_" -Level Error }
            } else {
                Write-Log "  [WHATIF] Would run: dotnet tool update --global $tool"
            }
        }
        Write-Log "dotnet tools: $count updated."
        return @{ Success = (-not $failed); Count = $count }
    } catch { Write-Log "dotnet tools error: $_" -Level Error; return @{ Success = $false; Count = 0 } }
}

function Update-VscodeExtensions {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) { Write-Log 'VS Code skipped: SYSTEM context (per-user).' -Level Warn; return @{ Success = $true; Count = 0 } }
    $codeCmd = Get-Command code -EA SilentlyContinue
    if (-not $codeCmd) { $codeCmd = Get-Command code-insiders -EA SilentlyContinue }
    if (-not $codeCmd) { Write-Log 'VS Code not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log "Updating VS Code extensions via: $($codeCmd.Name)"
    if ($PSCmdlet.ShouldProcess('VS Code', 'Run code --update-extensions')) {
        try {
            $result = Invoke-BootUpdateBackgroundOperation -Name 'Updating VS Code extensions' `
                -Status 'VS Code extension updates are running' -TimeoutMinutes $script:PackageTimeoutMinutes `
                -ScriptBlock { param($Path) & $Path --update-extensions 2>&1 } `
                -ArgumentList @($codeCmd.Source)
            $output = $result.Output
            $output | ForEach-Object { Write-Log $_ }
            if ($result.Failed -or $result.TimedOut) {
                Write-Log 'VS Code extension update failed or timed out.' -Level Error
                return @{ Success = $false; Count = 0 }
            }
            $count = @($output | Where-Object { $_ -match '(?i)updating extension|updated to version' }).Count
            if ($count -eq 0) {
                $upToDate = $output | Where-Object { $_ -match '(?i)already installed|up.to.date' }
                if ($upToDate) { Write-Log 'VS Code extensions: all up to date.'; $count = 0 }
                else { Write-Log 'VS Code extensions: update ran (exact count unavailable).'; $count = 1 }
            } else { Write-Log "VS Code extensions: $count updated." }
            return @{ Success = $true; Count = $count }
        } catch { Write-Log "VS Code error: $_" -Level Error; return @{ Success = $false; Count = 0 } }
    } else {
        Write-Log '  [WHATIF] Would run: code --update-extensions'
        return @{ Success = $true; Count = 0 }
    }
}

function Repair-AwsTooling {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $awsScript = Join-Path $PSScriptRoot 'Repair-AwsTooling.ps1'
    if (-not (Test-Path $awsScript)) { Write-Log 'Repair-AwsTooling.ps1 not found; AWS tooling phase cannot run.' -Level Error; return $false }
    Write-Log 'Repairing AWS tooling...'
    if ($PSCmdlet.ShouldProcess('AWS tooling', 'Run Repair-AwsTooling.ps1 -Mode Remediate')) {
        try {
            $result = Invoke-BootUpdateBackgroundOperation -Name 'Repairing AWS tooling' `
                -Status 'AWS CLI and module remediation is running' `
                -TimeoutMinutes $script:PackageTimeoutMinutes `
                -ScriptBlock {
                    param($Path)
                    & pwsh -NoProfile -NonInteractive -File $Path -Mode Remediate 2>&1
                    "BOOTUPDATE_EXIT|$LASTEXITCODE"
                } -ArgumentList @($awsScript)
            $exitCode = -1
            foreach ($line in $result.Output) {
                if ($line -match '^BOOTUPDATE_EXIT\|(-?\d+)$') { $exitCode = [int]$Matches[1]; continue }
                Write-Log $line.ToString()
            }
            if ($result.Failed -or $result.TimedOut -or $exitCode -ne 0) {
                Write-Log "AWS tooling repair failed or timed out (exit $exitCode)." -Level Error
                return $false
            }
        } catch { Write-Log "AWS error: $_" -Level Error; return $false }
    } else {
        Write-Log '  [WHATIF] Would run: Repair-AwsTooling.ps1 -Mode Remediate'
    }
    return $true
}
#endregion

#region Health Check
function Test-PostUpdateHealth {
    <#
    .SYNOPSIS
        Verifies that critical Windows services are running after the update cycle.

    .DESCRIPTION
        Checks each service in CriticalServices.  If a service is stopped or
        stop-pending, one non-blocking start attempt is made using a background
        job with a 5-second timeout so a hung SCM call can never stall the cycle.
        Never throws — health check failure must not abort cleanup.

    .OUTPUTS
        [PSCustomObject] with AllHealthy, FailedServices, CheckedServices.
    #>
    param(
        [string[]]$CriticalServices = @('W32Time', 'WinDefend', 'Dnscache', 'Spooler', 'EventLog')
    )

    Write-Log '--- Post-Update Health Check ---'

    $checked = [System.Collections.Generic.List[string]]::new()
    $failed  = [System.Collections.Generic.List[string]]::new()

    foreach ($svc in $CriticalServices) {
        try {
            $serviceObj = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $serviceObj) {
                Write-Log "  Health check: service not found: $svc (skipped — may not exist on this SKU)" -Level Warn
                continue
            }

            $checked.Add($svc)

            if ($serviceObj.Status -in @('Stopped', 'StopPending')) {
                Write-Log "  Health check: $svc is $($serviceObj.Status) — attempting start (5 s timeout)..."
                $startJob = Start-Job -ScriptBlock {
                    param($n) Start-Service -Name $n -ErrorAction SilentlyContinue
                } -ArgumentList $svc

                $null = Wait-BootUpdateJobsWithProgress -Jobs @($startJob) -TimeoutSeconds 5 `
                    -Activity 'Post-update health check' -Status "Starting service $svc"
                if ($startJob.State -eq 'Running') {
                    Stop-Job  -Job $startJob
                    Write-Log "  Health check: $svc start timed out (>5 s) — service may still be starting" -Level Warn
                }
                Remove-Job -Job $startJob -Force

                <# Re-query after attempt #>
                $refreshed = Get-Service -Name $svc -ErrorAction SilentlyContinue
                if ($refreshed -and $refreshed.Status -eq 'Running') {
                    Write-Log "  Health check: $svc started successfully"
                } else {
                    $finalStatus = if ($refreshed) { $refreshed.Status } else { 'Unknown' }
                    Write-Log "  Health check: $svc still not running (status: $finalStatus)" -Level Warn
                    $failed.Add($svc)
                }
            } else {
                Write-Log "  Health check: $svc is $($serviceObj.Status)"
            }
        } catch {
            Write-Log "  Health check: unexpected error checking $svc`: $_" -Level Warn
        }
    }

    $allHealthy = ($failed.Count -eq 0)
    if ($allHealthy) {
        Write-Log "  Health check: all $($checked.Count) service(s) healthy"
    } else {
        Write-Log "  Health check: $($failed.Count) service(s) not running: $($failed -join ', ')" -Level Warn
    }

    return [pscustomobject]@{
        AllHealthy      = $allHealthy
        FailedServices  = [string[]]$failed
        CheckedServices = [string[]]$checked
    }
}
#endregion

#region Maintenance Window
function Test-MaintenanceWindow {
    <#
    .SYNOPSIS
        Returns $true if the current hour falls within the configured maintenance window.

    .DESCRIPTION
        If either MaintenanceWindowStart or MaintenanceWindowEnd is -1 (default), no window
        is enforced and the function always returns $true.

        Supports midnight-crossing windows: e.g., Start=22 End=2 covers 10 PM through 2 AM.
        Normal windows: e.g., Start=2 End=5 covers 2 AM through 4:59 AM.

    .OUTPUTS
        [bool] $true = inside window (proceed); $false = outside window (defer).
    #>
    if ($script:MaintenanceWindowStart -eq -1 -or $script:MaintenanceWindowEnd -eq -1) {
        return $true
    }

    $now = (Get-Date).Hour

    if ($script:MaintenanceWindowStart -gt $script:MaintenanceWindowEnd) {
        # Midnight-crossing window (e.g., Start=22, End=2: 10 PM to 2 AM)
        return ($now -ge $script:MaintenanceWindowStart) -or ($now -lt $script:MaintenanceWindowEnd)
    } else {
        # Normal window (e.g., Start=2, End=5: 2 AM to 4:59 AM)
        return ($now -ge $script:MaintenanceWindowStart) -and ($now -lt $script:MaintenanceWindowEnd)
    }
}

function Get-NextMaintenanceWindowStart {
    param([datetime]$Now = (Get-Date))
    if ($script:MaintenanceWindowStart -lt 0) { return $Now.AddMinutes(2) }
    $next = $Now.Date.AddHours($script:MaintenanceWindowStart)
    if ($next -le $Now) { $next = $next.AddDays(1) }
    return $next
}
#endregion

#region Task Management
function Unregister-BootUpdateTask {
    foreach ($taskName in @('BootUpdateCycle', 'BootUpdateCycleFallback')) {
        if (Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Write-Log "Scheduled task removed: $taskName"
        }
    }
}

function Test-ArsoAvailable {
    <# Best-effort check that Windows ARSO (Automatic Restart Sign-On) will sign the
       current user back in after `shutdown /g`. No stored password involved — winlogon
       handles the resume. Returns $false under SYSTEM (no interactive user to resume),
       when the DisableAutomaticRestartSignOn policy is set, or when the user opted out
       (Settings > Accounts > Sign-in options). #>
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.User.Value -eq 'S-1-5-18') { return $false }
        $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -EA Ignore
        if ($pol -and ($pol.PSObject.Properties.Name -contains 'DisableAutomaticRestartSignOn') -and ([int]$pol.DisableAutomaticRestartSignOn -eq 1)) { return $false }
        $arso = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\UserARSO\$($identity.User.Value)" -EA Ignore
        if ($arso -and ($arso.PSObject.Properties.Name -contains 'OptOut') -and ([int]$arso.OptOut -eq 1)) { return $false }
        return $true
    } catch { return $false }
}

function Register-BootUpdateTaskForReboot {
    param(
        [switch]$RetrySoon,
        [Nullable[datetime]]$RetryAt = $null
    )
    $taskName = 'BootUpdateCycle'
    $pwshPath = (Get-Command pwsh -EA SilentlyContinue).Source
    if (-not $pwshPath) { $pwshPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
    $scriptPath = Join-Path $PSScriptRoot 'Invoke-BootUpdateCycle.ps1'
    $taskArgs = @(
        '-NoProfile', '-ExecutionPolicy Bypass'
        "-File `"$scriptPath`"", '-Force'
        "-MaxIterations $($script:MaxIterations)"
        "-PackageTimeoutMinutes $($script:PackageTimeoutMinutes)"
        "-RebootDelaySec $($script:RebootDelaySec)"
        "-OutputMode $($script:OutputMode)"
    )
    if ($script:SkipPip)              { $taskArgs += '-SkipPip' }
    if ($script:SkipNpm)              { $taskArgs += '-SkipNpm' }
    if ($script:SkipOffice365)        { $taskArgs += '-SkipOffice365' }
    if ($script:SkipAwsTooling)       { $taskArgs += '-SkipAwsTooling' }
    if ($script:SkipPowerShellModules){ $taskArgs += '-SkipPowerShellModules' }
    if ($script:SkipScoop)            { $taskArgs += '-SkipScoop' }
    if ($script:SkipDotnetTools)      { $taskArgs += '-SkipDotnetTools' }
    if ($script:SkipVscode)           { $taskArgs += '-SkipVscode' }
    if ($script:SkipDefender)         { $taskArgs += '-SkipDefender' }
    if ($script:IncludeDriverUpdates) { $taskArgs += '-IncludeDriverUpdates' }
    if ($script:IncludeFirmwareUpdates) { $taskArgs += '-IncludeFirmwareUpdates' }
    if ($script:UpdateWsl)            { $taskArgs += '-UpdateWsl' }
    if ($script:UpdateContainers)     { $taskArgs += '-UpdateContainers' }
    if ($script:SkipRestorePoint)     { $taskArgs += '-SkipRestorePoint' }
    if ($script:SkipHealthCheck)      { $taskArgs += '-SkipHealthCheck' }
    if ($script:SkipBitLocker)        { $taskArgs += '-SkipBitLocker' }
    if ($script:AllowMetered)         { $taskArgs += '-AllowMetered' }
    if ($script:DisableSelfUpdate)    { $taskArgs += '-DisableSelfUpdate' }
    if ($script:StagedRollout)        { $taskArgs += '-StagedRollout' }
    if ($script:NotifyEmail)          { $taskArgs += "-NotifyEmail `"$($script:NotifyEmail)`"" }
    if ($script:SmtpServer)           { $taskArgs += "-SmtpServer `"$($script:SmtpServer)`"" }
    if ($script:MaintenanceWindowStart -ge 0) { $taskArgs += "-MaintenanceWindowStart $($script:MaintenanceWindowStart)" }
    if ($script:MaintenanceWindowEnd   -ge 0) { $taskArgs += "-MaintenanceWindowEnd $($script:MaintenanceWindowEnd)" }
    if ($script:ConfigUrl)       { $taskArgs += "-ConfigUrl `"$($script:ConfigUrl)`"" }
    if ($script:PreCycleScript)  { $taskArgs += "-PreCycleScript `"$($script:PreCycleScript)`"" }
    if ($script:PostCycleScript) { $taskArgs += "-PostCycleScript `"$($script:PostCycleScript)`"" }
    if ($script:HooksConfig)     { $taskArgs += "-HooksConfig `"$($script:HooksConfig)`"" }
    if ($script:ExcludePatterns.Count -gt 0) {
        $encodedPatterns = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:ExcludePatterns | ConvertTo-Json -Compress)))
        $taskArgs += "-ExcludePatternsBase64 $encodedPatterns"
    }
    if ($script:IncludePatterns.Count -gt 0) {
        $encodedPatterns = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:IncludePatterns | ConvertTo-Json -Compress)))
        $taskArgs += "-IncludePatternsBase64 $encodedPatterns"
    }
    if ($script:NotificationLevel -ne 'Full') { $taskArgs += "-NotificationLevel $($script:NotificationLevel)" }
    $argString = $taskArgs -join ' '
    $action   = New-ScheduledTaskAction -Execute $pwshPath -Argument $argString -WorkingDirectory $PSScriptRoot
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    $registeredTaskNames = [System.Collections.Generic.List[string]]::new()
    $expectedPrincipal = @{}
    $expectedTriggerTypes = @{}
    $retryTime = if ($RetryAt.HasValue) { $RetryAt.Value } elseif ($RetrySoon) { (Get-Date).AddMinutes(2) } else { $null }
    $retryTrigger = if ($retryTime) { New-ScheduledTaskTrigger -Once -At $retryTime } else { $null }

    <# ARSO user-context resume (2ql): reboots use `shutdown /g`, so where ARSO is
       available winlogon signs the user back in — the primary task then triggers at
       that logon and runs in USER context, so user-scoped phases (winget user scope,
       Scoop, VS Code, WSL, containers) run on EVERY iteration, not just the first.
       A SYSTEM fallback task with a 3-minute startup delay covers the case where
       ARSO does not sign the user in; the named mutex arbitrates if both fire
       (second instance exits immediately) and phase Done-flags prevent double work.
       If no interactive identity is discoverable, a SYSTEM task is retained; callers
       must add a dated retry when user-scoped completion is still pending. #>
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $resumeUser = if ($script:ResumeUser) { $script:ResumeUser } elseif ($currentIdentity.User.Value -ne 'S-1-5-18') { $currentIdentity.Name } else { $null }
    if ($resumeUser) {
        $currentUser = $resumeUser
        $userTrigger   = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
        $userPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
        $userTriggers = if ($retryTrigger) { @($userTrigger, $retryTrigger) } else { @($userTrigger) }
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $userTriggers -Principal $userPrincipal -Settings $settings `
            -Description 'Boot update loop: patches everything, reboots until clean. (user context via ARSO)' -Force -ErrorAction Stop | Out-Null
        $registeredTaskNames.Add($taskName)
        $expectedPrincipal[$taskName] = $currentUser
        $expectedTriggerTypes[$taskName] = @('MSFT_TaskLogonTrigger') + $(if ($retryTrigger) { 'MSFT_TaskTimeTrigger' } else { @() })
        $arsoText = if (Test-ArsoAvailable) { 'ARSO or interactive logon' } else { 'next interactive logon' }
        Write-Log "Scheduled task registered: $taskName ($currentUser at logon — $arsoText)"

        $fbTrigger = New-ScheduledTaskTrigger -AtStartup
        $fbTrigger.Delay = 'PT3M'
        $fallbackTriggers = if ($retryTrigger) { @($fbTrigger, $retryTrigger) } else { @($fbTrigger) }
        $fbPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'BootUpdateCycleFallback' -Action $action -Trigger $fallbackTriggers -Principal $fbPrincipal -Settings $settings `
            -Description 'Boot update loop fallback: runs as SYSTEM if ARSO sign-on does not occur.' -Force -ErrorAction Stop | Out-Null
        $registeredTaskNames.Add('BootUpdateCycleFallback')
        $expectedPrincipal['BootUpdateCycleFallback'] = 'SYSTEM'
        $expectedTriggerTypes['BootUpdateCycleFallback'] = @('MSFT_TaskBootTrigger') + $(if ($retryTrigger) { 'MSFT_TaskTimeTrigger' } else { @() })
        Write-Log 'Scheduled task registered: BootUpdateCycleFallback (SYSTEM at startup +3min, mutex-arbitrated)'
    } else {
        $trigger  = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $systemTriggers = if ($retryTrigger) { @($trigger, $retryTrigger) } else { @($trigger) }
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $systemTriggers -Principal $principal -Settings $settings `
            -Description 'Boot update loop: patches everything, reboots until clean.' -Force -ErrorAction Stop | Out-Null
        $registeredTaskNames.Add($taskName)
        $expectedPrincipal[$taskName] = 'SYSTEM'
        $expectedTriggerTypes[$taskName] = @('MSFT_TaskBootTrigger') + $(if ($retryTrigger) { 'MSFT_TaskTimeTrigger' } else { @() })
        Write-Log "Scheduled task registered: $taskName (SYSTEM at startup — ARSO unavailable)"
    }

    <# Fail closed before rebooting: registration success is not enough if policy or a
       task-store race leaves the task disabled or with the wrong action. #>
    foreach ($registeredName in $registeredTaskNames) {
        $task = Get-ScheduledTask -TaskName $registeredName -ErrorAction Stop
        if ($task.State -eq 'Disabled') { throw "Resume task '$registeredName' is disabled." }
        $actualPrincipal = [string]$task.Principal.UserId
        $expectedUser = [string]$expectedPrincipal[$registeredName]
        if ($expectedUser -eq 'SYSTEM') {
            if ($actualPrincipal -notin @('SYSTEM','S-1-5-18')) { throw "Resume task '$registeredName' has the wrong principal." }
        } elseif ($actualPrincipal -ne $expectedUser) { throw "Resume task '$registeredName' has the wrong principal." }
        if ([int]$task.Settings.RestartCount -ne 3) { throw "Resume task '$registeredName' is missing its retry policy." }
        $matchingAction = @($task.Actions | Where-Object {
            $_.Execute -eq $pwshPath -and $_.Arguments -eq $argString -and $_.WorkingDirectory -eq $PSScriptRoot
        })
        if ($matchingAction.Count -eq 0) { throw "Resume task '$registeredName' does not contain the exact expected orchestrator action and arguments." }
        $actualTriggerTypes = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
        foreach ($triggerType in $expectedTriggerTypes[$registeredName]) {
            if ($actualTriggerTypes -notcontains $triggerType) { throw "Resume task '$registeredName' is missing trigger type '$triggerType'." }
        }
        if ($registeredName -eq 'BootUpdateCycleFallback') {
            $bootTrigger = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }) | Select-Object -First 1
            if (-not $bootTrigger -or $bootTrigger.Delay -ne 'PT3M') { throw "Resume task '$registeredName' is missing the three-minute startup delay." }
        }
    }
    Write-Log "Resume chain verified: $($registeredTaskNames -join ', ') (3 retries, 2-minute interval)."
    return $registeredTaskNames.ToArray()
}

function Suspend-BitLockerForReboot {
    <# Suspends BitLocker protection for exactly one reboot so the unattended loop
       doesn't land at a recovery prompt.  Best-effort — never throws. #>
    try {
        if ($script:SkipBitLocker) {
            Write-Log 'BitLocker suspend skipped (-SkipBitLocker).'
            return
        }

        $protectedVolumes = Get-BitLockerVolume -ErrorAction Stop |
            Where-Object { $_.ProtectionStatus -eq 'On' }

        if (-not $protectedVolumes) {
            Write-Log 'BitLocker: no protected volumes found — nothing to suspend.'
            return
        }

        foreach ($vol in $protectedVolumes) {
            $drive = $vol.MountPoint
            $suspended = $false

            # Primary path: BitLocker cmdlet (preferred — returns structured objects)
            try {
                $vol | Suspend-BitLocker -RebootCount 1 -ErrorAction Stop | Out-Null
                Write-Log "BitLocker suspended for 1 reboot on $drive"
                $suspended = $true
            } catch {
                Write-Log "BitLocker cmdlet failed on $drive (${_}); trying manage-bde fallback." -Level Warn
            }

            # Fallback: manage-bde.exe (available even when the PS module is broken)
            if (-not $suspended) {
                try {
                    $bdeOut = & manage-bde.exe -protectors -disable $drive -RebootCount 1 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "BitLocker suspended via manage-bde on $drive"
                    } else {
                        Write-Log "manage-bde failed on $drive (exit $LASTEXITCODE): $bdeOut" -Level Warn
                    }
                } catch {
                    Write-Log "manage-bde.exe unavailable on ${drive}: $_" -Level Warn
                }
            }
        }
    } catch {
        Write-Log "Suspend-BitLockerForReboot: unexpected error: $_" -Level Warn
    }
}
#endregion

#region Notifications
function Write-EventLogEntry {
    <# Central event log helper.  IDs: 1000=Complete, 1001=Reboot, 1002=Started, 1003=Failed, 1004=PhaseComplete #>
    param([int]$EventId, [string]$EntryType = 'Information', [string]$Message)
    try {
        $src = 'BootUpdateCycle'
        if (-not [System.Diagnostics.EventLog]::SourceExists($src)) { New-EventLog -LogName Application -Source $src -EA SilentlyContinue }
        Write-EventLog -LogName Application -Source $src -EventId $EventId -EntryType $EntryType -Message $Message
    } catch { }
}

function Send-WebhookNotification {
    param(
        [string]$Title,
        [string]$Message,
        [hashtable]$Data = @{}
    )
    if ([string]::IsNullOrWhiteSpace($script:WebhookUrl)) { return }

    <# Transparent-proxy support: SYSTEM context may not inherit user proxy config #>
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials

    $url = $script:WebhookUrl

    <# Build facts/fields from $Data for richer payloads #>
    $totalPkgs  = if ($Data.ContainsKey('_total'))     { $Data['_total'] }     else { 0 }
    $iterations = if ($Data.ContainsKey('_iterations')) { $Data['_iterations'] } else { 0 }
    $durMin     = if ($Data.ContainsKey('_durMin'))    { $Data['_durMin'] }    else { 0 }

    $perMgr = @(
        @{ n = 'Winget';          k = 'Winget'          }
        @{ n = 'Chocolatey';      k = 'Chocolatey'      }
        @{ n = 'Windows Update';  k = 'WindowsUpdate'   }
        @{ n = 'pip';             k = 'Pip'             }
        @{ n = 'npm';             k = 'Npm'             }
        @{ n = 'Office 365';      k = 'Office365'       }
        @{ n = 'PS Modules';      k = 'PowerShellModules' }
        @{ n = 'Scoop';           k = 'Scoop'           }
        @{ n = '.NET Tools';      k = 'DotnetTools'     }
        @{ n = 'VS Code';         k = 'Vscode'          }
    )

    try {
        if ($url -match 'webhook\.office\.com|teams') {
            <# Microsoft Teams: MessageCard format #>
            $facts = @(
                @{ name = 'Duration';    value = "$durMin min" }
                @{ name = 'Iterations';  value = "$iterations" }
                @{ name = 'Total Pkgs';  value = "$totalPkgs"  }
            )
            foreach ($pm in $perMgr) {
                $cnt = if ($Data.ContainsKey($pm.k)) { $Data[$pm.k] } else { 0 }
                if ($cnt -gt 0) { $facts += @{ name = $pm.n; value = "$cnt pkg(s)" } }
            }
            $payload = [ordered]@{
                '@type'      = 'MessageCard'
                '@context'   = 'https://schema.org/extensions'
                themeColor   = '0078D4'
                title        = $Title
                text         = $Message
                facts        = $facts
            }
        } elseif ($url -match 'hooks\.slack\.com') {
            <# Slack: simple text payload #>
            $lines = @($Title, $Message, "Duration: $durMin min | Iterations: $iterations | Total: $totalPkgs pkg(s)")
            foreach ($pm in $perMgr) {
                $cnt = if ($Data.ContainsKey($pm.k)) { $Data[$pm.k] } else { 0 }
                if ($cnt -gt 0) { $lines += "$($pm.n): $cnt" }
            }
            $payload = @{ text = ($lines -join "`n") }
        } elseif ($url -match 'discord\.com') {
            <# Discord: embeds format #>
            $fields = @(
                @{ name = 'Duration';   value = "$durMin min";    inline = $true }
                @{ name = 'Iterations'; value = "$iterations";    inline = $true }
                @{ name = 'Total Pkgs'; value = "$totalPkgs pkg"; inline = $true }
            )
            foreach ($pm in $perMgr) {
                $cnt = if ($Data.ContainsKey($pm.k)) { $Data[$pm.k] } else { 0 }
                if ($cnt -gt 0) { $fields += @{ name = $pm.n; value = "$cnt"; inline = $true } }
            }
            $payload = @{
                content = $Title
                embeds  = @(@{
                    description = $Message
                    color       = 5025616  <# #4CAF50 green #>
                    fields      = $fields
                })
            }
        } else {
            <# Generic fallback #>
            $payload = @{ text = "$Title`n$Message" }
        }

        $jsonBody = $payload | ConvertTo-Json -Depth 6 -Compress
        $maxRetries = 3
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                <# Keep the bearer URL out of child-process arguments. The request itself is
                   capped at 10 seconds; animated retry delays resume immediately on failure. #>
                Invoke-RestMethod -Uri $url -Method Post -Body $jsonBody `
                    -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
                Write-Log "Notification: webhook delivered"
                break
            } catch {
                if ($attempt -lt $maxRetries) {
                    Write-Log "Notification: webhook attempt $attempt failed, retrying in $($attempt * 2)s..." -Level Warn
                    Wait-BootUpdateUiInterval -Seconds ($attempt * 2) `
                        -Activity 'Sending completion notification' -Status 'Waiting to retry webhook delivery'
                } else {
                    Write-Log "Notification: webhook failed after $maxRetries attempts: $_" -Level Warn
                }
            }
        }
    } catch {
        Write-Log "Notification: webhook error: $_" -Level Warn
    }
}

function Send-EmailNotification {
    param(
        [string]$Title,
        [string]$Message,
        [hashtable]$Data = @{}
    )
    if ([string]::IsNullOrWhiteSpace($script:NotifyEmail)) { return }
    if ([string]::IsNullOrWhiteSpace($script:SmtpServer))  { return }

    <# SMTP auth: pass credential if provided, otherwise rely on anonymous/relay #>

    Write-Log "Sending email notification to $($script:NotifyEmail)"

    $totalPkgs  = if ($Data.ContainsKey('_total'))     { $Data['_total'] }     else { 0 }
    $iterations = if ($Data.ContainsKey('_iterations')) { $Data['_iterations'] } else { 0 }
    $durMin     = if ($Data.ContainsKey('_durMin'))    { $Data['_durMin'] }    else { 0 }

    $bodyLines = @(
        $Title
        ''
        $Message
        ''
        "Duration:   $durMin min"
        "Iterations: $iterations"
        "Total pkgs: $totalPkgs"
        ''
        "Per package manager:"
        "  Winget:          $($Data['Winget'] ?? 0)"
        "  Chocolatey:      $($Data['Chocolatey'] ?? 0)"
        "  Windows Update:  $($Data['WindowsUpdate'] ?? 0)"
        "  pip:             $($Data['Pip'] ?? 0)"
        "  npm:             $($Data['Npm'] ?? 0)"
        "  Office 365:      $($Data['Office365'] ?? 0)"
        "  PS Modules:      $($Data['PowerShellModules'] ?? 0)"
        "  Scoop:           $($Data['Scoop'] ?? 0)"
        "  .NET Tools:      $($Data['DotnetTools'] ?? 0)"
        "  VS Code:         $($Data['Vscode'] ?? 0)"
        ''
        "Host: $env:COMPUTERNAME"
        "Sent: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    )

    try {
        $mailParams = @{
            To         = $script:NotifyEmail
            From       = "BootUpdateCycle@$env:COMPUTERNAME"
            Subject    = $Title
            Body       = ($bodyLines -join "`n")
            SmtpServer = $script:SmtpServer
            UseSsl     = $true
            Port       = 587
        }
        if ($script:SmtpCredential) {
            $mailParams['Credential'] = $script:SmtpCredential
        }
        $mailJob = Send-MailMessage @mailParams -AsJob
        Write-Log "Notification: email job queued to $($script:NotifyEmail)"
        $null = Wait-BootUpdateJobsWithProgress -Jobs @($mailJob) -TimeoutSeconds 30 `
            -Activity 'Sending completion notification' -Status 'Waiting for email delivery'
        $jobErrors = @(Receive-Job -Job $mailJob -ErrorAction SilentlyContinue -ErrorVariable receiveErrs 2>$null)
        if ($receiveErrs) { Write-Log "Notification: email job errors: $($receiveErrs -join '; ')" -Level Warn }
        Remove-Job -Job $mailJob -Force
    } catch {
        Write-Log "Notification: email failed: $_" -Level Warn
    }
}

function Send-CompletionNotification {
    param([string]$Title, [string]$Message, [pscustomobject]$Data = $null,
          [ValidateSet('Success','Error','Progress')][string]$Kind = 'Success')
    <# Event log is always written (audit trail); everything else honors -NotificationLevel #>
    if (-not (Test-NotificationAllowed -Kind $Kind)) {
        Write-EventLogEntry -EventId 1000 -Message "$Title`n$Message"
        Write-Log "Notifications suppressed (NotificationLevel=$($script:NotificationLevel), kind=$Kind); event log entry written."
        return
    }
    Write-Log 'Sending completion notifications...'
    <# msg.exe broadcast #>
    try {
        $msgExe = Join-Path $env:SystemRoot 'System32\msg.exe'
        if (Test-Path $msgExe) { & $msgExe * /TIME:120 "$Title`n`n$Message" 2>$null; if ($LASTEXITCODE -eq 0) { Write-Log 'Notification: msg.exe sent' } }
    } catch { }
    <# BurntToast (user context only) #>
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if (-not $isSystem) {
        try {
            if (-not (Get-Module -ListAvailable BurntToast)) { Install-Module BurntToast -Force -Scope CurrentUser -AllowClobber }
            Import-Module BurntToast -Force; New-BurntToastNotification -Text $Title, $Message -AppLogo $null
            Write-Log 'Notification: BurntToast sent'
        } catch { Write-Log "Notification: BurntToast failed: $_" -Level Warn }
    }
    Write-EventLogEntry -EventId 1000 -Message "$Title`n$Message"

    <# Build a flat hashtable from the pscustomobject summary for webhook/email functions #>
    $dataHt = @{}
    if ($null -ne $Data) {
        foreach ($prop in $Data.PSObject.Properties) { $dataHt[$prop.Name] = $prop.Value }
    }
    Send-WebhookNotification -Title $Title -Message $Message -Data $dataHt
    Send-EmailNotification   -Title $Title -Message $Message -Data $dataHt
}

function Send-RebootWarning {
    param([int]$SecondsUntilReboot = 120)
    $msgFull = "Boot Update Cycle needs to reboot.`nReboot in: $SecondsUntilReboot seconds`nTo cancel: shutdown /a"
    Write-Log 'Sending reboot warnings...'
    <# Toast is gated as Progress noise; the native shutdown countdown dialog and the
       event log entry are NOT gated — the abort window must stay discoverable. #>
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if (-not $isSystem -and (Test-NotificationAllowed -Kind Progress)) {
        try { if (Get-Module -ListAvailable BurntToast) { Import-Module BurntToast -Force; New-BurntToastNotification -Text 'System Reboot Warning', $msgFull -AppLogo $null -Sound 'Alarm' } } catch { }
    }
    Write-EventLogEntry -EventId 1001 -EntryType Warning -Message $msgFull
}

function Start-BootUpdateRestart {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string]$Reason
    )
    <# Also arm a dated watchdog. If the user accepts the documented `shutdown /a`
       escape hatch, neither startup nor logon fires; the watchdog keeps the durable
       chain alive. A normal reboot makes this trigger harmless and mutex-arbitrated. #>
    $restartWatchdog = (Get-Date).AddSeconds([math]::Max(120, $script:RebootDelaySec) + 300)
    $null = Register-BootUpdateTaskForReboot -RetryAt $restartWatchdog
    Send-RebootWarning -SecondsUntilReboot $script:RebootDelaySec
    if (Test-NotificationAllowed -Kind Progress) {
        Send-WebhookNotification -Title "Boot Update Cycle: Rebooting ($env:COMPUTERNAME)" `
            -Message "$Reason Rebooting in $($script:RebootDelaySec)s; the verified checkpoint will resume after boot." -Data @{}
    }
    Write-BootUpdateProgress -Completed
    Show-CycleBanner -Title 'R E B O O T I N G . . .' -AnsiColor "$([char]27)[33m" -Info @(
        "Shutdown in $($script:RebootDelaySec) seconds"
        'Cancel:  shutdown /a'
        'Resume: user-at-logon with delayed SYSTEM safety net'
    )
    Suspend-BitLockerForReboot
    $shutdownComment = 'Boot Update Cycle: Applying updates (forced reboot).'
    Write-Log "Initiating forced shutdown /g /f /t $($script:RebootDelaySec) (ARSO where supported)"
    if ($PSCmdlet.ShouldProcess('Windows', 'Restart computer')) {
        & shutdown.exe /g /f /t $script:RebootDelaySec /c "$shutdownComment" /d p:2:17
        if ($LASTEXITCODE -ne 0) {
            $State.Phase = 'RetryPending'
            Set-BootUpdateState -State $State
            $null = Register-BootUpdateTaskForReboot -RetrySoon
            Write-Log "shutdown.exe rejected the restart request (exit $LASTEXITCODE); automatic retry queued." -Level Error
            exit 1
        }
        Write-Log 'Shutdown scheduled. Exiting; will resume after reboot.'
        exit 0
    }
}
#endregion

#region Console Visuals
<# Console-only visual elements for progress monitoring.  These use Write-Host
   and do NOT go to the log file — the log stays clean and greppable.  #>

function Show-StartupArt {
    <# BBS-inspired splash. The wordmark uses native PowerShell background
       colors over plain spaces, avoiding Unicode glyph and ANSI/VT dependencies
       for older consoles such as Windows Server 2016 cmd.exe. #>

    function Write-CellRow {
        param([Parameter(Mandatory)][string]$Pattern)
        Write-Host '  ::' -NoNewline -ForegroundColor DarkGray
        Write-Host '   ' -NoNewline
        foreach ($ch in $Pattern.ToCharArray()) {
            switch ($ch) {
                'C' { Write-Host '  ' -NoNewline -BackgroundColor Cyan }
                'W' { Write-Host '  ' -NoNewline -BackgroundColor White }
                'M' { Write-Host '  ' -NoNewline -BackgroundColor Magenta }
                'B' { Write-Host '  ' -NoNewline -BackgroundColor Blue }
                default { Write-Host '  ' -NoNewline }
            }
        }
        Write-Host ''
    }

    Write-Host ""
    Write-Host '  .:' -NoNewline -ForegroundColor DarkGray
    Write-Host ('=' * 66) -NoNewline -ForegroundColor Cyan
    Write-Host ':.' -ForegroundColor DarkGray
    Write-Host '  :: ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'BOOT UPDATE CYCLE' -NoNewline -ForegroundColor Magenta
    Write-Host ' // ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'unattended patch board' -NoNewline -ForegroundColor White
    Write-Host ' // ' -NoNewline -ForegroundColor DarkGray
    Write-Host "v$($script:BootUpdateCycleVersion)" -ForegroundColor Yellow
    Write-Host '  ::' -ForegroundColor DarkGray

    <# 24-bit VT gradient wordmark where supported (Win10 1703+/Win11 conhost and
       Windows Terminal). Still spaces + background color only — no Unicode glyphs —
       so the cmd.exe glyph-drop failure mode from pre-2.5.6 cannot recur. Legacy
       consoles (Server 2016, no VT) fall back to the 16-color block wordmark. #>
    $vtOk = $false
    try {
        $vtOk = $Host.UI.SupportsVirtualTerminal -and ([System.Environment]::OSVersion.Version.Build -ge 15063)
    } catch { }

    <# Splash theme (0 = neon gradient [default], 1 = bright-rim outline with
       dithered fill, 2 = classic 16-color blocks). Override with
       BOOT_UPDATE_SPLASH_THEME=0|1|2. Non-VT consoles always get 2. #>
    $theme = 2
    if ($vtOk) {
        $theme = 0
        if ($env:BOOT_UPDATE_SPLASH_THEME -match '^[0-2]$') { $theme = [int]$env:BOOT_UPDATE_SPLASH_THEME }
    }

    if ($theme -le 1) {
        $e = [char]27
        <# Per-letter neon gradients (top-left -> bottom-right), echoing the demoscene
           palette: cyan B, magenta O, blue/violet O, acid-green T. #>
        $letters = @(
            @{ W = 7; From = @(80,255,230);  To = @(0,140,190);  Rows = @('#######','##...##','##...##','######.','##...##','##...##','##...##','#######') }
            @{ W = 7; From = @(255,90,205);  To = @(175,0,115);  Rows = @('.#####.','##...##','##...##','##...##','##...##','##...##','##...##','.#####.') }
            @{ W = 7; From = @(95,115,255);  To = @(155,60,255); Rows = @('.#####.','##...##','##...##','##...##','##...##','##...##','##...##','.#####.') }
            @{ W = 7; From = @(75,255,145);  To = @(190,255,70); Rows = @('#######','#######','..###..','..###..','..###..','..###..','..###..','..###..') }
        )
        <# Glitch-confetti gutter cell: deterministic sparse colored cells flanking
           the wordmark (demoscene side-column noise). Returns a 2-char cell. #>
        $confetti = {
            param([int]$Seed)
            $h = $Seed % 11
            if ($h -lt (3 + $theme * 2)) {
                $c = $letters[$Seed % 4].To
                $dim = 0.22 + $h * 0.07
                "$e[48;2;$([int]($c[0]*$dim));$([int]($c[1]*$dim));$([int]($c[2]*$dim))m  $e[0m"
            } else { '  ' }
        }

        for ($row = 0; $row -lt 8; $row++) {
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.Append("$e[90m  ::$e[0m ")
            [void]$sb.Append((& $confetti ($row * 53 + 7))).Append((& $confetti ($row * 31 + 2))).Append(' ')
            for ($li = 0; $li -lt $letters.Count; $li++) {
                $L = $letters[$li]
                $bits = $L.Rows[$row]
                for ($col = 0; $col -lt $L.W; $col++) {
                    if ($bits[$col] -eq '#') {
                        if ($theme -eq 0) {
                            <# Neon: diagonal gradient + CRT scanline (odd rows dimmer) + dither + bevel #>
                            $t = ($row / 7.0) * 0.72 + ($col / [double]($L.W - 1)) * 0.28
                            $shade = if ($row % 2 -eq 1) { 0.78 } else { 1.0 }
                            $shade *= 1.0 + ((($row * 31 + $col * 17 + $li * 7) % 7) - 3) * 0.02
                            if ($row -eq 0 -or $L.Rows[$row - 1][$col] -ne '#') { $shade *= 1.25 }
                            elseif ($row -eq 7 -or $L.Rows[$row + 1][$col] -ne '#') { $shade *= 0.55 }
                            $rgb = for ($k = 0; $k -lt 3; $k++) {
                                [int][Math]::Max(0, [Math]::Min(255, ($L.From[$k] + ($L.To[$k] - $L.From[$k]) * $t) * $shade))
                            }
                        } else {
                            <# Outline: full-brightness rim around every edge (including
                               counter holes), dark checkerboard-dithered interior #>
                            $edge = ($row -eq 0 -or $L.Rows[$row - 1][$col] -ne '#') -or
                                    ($row -eq 7 -or $L.Rows[$row + 1][$col] -ne '#') -or
                                    ($col -eq 0 -or $bits[$col - 1] -ne '#') -or
                                    ($col -eq ($L.W - 1) -or $bits[$col + 1] -ne '#')
                            if ($edge) {
                                $rgb = $L.From
                            } else {
                                $dim = if ((($row + $col) % 2) -eq 0) { 0.42 } else { 0.26 }
                                $rgb = for ($k = 0; $k -lt 3; $k++) { [int]($L.To[$k] * $dim) }
                            }
                        }
                        [void]$sb.Append("$e[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m  ")
                    } else {
                        [void]$sb.Append("$e[0m  ")
                    }
                }
                [void]$sb.Append("$e[0m  ")
            }
            [void]$sb.Append((& $confetti ($row * 47 + 5))).Append((& $confetti ($row * 29 + 11)))
            [void]$sb.Append("$e[0m")
            Write-Host $sb.ToString()
        }
        <# Phosphor reflection: dim echo of each letter's bottom row #>
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("$e[90m  ::$e[0m      ")
        for ($li = 0; $li -lt $letters.Count; $li++) {
            $L = $letters[$li]
            $bits = $L.Rows[7]
            for ($col = 0; $col -lt $L.W; $col++) {
                if ($bits[$col] -eq '#') {
                    $rgb = for ($k = 0; $k -lt 3; $k++) { [int]($L.To[$k] * 0.16) }
                    [void]$sb.Append("$e[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m  ")
                } else {
                    [void]$sb.Append("$e[0m  ")
                }
            }
            [void]$sb.Append("$e[0m  ")
        }
        [void]$sb.Append("$e[0m")
        Write-Host $sb.ToString()
    } else {
        Write-CellRow 'CCCC..MMMM..MMMM..WWWWW'
        Write-CellRow 'CBBCC.MBBBM.MBBBM...W..'
        Write-CellRow 'CBBCC.MBBBM.MBBBM...W..'
        Write-CellRow 'CCCC..MBBBM.MBBBM...W..'
        Write-CellRow 'CBBCC.MBBBM.MBBBM...W..'
        Write-CellRow 'CBBCC.MBBBM.MBBBM...W..'
        Write-CellRow 'CCCC..MMMM..MMMM....W..'
    }
    Write-Host '  ::' -ForegroundColor DarkGray
    Write-Host '  :: ' -NoNewline -ForegroundColor DarkGray
    Write-Host '[sysop]' -NoNewline -ForegroundColor Green
    Write-Host ' update cycle   ' -NoNewline -ForegroundColor White
    Write-Host '[carrier]' -NoNewline -ForegroundColor Green
    Write-Host ' updates you can sleep through' -ForegroundColor Magenta
    Write-Host '  :: ' -NoNewline -ForegroundColor DarkGray
    Write-Host '[board]' -NoNewline -ForegroundColor Green
    Write-Host ' nanoDBA/boot-upd' -NoNewline -ForegroundColor Cyan
    Write-Host '        [motd]' -NoNewline -ForegroundColor Green
    Write-Host ' run upd as admin, walk away' -ForegroundColor White
    Write-Host '  :: ' -NoNewline -ForegroundColor DarkGray
    Write-Host '[log]' -NoNewline -ForegroundColor Green
    Write-Host "   $($script:LogPath)" -ForegroundColor DarkCyan
    Write-Host "  '::" -NoNewline -ForegroundColor DarkGray
    Write-Host ('=' * 66) -NoNewline -ForegroundColor Cyan
    Write-Host "::'" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-CycleStartStatus {
    param([string]$Verb, [string]$SessionId, [int]$Iteration, [int]$MaxIterations, [string]$Context, [string]$Window = '')
    if (-not (Test-BootUpdateOutputAtLeast -Minimum Normal)) { return }
    Write-Host '  [' -NoNewline -ForegroundColor DarkGray
    Write-Host $Verb -NoNewline -ForegroundColor Green
    Write-Host '] ' -NoNewline -ForegroundColor DarkGray
    Write-Host "Session: $SessionId " -NoNewline -ForegroundColor White
    Write-Host '| ' -NoNewline -ForegroundColor DarkGray
    Write-Host "Iteration: $Iteration/$MaxIterations " -NoNewline -ForegroundColor White
    Write-Host '| ' -NoNewline -ForegroundColor DarkGray
    Write-Host "Context: $Context" -ForegroundColor White
    if (-not [string]::IsNullOrWhiteSpace($Window)) {
        Write-Host '  [window] ' -NoNewline -ForegroundColor DarkCyan
        Write-Host $Window -ForegroundColor White
    }
    Write-Host ""
}

function Show-CycleBanner {
    param([string]$Title, [string]$AnsiColor, [string[]]$Info)
    $e = [char]27; $b = "$e[1m"; $d = "$e[2m"; $w = "$e[97m"; $r = "$e[0m"
    $len = 70
    Write-Host ""
    Write-Host "$AnsiColor$b  $('=' * $len)$r"
    Write-Host ""
    Write-Host "$AnsiColor$b    $w$Title$r"
    Write-Host ""
    if ($Info.Count -gt 0) {
        Write-Host "$AnsiColor  $('-' * $len)$r"
        foreach ($line in $Info) { Write-Host "$d    $line$r" }
        Write-Host ""
    }
    Write-Host "$AnsiColor$b  $('=' * $len)$r"
    Write-Host ""
}

function Write-PhaseHeader {
    param([int]$Num, [int]$Total, [string]$Name)
    $percent = if ($Total -gt 0) { [math]::Floor((($Num - 1) / $Total) * 100) } else { 0 }
    Write-BootUpdateProgress -Activity "Boot Update Cycle [$Num/$Total]" -Status "Running $Name" -PercentComplete $percent
    if (-not (Test-BootUpdateOutputAtLeast -Minimum Normal)) { return }
    Clear-BootUpdateProgressLine
    $e = [char]27; $c = "$e[36m"; $b = "$e[1m"; $w = "$e[97m"; $r = "$e[0m"
    $label = "[$Num/$Total] $Name"
    $pad = 66 - $label.Length; if ($pad -lt 3) { $pad = 3 }
    Write-Host ""
    Write-Host "$c$b  --- $w$label $c$('-' * $pad)$r"
}

function Write-PhaseResult {
    param([int]$Num, [int]$Total, [string]$Name, [bool]$Success, [double]$Minutes, [int]$Count = 0)
    $percent = if ($Total -gt 0) { [math]::Min(100, [math]::Floor(($Num / $Total) * 100)) } else { 100 }
    Write-BootUpdateProgress -Activity "Boot Update Cycle [$Num/$Total]" -Status "$Name complete" -PercentComplete $percent
    if ($Success -and -not (Test-BootUpdateOutputAtLeast -Minimum Normal)) { return }
    $e = [char]27; $g = "$e[32m"; $red = "$e[31m"; $r = "$e[0m"
    $countMsg = if ($Count -gt 0) { ", $Count pkg" } else { '' }
    $t = "$([math]::Round($Minutes, 1)) min"
    Clear-BootUpdateProgressLine
    if ($Success) {
        $message = ">>> [$Num/$Total] $Name done ($t$countMsg)"
        Write-Host "$g  $message$r"
    } else {
        $message = "!!! [$Num/$Total] $Name FAILED ($t)"
        Write-Host "$red  $message$r"
    }
}

function Write-PhaseSkip {
    param([string]$Name)
    Read-BootUpdateUiKeys
    if (-not (Test-BootUpdateOutputAtLeast -Minimum Verbose)) { return }
    Clear-BootUpdateProgressLine
    $e = [char]27; $d = "$e[2m"; $r = "$e[0m"
    Write-Host "$d    ~ $Name skipped$r"
}
#endregion

#region Extension Hooks
<#
    74r — Cycle-level hooks: -PreCycleScript / -PostCycleScript
    b3w — Per-phase hooks:   hooks.psd1 sidecar loaded into $script:PhaseHooks

    Hook scripts run in the SAME scope as the orchestrator so they can read $state and
    $script:* variables.  Mutations are possible but unsupported — treat as read-only.
    All hook failures are logged at Warn level; the cycle continues regardless.
#>

function Invoke-Hook {
    <#
    .SYNOPSIS
        Executes a cycle-level hook script (.ps1) with best-effort error handling.
    .PARAMETER Path
        Absolute or relative path to a .ps1 file.  Empty/null/whitespace = no-op.
    .PARAMETER HookName
        Friendly name used in log messages (e.g. 'PreCycle', 'PostCycle').
    #>
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$HookName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Hook [$HookName]: file not found at '$Path' — skipping." -Level Warn
        return
    }

    try {
        $trustedPath = Resolve-BootUpdateTrustedFile `
            -Path $Path -TrustRoot $PSScriptRoot -AllowedExtension @('.ps1')
        if (-not $trustedPath) {
            throw 'hook failed its path or ACL trust check'
        }
        Write-Log "Hook [$HookName]: executing '$trustedPath'"
        . $trustedPath
        Write-Log "Hook [$HookName]: completed."
    } catch {
        Write-Log "Hook [$HookName]: error during execution — $_" -Level Warn
    }
}

function Invoke-PhaseHook {
    <#
    .SYNOPSIS
        Fires a named per-phase hook scriptblock from $script:PhaseHooks with best-effort error handling.
    .PARAMETER EventName
        Key in $script:PhaseHooks hashtable, e.g. 'BeforeWinget', 'AfterChoco'.
    #>
    param([Parameter(Mandatory)][string]$EventName)

    if (-not $script:PhaseHooks.ContainsKey($EventName)) { return }
    $sb = $script:PhaseHooks[$EventName]
    if ($sb -isnot [scriptblock]) { return }

    try {
        Write-Log "PhaseHook [$EventName]: executing"
        & $sb
        Write-Log "PhaseHook [$EventName]: completed."
    } catch {
        Write-Log "PhaseHook [$EventName]: error — $_" -Level Warn
    }
}
#endregion

#region Fleet Management

<# Update-OrchestratorSelf (lz1)
   Downloads the latest Invoke-BootUpdateCycle.ps1 from the canonical GitHub release,
   validates it, and re-execs into the new version.  Only runs in user context (never
   SYSTEM).  Best-effort: all failure paths log and return — never throw. #>
function Get-OrchestratorFileVersion {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ($raw -match "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
            return [System.Version]::new($matches[1])
        }
    } catch { }
    return $null
}

function Test-SelfUpdateHandoff {
    <# The current updater keeps the mutex while it synchronously waits for its
       replacement. Only that replacement inherits this short-lived, nonced
       marker. Confirming the recorded PID is the replacement's actual pwsh
       parent prevents an unrelated invocation from bypassing the mutex. #>
    $markerName = 'BOOT_UPDATE_SELF_UPDATE_HANDOFF'
    $marker = [Environment]::GetEnvironmentVariable($markerName, 'Process')
    if ([string]::IsNullOrWhiteSpace($marker)) { return $false }

    <# Consume the capability before the update cycle starts so tools launched
       by the replacement cannot inherit and replay it. #>
    [Environment]::SetEnvironmentVariable($markerName, $null, 'Process')

    try {
        $parts = $marker.Split(':')
        if ($parts.Count -ne 3 -or $parts[0] -ne 'v1') { return $false }

        $expectedParentPid = 0
        if (-not [int]::TryParse($parts[1], [ref]$expectedParentPid) -or $expectedParentPid -le 0) {
            return $false
        }
        if ($parts[2] -notmatch '^[0-9a-f]{32}$') { return $false }

        $thisProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        if ([int]$thisProcess.ParentProcessId -ne $expectedParentPid) { return $false }

        $parentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$expectedParentPid" -ErrorAction Stop
        if ($parentProcess.Name -notin @('pwsh.exe', 'pwsh')) { return $false }
        return ($parentProcess.CommandLine -match '(?i)(Deploy|Invoke)-BootUpdateCycle\.ps1')
    } catch {
        return $false
    }
}

function Test-LegacySelfUpdateHandoff {
    <# Versions through 2.5.16 started the replacement synchronously while still
       owning the mutex. The child can safely inherit that handoff: its parent is
       blocked waiting for it, so no two update cycles execute concurrently.
       A freshly replaced live file plus an older .bak distinguishes that case
       from an ordinary second launch. #>
    $livePath = $PSCommandPath
    $bakPath = "$livePath.bak"
    if (-not (Test-Path -LiteralPath $bakPath)) { return $false }

    try {
        <# A genuine handoff child was spawned by the old pwsh process. A normal
           second upd launch runs inside its own pwsh whose parent is cmd.exe. #>
        $thisProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        $parentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($thisProcess.ParentProcessId)" -ErrorAction Stop
        if ($parentProcess.Name -notin @('pwsh.exe', 'pwsh')) { return $false }
        if ($parentProcess.CommandLine -notmatch '(?i)(Deploy|Invoke)-BootUpdateCycle\.ps1') { return $false }

        $liveItem = Get-Item -LiteralPath $livePath -ErrorAction Stop
        if ($liveItem.LastWriteTimeUtc -lt [datetime]::UtcNow.AddMinutes(-5)) { return $false }

        $liveVersion = Get-OrchestratorFileVersion -Path $livePath
        $bakVersion = Get-OrchestratorFileVersion -Path $bakPath
        return ($null -ne $liveVersion -and $null -ne $bakVersion -and $liveVersion -gt $bakVersion)
    } catch {
        return $false
    }
}

function Repair-OrchestratorSourceCopy {
    <# An old Deploy script can repeatedly copy an old Invoke script over the
       healed ProgramData copy. Repair launcher directories found on Machine
       PATH so the self-update survives the next upd invocation. #>
    param([Parameter(Mandatory)][System.Version]$VerifiedReleaseVersion)

    try {
        $liveVersion = Get-OrchestratorFileVersion -Path $PSCommandPath
        if ($null -eq $liveVersion -or $liveVersion -lt $VerifiedReleaseVersion) { return }

        $candidateDirs = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        if (-not [string]::IsNullOrWhiteSpace($env:BOOT_UPDATE_SOURCE_DIR)) {
            $null = $candidateDirs.Add($env:BOOT_UPDATE_SOURCE_DIR)
        }
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        foreach ($entry in ($machinePath -split ';')) {
            $trimmed = $entry.Trim().Trim('"')
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $null = $candidateDirs.Add($trimmed) }
        }

        foreach ($dir in $candidateDirs) {
            $sourceInvoke = Join-Path $dir 'Invoke-BootUpdateCycle.ps1'
            $sourceLauncher = Join-Path $dir 'upd.cmd'
            if (-not (Test-Path -LiteralPath $sourceInvoke) -or -not (Test-Path -LiteralPath $sourceLauncher)) { continue }
            if ([System.IO.Path]::GetFullPath($sourceInvoke) -eq [System.IO.Path]::GetFullPath($PSCommandPath)) { continue }

            $sourceVersion = Get-OrchestratorFileVersion -Path $sourceInvoke
            if ($null -ne $sourceVersion -and $sourceVersion -ge $liveVersion) { continue }

            Copy-Item -LiteralPath $sourceInvoke -Destination "$sourceInvoke.bak" -Force -ErrorAction Stop
            Copy-Item -LiteralPath $PSCommandPath -Destination $sourceInvoke -Force -ErrorAction Stop
            $oldVersion = if ($null -eq $sourceVersion) { 'unknown' } else { $sourceVersion.ToString() }
            Write-Log "Self-update: repaired launcher source copy ($oldVersion -> $liveVersion): $sourceInvoke" -Level Info
        }
    } catch {
        Write-Log "Self-update: source-copy repair skipped — $_" -Level Warn
    }
}
function Update-OrchestratorSelf {
    param(
        <# Script-level $PSBoundParameters must be forwarded explicitly so the re-launch
           can reproduce the caller's explicit switches/values across the process boundary. #>
        [hashtable]$ScriptBoundParams = @{}
    )
    try {
        <# Guard: never self-update under SYSTEM scheduled task context #>
        $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
        if ($isSystem) {
            Write-Log 'Self-update: skipped in SYSTEM context.' -Level Info
            return
        }

        <# Guard: env-var escape hatch for test environments #>
        if (-not [string]::IsNullOrEmpty($env:BOOT_UPDATE_NO_SELF_UPDATE)) {
            Write-Log 'Self-update: disabled via BOOT_UPDATE_NO_SELF_UPDATE env var.' -Level Info
            return
        }

        <# Guard: explicit -DisableSelfUpdate switch #>
        if ($script:DisableSelfUpdate) {
            Write-Log 'Self-update: disabled via -DisableSelfUpdate switch.' -Level Info
            return
        }

        Write-Log 'Self-update: checking for newer release on GitHub...' -Level Info

        $releaseInfo = $null
        try {
            $releaseInfo = Invoke-RestMethod `
                -Uri 'https://api.github.com/repos/nanoDBA/boot-upd/releases/latest' `
                -TimeoutSec 15 `
                -Headers @{ 'User-Agent' = 'BootUpdateCycle' } `
                -ErrorAction Stop
        } catch {
            Write-Log "Self-update: could not reach GitHub releases API — $_" -Level Warn
            return
        }

        $tagName = $releaseInfo.tag_name -replace '^v', ''
        if ([string]::IsNullOrWhiteSpace($tagName)) {
            Write-Log 'Self-update: could not parse tag_name from release response.' -Level Warn
            return
        }

        <# Compare semver: if remote <= current, nothing to do #>
        $current = $script:BootUpdateCycleVersion
        try {
            $remoteVer  = [System.Version]::new($tagName)
            $currentVer = [System.Version]::new($current)
        } catch {
            Write-Log "Self-update: version parse failed (remote='$tagName', current='$current') — $_" -Level Warn
            return
        }

        if ($remoteVer -le $currentVer) {
            Write-Log "Self-update: already on latest ($current)." -Level Info
            Repair-OrchestratorSourceCopy -VerifiedReleaseVersion $remoteVer
            return
        }

        Write-Log "Self-update: newer release found — $current -> $tagName. Downloading..." -Level Info

        <# Locate the Invoke-BootUpdateCycle.ps1 asset in the release #>
        $asset = $releaseInfo.assets | Where-Object { $_.name -eq 'Invoke-BootUpdateCycle.ps1' } | Select-Object -First 1
        if (-not $asset) {
            Write-Log "Self-update: release $tagName has no 'Invoke-BootUpdateCycle.ps1' asset. Skipping." -Level Warn
            return
        }

        <# Look for a sibling SHA256 asset or a SHA256 hex in the release body #>
        $expectedSha = $null
        $shaAsset = $releaseInfo.assets | Where-Object { $_.name -eq 'Invoke-BootUpdateCycle.ps1.sha256' } | Select-Object -First 1
        if ($shaAsset) {
            try {
                $shaContent = Invoke-RestMethod -Uri $shaAsset.browser_download_url -TimeoutSec 15 -Headers @{ 'User-Agent' = 'BootUpdateCycle' } -ErrorAction Stop
                $expectedSha = ($shaContent -split '\s+')[0].Trim().ToUpperInvariant()
            } catch {
                Write-Log "Self-update: failed to fetch .sha256 asset — $_" -Level Warn
            }
        }

        if ($expectedSha -notmatch '^[0-9A-F]{64}$') { $expectedSha = $null }

        if (-not $expectedSha -and -not [string]::IsNullOrWhiteSpace($releaseInfo.body)) {
            <# Try to find a SHA256 hex near the asset filename in the release body #>
            if ($releaseInfo.body -match '(?i)Invoke-BootUpdateCycle\.ps1[^\n]*?([0-9a-fA-F]{64})') {
                $expectedSha = $matches[1].ToUpperInvariant()
            } elseif ($releaseInfo.body -match '([0-9a-fA-F]{64})') {
                $expectedSha = $matches[1].ToUpperInvariant()
            }
        }

        if ($expectedSha -notmatch '^[0-9A-F]{64}$') {
            Write-Log 'Self-update: release provides no valid SHA256; refusing unverified update.' -Level Error
            return
        }

        <# Download to temp file #>
        $tempPath = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
        try {
            Invoke-WebRequest `
                -Uri $asset.browser_download_url `
                -OutFile $tempPath `
                -TimeoutSec 60 `
                -Headers @{ 'User-Agent' = 'BootUpdateCycle' } `
                -ErrorAction Stop
        } catch {
            Write-Log "Self-update: download failed — $_" -Level Warn
            if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
            return
        }

        <# Validate: must parse as valid PowerShell #>
        try {
            $null = [scriptblock]::Create((Get-Content $tempPath -Raw -ErrorAction Stop))
        } catch {
            Write-Log "Self-update: downloaded script failed PowerShell parse check — $_. Aborting update." -Level Error
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
            return
        }

        <# SHA256 verification is mandatory before replacing elevated code. #>
        $actualSha = (Get-FileHash -Path $tempPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualSha -ne $expectedSha) {
            Write-Log "Self-update: SHA256 mismatch! Expected=$expectedSha Actual=$actualSha. Aborting update." -Level Error
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
            return
        }
        Write-Log "Self-update: SHA256 verified ($actualSha)." -Level Info

        <# Atomic replace: backup then move #>
        $livePath = $PSCommandPath   # The running script file
        $bakPath  = "$livePath.bak"
        try {
            Copy-Item -Path $livePath -Destination $bakPath -Force -ErrorAction Stop
            Move-Item -Path $tempPath -Destination $livePath -Force -ErrorAction Stop
        } catch {
            Write-Log "Self-update: atomic replace failed — $_" -Level Error
            if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
            return
        }

        Write-Log "Self-update: successfully updated to $tagName. Re-executing new version..." -Level Info

        <# Re-exec: build argument list, preserving caller's explicit params #>
        $relaunchArgs = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $ScriptBoundParams.GetEnumerator()) {
            if ($p.Value -is [switch]) {
                if ($p.Value.IsPresent) { $relaunchArgs.Add("-$($p.Key)") }
            } elseif ($p.Value -is [string[]]) {
                foreach ($v in $p.Value) { $relaunchArgs.Add("-$($p.Key)"); $relaunchArgs.Add($v) }
            } elseif ($p.Value -is [pscredential]) {
                <# Cannot pass credential over process boundary — skip; caller must re-supply if needed #>
                Write-Log 'Self-update: -SmtpCredential cannot be forwarded to re-launched process.' -Level Warn
            } elseif ($p.Key -eq 'WebhookUrl') {
                <# Persisted in the ACL-protected ProgramData secret; never expose it in child argv. #>
                continue
            } else {
                $relaunchArgs.Add("-$($p.Key)")
                $relaunchArgs.Add("$($p.Value)")
            }
        }

        <# Keep the mutex continuously held while the replacement runs. The
           process-only capability is inherited by this child but not by a
           concurrently scheduled/manual invocation. #>
        $handoffName = 'BOOT_UPDATE_SELF_UPDATE_HANDOFF'
        $previousHandoff = [Environment]::GetEnvironmentVariable($handoffName, 'Process')
        $handoffMarker = "v1:${PID}:$([guid]::NewGuid().ToString('N'))"
        try {
            [Environment]::SetEnvironmentVariable($handoffName, $handoffMarker, 'Process')
            & pwsh -NoProfile -File $livePath @relaunchArgs
            $replacementExitCode = $LASTEXITCODE
        } finally {
            [Environment]::SetEnvironmentVariable($handoffName, $previousHandoff, 'Process')
        }
        exit $replacementExitCode

    } catch {
        Write-Log "Self-update: unexpected error — $_" -Level Warn
    }
}

<# Get-RemoteConfig (jzw)
   Fetches a JSON config from $script:ConfigUrl and returns a PSCustomObject whose
   top-level keys override local defaults for any param NOT explicitly supplied by the
   user.  Falls back to the last-cached response on network failure.
   Returns $null when ConfigUrl is empty or on unrecoverable failure. #>
function Get-RemoteConfig {
    $url = $script:ConfigUrl
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }

    $cacheDir  = Join-Path $env:ProgramData 'BootUpdateCycle'
    $cachePath = Join-Path $cacheDir 'remote-config.cache.json'

    $parsed = $null
    try {
        $response = Invoke-RestMethod `
            -Uri $url `
            -TimeoutSec 10 `
            -Headers @{ 'User-Agent' = 'BootUpdateCycle' } `
            -ErrorAction Stop

        if ($response -isnot [pscustomobject] -and $response -isnot [hashtable]) {
            Write-Log "Remote config: response from '$url' is not a JSON object. Ignoring." -Level Warn
            $parsed = $null
        } else {
            $parsed = $response
            <# Cache successful response #>
            try {
                if (-not (Test-Path $cacheDir)) { $null = New-Item -ItemType Directory -Path $cacheDir -Force }
                $parsed | ConvertTo-Json -Depth 5 | Set-Content -Path $cachePath -Encoding UTF8 -Force
            } catch {
                Write-Log "Remote config: failed to cache response — $_" -Level Warn
            }
        }
    } catch {
        Write-Log "Remote config: fetch from '$url' failed — $_" -Level Warn

        <# Fallback: use last-known cached config #>
        if (Test-Path $cachePath) {
            try {
                $cached = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                Write-Log 'Remote config: using last-known cached config.' -Level Warn
                $parsed = $cached
            } catch {
                Write-Log "Remote config: cache exists but failed to parse — $_" -Level Warn
                return $null
            }
        } else {
            Write-Log 'Remote config: no cache available. Proceeding with local defaults.' -Level Warn
            return $null
        }
    }

    return $parsed
}

<# Apply-RemoteConfig
   Walks top-level keys of $RemoteConfig and overwrites $script:<key> for any key
   that was NOT explicitly passed by the user on the command line.
   $UserBoundParams must be the script-level $PSBoundParameters hashtable.
   Supported keys mirror the boolean/int/string params documented in CLAUDE.md. #>
function Apply-RemoteConfig {
    param(
        [pscustomobject]$RemoteConfig,
        [hashtable]$UserBoundParams = @{}
    )
    if ($null -eq $RemoteConfig) { return }

    $supportedKeys = @(
        'ExcludePatterns', 'IncludePatterns', 'NotificationLevel',
        'MaxIterations', 'RebootDelaySec', 'PackageTimeoutMinutes',
        'MaintenanceWindowStart', 'MaintenanceWindowEnd',
        'SkipPip', 'SkipNpm', 'SkipScoop', 'SkipDotnetTools', 'SkipVscode',
        'SkipPowerShellModules', 'SkipOffice365', 'SkipAwsTooling',
        'SkipDefender', 'SkipBitLocker', 'SkipRestorePoint', 'SkipHealthCheck',
        'IncludeDriverUpdates', 'IncludeFirmwareUpdates',
        'UpdateWsl', 'UpdateContainers', 'AllowMetered', 'DisableSelfUpdate',
        'StagedRollout', 'OutputMode'
    )

    $overridden = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $supportedKeys) {
        <# User always wins — skip any key the caller passed explicitly #>
        if ($UserBoundParams.ContainsKey($key)) { continue }

        $remoteProps = $RemoteConfig.PSObject.Properties.Name
        if ($remoteProps -notcontains $key) { continue }

        $remoteVal = $RemoteConfig.$key
        if ($null -eq $remoteVal) { continue }
        if ($key -eq 'OutputMode' -and $remoteVal -notin $script:OutputModes) {
            Write-Log "Remote config: invalid OutputMode '$remoteVal' ignored." -Level Warn
            continue
        }

        try {
            Set-Variable -Name $key -Value $remoteVal -Scope Script -Force -ErrorAction Stop
            $overridden.Add($key)
        } catch {
            Write-Log "Remote config: could not apply key '$key' — $_" -Level Warn
        }
    }

    if ($overridden.Count -gt 0) {
        Write-Log "Remote config: overrode $($overridden.Count) setting(s): $($overridden -join ', ')." -Level Info
    } else {
        Write-Log 'Remote config: no local settings overridden (all already set by user or key absent).' -Level Info
    }
}
#endregion

#region Main Orchestration
function Invoke-BootUpdateCycle {
    Invoke-LogRotation

    $state = Get-BootUpdateState
    $isFirstIteration = -not $state.StartTime
    if ($isFirstIteration) { $state.StartTime = Get-Date -Format 'o' }
    $currentBootSessionId = Get-BootUpdateBootSessionId
    $priorBootSessionId = $state.LastBootSessionId
    $state = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId $currentBootSessionId
    if ($priorBootSessionId -and $priorBootSessionId -ne $currentBootSessionId) { Write-Log "Observed a new Windows boot session; completed reboot count is now $($state.RebootCount)." -Visibility Verbose }
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($currentIdentity.User.Value -ne 'S-1-5-18') { $state.ResumeUser = $currentIdentity.Name }
    elseif (-not $state.ResumeUser) {
        try { $state.ResumeUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
        if (-not $state.ResumeUser) {
            try { $state.ResumeUser = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -Name LastLoggedOnSAMUser -ErrorAction Stop).LastLoggedOnSAMUser } catch { }
        }
    }
    $script:ResumeUser = $state.ResumeUser
    $script:CurrentState = $state
    $script:ExplicitRebootRequests.Clear()
    foreach ($request in @($state.ExplicitRebootRequests)) { $script:ExplicitRebootRequests.Add($request) }
    Set-BootUpdateState -State $state
    $pendingIteration = $state.Iteration + 1

    $sessionId = ([datetime]$state.StartTime).ToString('yyyy-MM-dd HH:mm:ss')
    $cycleVerb = if ($isFirstIteration) { 'STARTED' } else { 'RESUMED (after reboot)' }
    $context = if (([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -eq 'S-1-5-18') { 'SYSTEM (scheduled task)' } else { "$env:USERNAME (user context)" }

    <# Console: BBS splash on every run.  Entry-point may have already shown it before
       self-update chatter; honor that flag and clear it so post-reboot resumes still splash. #>
    if (-not $script:_splashShown -and (Test-BootUpdateOutputAtLeast -Minimum Normal)) { Show-StartupArt }
    $script:_splashShown = $false
    $statusVerb = if ($WhatIfPreference) { "$cycleVerb [WHATIF]" } else { $cycleVerb }
    $windowText = ''
    if ($script:MaintenanceWindowStart -ge 0) {
        $windowText = "$($script:MaintenanceWindowStart):00 - $($script:MaintenanceWindowEnd):00"
    }
    Show-CycleStartStatus -Verb $statusVerb -SessionId $sessionId -Iteration $pendingIteration -MaxIterations $MaxIterations -Context $context -Window $windowText
    if ($script:TuiInteractive -and (Test-BootUpdateOutputAtLeast -Minimum Normal)) {
        Write-Host "  [view] $($script:OutputMode) | press v to cycle Quiet > Normal > Verbose > Debug" -ForegroundColor DarkCyan
    }
    <# Log file: clean greppable entry #>
    $whatIfTag = if ($WhatIfPreference) { ' [WHATIF]' } else { '' }
    Write-Log "BOOT UPDATE CYCLE$whatIfTag $cycleVerb | Session: $sessionId | Iteration: $pendingIteration/$MaxIterations | Context: $context"
    if ($script:MaintenanceWindowStart -ge 0) { Write-Log "Maintenance window: $($script:MaintenanceWindowStart):00 - $($script:MaintenanceWindowEnd):00" -Level Info }

    <# Event Log: cycle started #>
    Write-EventLogEntry -EventId 1002 -Message "Boot Update Cycle $cycleVerb`nSession: $sessionId`nIteration: $pendingIteration of $MaxIterations"

    <# Maintenance window gate — exit clean (task survives) if outside configured window #>
    if (-not (Test-MaintenanceWindow)) {
        $nextWindow = Get-NextMaintenanceWindowStart
        if (-not $WhatIfPreference) { $null = Register-BootUpdateTaskForReboot -RetryAt $nextWindow }
        Write-Log "Outside maintenance window ($($script:MaintenanceWindowStart):00 - $($script:MaintenanceWindowEnd):00). Deferred until $($nextWindow.ToString('yyyy-MM-dd HH:mm'))." -Level Warn
        exit 0
    }

    <# Pre-flight checks (every iteration — disk/network can change between reboots) #>
    $preflight = Test-PreFlightChecks -Force:$Force -State $state
    if (-not $preflight.CanProceed) {
        Write-Log 'Update cycle aborted by pre-flight checks.' -Level Error
        Write-EventLogEntry -EventId 1003 -EntryType Error -Message "Cycle aborted by pre-flight checks.`nErrors: $($preflight.Errors -join '; ')"
        if (-not $WhatIfPreference -and $isFirstIteration) {
            Unregister-BootUpdateTask
            Clear-BootUpdateState
        } elseif (-not $WhatIfPreference) {
            $null = Register-BootUpdateTaskForReboot -RetrySoon
            Write-Log 'Resume checkpoint preserved; a fresh two-minute retry and the boot/logon triggers are armed.' -Level Warn
        }
        exit 1
    }

    <# Only a run which passed pre-flight consumes an iteration. A slow network or
       service during boot can therefore use Task Scheduler retries without burning
       through the reboot-loop safety valve. #>
    $waitingForIdentity = $state.Phase -eq 'UserContextPending' -and
        $currentIdentity.User.Value -eq 'S-1-5-18' -and
        [string]::IsNullOrWhiteSpace([string]$state.ResumeUser)
    if (-not $waitingForIdentity) { $state.Iteration++ }
    else { Write-Log 'User identity discovery retry does not consume a mutation iteration.' -Level Warn }
    Set-BootUpdateState -State $state

    <# Max iterations safety valve — PostCycle fires here so callers get a final callback even on cap-exceeded exit #>
    if ($state.Iteration -gt $MaxIterations) {
        Write-Log "Max iterations ($MaxIterations) exceeded. Stopping." -Level Error
        Write-EventLogEntry -EventId 1003 -EntryType Error -Message "Cycle stopped: exceeded $MaxIterations iterations.`nSession: $sessionId"
        Send-CompletionNotification -Kind Error -Title 'Boot Update Cycle STOPPED' -Message "Exceeded $MaxIterations iterations with reboots still pending. Check $($script:LogPath) — a stale reboot signal is the usual cause."
        Invoke-Hook -Path $script:PostCycleScript -HookName 'PostCycle'
        if (-not $WhatIfPreference) { Unregister-BootUpdateTask; Clear-BootUpdateState }
        return
    }

    <# Arm the checkpoint before the first mutating phase, not merely after detecting
       a reboot. Native exit 1641 means an installer has already initiated restart;
       pre-registration is what makes that surprise reboot resumable. Completion
       removes both tasks, and the mutex prevents a scheduled collision. #>
    if (-not $WhatIfPreference) {
        $null = Register-BootUpdateTaskForReboot
        Write-Log 'Resume checkpoint armed before update phases.' -Visibility Verbose
    }

    <# A pending reboot is a phase barrier. Do not feed MSI/CBS/package work into a
       machine which already needs to finish servicing from an earlier transaction. #>
    <# Use the same settle-and-recheck detector as final verification. Servicing flags
       can appear shortly after boot, so a single clean probe is not a safe mutation gate. #>
    $pending = @(Get-ConfirmedPendingReboot)
    if ($pending.Count -gt 0) {
        $pending | ForEach-Object { Write-Log "Pending reboot before mutation: $($_.Source) — $($_.Detail)" -Level Warn }
        if (-not $WhatIfPreference) {
            $state.LastRebootSignals = (($pending.Source | Sort-Object) -join ',')
            foreach ($flag in @('WingetDone','ChocolateyDone','WindowsUpdateDone','AwsToolingDone','PipDone','NpmDone','Office365Done','PowerShellModulesDone','ScoopDone','DotnetToolsDone','VscodeDone','DefenderDone','DriverFirmwareDone','WslDone','ContainersDone')) { $state.$flag = $false }
            $state.Phase = 'Rebooting'
            $state.LastPreflightNetworkAt = $null; $state.LastPreflightNetworkOk = $null
            Set-BootUpdateState -State $state
            Start-BootUpdateRestart -State $state -Reason 'A reboot was already pending before update phases began.'
        }
    } else { Write-Log 'No pending reboots at start of iteration' }

    <# Crash recovery #>
    $null = Test-CrashRecovery -State $state

    <# PreCycle hook — runs after pre-flight passes and max-iterations check, before the first phase.
       Not called on aborted paths (metered/pre-flight abort) or mutex-collision exits. #>
    Invoke-Hook -Path $script:PreCycleScript -HookName 'PreCycle'

    <# ── Windows Update prefetch (2uj): scan + DOWNLOAD in a background child process
       while Winget/Chocolatey run. Downloads ride BITS — no msiexec/CBS contention.
       The INSTALL step stays in the sequential chain; Install-WindowsUpdates collects
       this job before installing. Skipped when: staged rollout (WU may not run this
       boot), WhatIf, WU already done, or PSWindowsUpdate not yet installed (the module
       install belongs to the WU phase — no racing it from here). #>
    $script:WuPrefetchJob = $null
    if (-not $script:StagedRollout -and -not $WhatIfPreference -and -not $state.WindowsUpdateDone -and (Get-Module -ListAvailable PSWindowsUpdate)) {
        try {
            $prefetchNotTitle = ((@('SQL') + ($script:ExcludePatterns | ForEach-Object { [regex]::Escape($_) })) -join '|')
            $script:WuPrefetchJob = Start-Job -ScriptBlock {
                param($NotTitle)
                Import-Module PSWindowsUpdate -Force
                Get-WindowsUpdate -AcceptAll -Download -NotTitle $NotTitle `
                    -RootCategories @('Security Updates','Critical Updates','Definition Updates') `
                    -IgnoreReboot -Confirm:$false 2>&1 | ForEach-Object { $_.ToString() }
            } -ArgumentList $prefetchNotTitle
            Write-Log 'Windows Update prefetch: scan + download started in background (install stays sequential).'
        } catch {
            Write-Log "Windows Update prefetch failed to start (non-fatal): $_" -Level Warn
            $script:WuPrefetchJob = $null
        }
    }

    <# System restore point — first iteration only; skipped on SYSTEM, Server SKUs, -SkipRestorePoint, or WhatIf #>
    if ($isFirstIteration) {
        $null = New-SystemRestorePoint
    }

    <# ---- Phase counter for progress display ---- #>
    <# Sequential phases: must run one at a time — Winget/Chocolatey/WindowsUpdate/
       DriverFirmware/AwsTooling all contend for the msiexec mutex or CBS/TrustedInstaller;
       Wsl/Containers stay sequential out of caution (opt-in, network/VM heavy).
       Parallel cohort (below): everything with no shared installer locks. #>
    $isSystemCtx = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    $allPhases = @(
        @{ Name='Winget';            Flag='WingetDone';            Key='Winget';            Skip=$false; Defer=$false; UserCompletionDeferred=$isSystemCtx;                  Action={ Update-WingetPackages } }
        @{ Name='Chocolatey';        Flag='ChocolateyDone';        Key='Chocolatey';        Skip=$false;                                                                       Action={ Update-ChocolateyPackages } }
        @{ Name='WindowsUpdate';     Flag='WindowsUpdateDone';     Key='WindowsUpdate';     Skip=$false;                                                                       Action={ Install-WindowsUpdates } }
        @{ Name='DriverFirmware';    Flag='DriverFirmwareDone';    Key='DriverFirmware';    Skip=(-not ($IncludeDriverUpdates -or $IncludeFirmwareUpdates));                    Action={ Install-DriverFirmwareUpdates } }
        @{ Name='AwsTooling';        Flag='AwsToolingDone';        Key=$null;               Skip=[bool]$SkipAwsTooling;                                                        Action={ $r = Repair-AwsTooling; @{ Success = $r; Count = 0 } } }
        @{ Name='Wsl';               Flag='WslDone';               Key='Wsl';               Skip=(-not $UpdateWsl); Defer=$isSystemCtx; UserCompletionDeferred=$isSystemCtx; Action={ Update-WslKernelAndDistros } }
        @{ Name='Containers';        Flag='ContainersDone';        Key='Containers';        Skip=(-not $UpdateContainers); Defer=$isSystemCtx; UserCompletionDeferred=$isSystemCtx; Action={ Update-ContainerImages } }
    )

    <# Parallel cohort: pip / npm / scoop / dotnet-tools / vscode / defender / office365 /
       powershell-modules — independent, no shared installer locks (no msiexec, no CBS):
       Defender uses MpCmdRun.exe, Office365 uses the ClickToRun service, PS modules are
       PSGallery file copies. Each entry includes an Action for staged-rollout compatibility
       (single-phase sequential execution uses the original function on the parent thread).
       SYSTEM-context skips (Scoop, Vscode) are checked both here (Skip flag) and inside each Action. #>
    $parallelCohort = @(
        @{ Name='Pip';               Flag='PipDone';               Key='Pip';               Skip=[bool]$SkipPip;                              Action={ Update-PipPackages } }
        @{ Name='Npm';               Flag='NpmDone';               Key='Npm';               Skip=[bool]$SkipNpm;                              Action={ Update-NpmPackages } }
        @{ Name='Scoop';             Flag='ScoopDone';             Key='Scoop';             Skip=[bool]$SkipScoop; Defer=$isSystemCtx; UserCompletionDeferred=$isSystemCtx; Action={ Update-ScoopPackages } }
        @{ Name='DotnetTools';       Flag='DotnetToolsDone';       Key='DotnetTools';       Skip=[bool]$SkipDotnetTools;                      Action={ Update-DotnetTools } }
        @{ Name='Vscode';            Flag='VscodeDone';            Key='Vscode';            Skip=[bool]$SkipVscode; Defer=$isSystemCtx; UserCompletionDeferred=$isSystemCtx; Action={ Update-VscodeExtensions } }
        @{ Name='Defender';          Flag='DefenderDone';          Key='Defender';          Skip=[bool]$SkipDefender;                         Action={ Update-DefenderSignatures } }
        @{ Name='Office365';         Flag='Office365Done';         Key='Office365';         Skip=[bool]$SkipOffice365;                        Action={ Update-Office365 } }
        @{ Name='PowerShellModules'; Flag='PowerShellModulesDone'; Key='PowerShellModules'; Skip=[bool]$SkipPowerShellModules;                Action={ Update-PowerShellModules } }
    )

    <# $allPhases + $parallelCohort combined — used for staged rollout and $enabledPhases count #>
    $allPhasesFlat = $allPhases + $parallelCohort
    $enabledPhases = @($allPhasesFlat | Where-Object { -not $_.Skip })
    $phaseNum = 0

    <# ---- Staged rollout: one phase per boot; or all phases in one boot (default) ---- #>
    if ($script:StagedRollout) {
        <# Staged mode: determine the single phase to run this boot.
           If StagedNextPhase points to a valid undone enabled phase, honour it.
           Otherwise find the first undone enabled phase (first boot or post-reboot reset). #>

        $targetPhase = $null

        if (-not [string]::IsNullOrWhiteSpace($state.StagedNextPhase)) {
            $candidate = $allPhasesFlat | Where-Object { $_.Name -eq $state.StagedNextPhase } | Select-Object -First 1
            if ($candidate -and (-not $candidate.Skip) -and (-not $candidate.Defer) -and (-not [bool]$state.($candidate.Flag))) {
                $targetPhase = $candidate
            }
        }

        if (-not $targetPhase) {
            $targetPhase = $allPhasesFlat | Where-Object { (-not $_.Skip) -and (-not $_.Defer) -and (-not [bool]$state.($_.Flag)) } | Select-Object -First 1
        }

        if ($targetPhase) {
            $state.StagedNextPhase = $targetPhase.Name
            Set-BootUpdateState -State $state
            Write-Log "Staged rollout mode: running phase [$($state.StagedNextPhase)] only this iteration." -Level Info

            <# Compute display position within enabled phases #>
            $enabledPhaseNames = [System.Collections.Generic.List[string]]::new()
            foreach ($ep in $enabledPhases) { $enabledPhaseNames.Add($ep.Name) }
            $phaseNum = $enabledPhaseNames.IndexOf($targetPhase.Name) + 1
            if ($phaseNum -lt 1) { $phaseNum = 1 }

            Write-PhaseHeader -Num $phaseNum -Total $enabledPhases.Count -Name $targetPhase.Name
            Write-Log ">>> [$phaseNum/$($enabledPhases.Count)] $($targetPhase.Name) - STARTING"
            $phaseStart = Get-Date

            $state.LastPhaseStarted = $targetPhase.Name; $state.LastPhaseTimestamp = Get-Date -Format 'o'; $state.Phase = $targetPhase.Name
            Set-BootUpdateState -State $state

            try {
                if ($PSCmdlet.ShouldProcess($targetPhase.Name, "Run $($targetPhase.Name) updates")) {
                    $r = & $targetPhase.Action
                } else {
                    Write-Log "  [WHATIF] Would execute phase: $($targetPhase.Name)"
                    $r = @{ Success = $true; Count = 0 }
                }
                $phaseSucceeded = [bool]$r.Success -and (-not $targetPhase.UserCompletionDeferred)
                $state.($targetPhase.Flag) = $phaseSucceeded
                $phaseCount = if ($targetPhase.Key -and $r.Count) { $state.Summary.($targetPhase.Key) += $r.Count; $r.Count } else { 0 }
                $elapsed = (Get-Date) - $phaseStart

                Write-PhaseResult -Num $phaseNum -Total $enabledPhases.Count -Name $targetPhase.Name -Success $phaseSucceeded -Minutes $elapsed.TotalMinutes -Count $phaseCount
                $phaseLabel = if ($targetPhase.UserCompletionDeferred) { 'MACHINE PORTION DONE; USER PASS DEFERRED' } elseif ($phaseSucceeded) { 'DONE' } else { 'FAILED' }
                Write-Log "<<< [$phaseNum/$($enabledPhases.Count)] $($targetPhase.Name) - $phaseLabel ($([math]::Round($elapsed.TotalMinutes, 1)) min, $phaseCount pkg)" -Level $(if ($phaseSucceeded -or $targetPhase.UserCompletionDeferred) { 'Info' } else { 'Error' })
                if ($phaseSucceeded) { Write-EventLogEntry -EventId 1004 -Message "$($targetPhase.Name) complete: $phaseCount packages in $([math]::Round($elapsed.TotalMinutes,1)) min" }
            } catch {
                $elapsed = (Get-Date) - $phaseStart

                Write-PhaseResult -Num $phaseNum -Total $enabledPhases.Count -Name $targetPhase.Name -Success $false -Minutes $elapsed.TotalMinutes
                Write-Log "<<< [$phaseNum/$($enabledPhases.Count)] $($targetPhase.Name) - FAILED ($([math]::Round($elapsed.TotalMinutes, 1)) min)" -Level Error
                Write-Log "  Error: $_" -Level Error
                if ($_.Exception.StackTrace) { Write-Log "  Stack: $($_.Exception.StackTrace)" -Level Error }
                if ($_.Exception.InnerException) { Write-Log "  Inner: $($_.Exception.InnerException.Message)" -Level Error }
                Write-EventLogEntry -EventId 1003 -EntryType Error -Message "$($targetPhase.Name) failed: $_"
                $state.($targetPhase.Flag) = $false
            }
            Set-BootUpdateState -State $state
        } else {
            <# All enabled phases already done — fall through to reboot/completion decision #>
            Write-Log 'Staged rollout: all phases already complete for this cycle.' -Level Info
        }
    } else {
        <# Non-staged mode: sequential phases then parallel cohort (v2.0 flow preserved for sequential; cohort parallelized) #>
    }

    if (-not $script:StagedRollout) {
        <# ── Sequential phases (Winget, Chocolatey, WindowsUpdate, DriverFirmware, AwsTooling, Wsl, Containers) ── #>
        $rebootBarrierRaised = $false
        foreach ($phase in $allPhases) {
            if ($phase.Skip) {
                Write-PhaseSkip -Name $phase.Name
                Write-Log "  [SKIP] $($phase.Name) (disabled)"
                continue
            }
            if ($phase.Defer) {
                Write-PhaseSkip -Name $phase.Name
                Write-Log "  [DEFER] $($phase.Name) requires the saved interactive user context." -Level Warn
                continue
            }
            if ($state.($phase.Flag)) { $phaseNum++; continue }  <# Already done this iteration #>

            $phaseNum++

            <# Console: styled phase header #>
            Write-PhaseHeader -Num $phaseNum -Total $enabledPhases.Count -Name $phase.Name
            Write-Log ">>> [$phaseNum/$($enabledPhases.Count)] $($phase.Name) - STARTING"
            $phaseStart = Get-Date

            <# Crash-recovery markers: write intent before execution (skipped in WhatIf) #>
            $state.LastPhaseStarted = $phase.Name; $state.LastPhaseTimestamp = Get-Date -Format 'o'; $state.Phase = $phase.Name
            Set-BootUpdateState -State $state

            <# Per-phase hook — Before<Name> (b3w) #>
            Invoke-PhaseHook -EventName "Before$($phase.Name)"

            try {
                <# ShouldProcess guard: in WhatIf mode the phase Action is NOT invoked #>
                if ($PSCmdlet.ShouldProcess($phase.Name, "Run $($phase.Name) updates")) {
                    $r = & $phase.Action
                } else {
                    Write-Log "  [WHATIF] Would execute phase: $($phase.Name)"
                    $r = @{ Success = $true; Count = 0 }
                }
                $phaseSucceeded = [bool]$r.Success -and (-not $phase.UserCompletionDeferred)
                $state.($phase.Flag) = $phaseSucceeded
                $phaseCount = if ($phase.Key -and $r.Count) { $state.Summary.($phase.Key) += $r.Count; $r.Count } else { 0 }
                $elapsed = (Get-Date) - $phaseStart

                <# Console: styled result #>
                Write-PhaseResult -Num $phaseNum -Total $enabledPhases.Count -Name $phase.Name -Success $phaseSucceeded -Minutes $elapsed.TotalMinutes -Count $phaseCount
                $phaseLabel = if ($phase.UserCompletionDeferred) { 'MACHINE PORTION DONE; USER PASS DEFERRED' } elseif ($phaseSucceeded) { 'DONE' } else { 'FAILED' }
                Write-Log "<<< [$phaseNum/$($enabledPhases.Count)] $($phase.Name) - $phaseLabel ($([math]::Round($elapsed.TotalMinutes, 1)) min, $phaseCount pkg)" -Level $(if ($phaseSucceeded -or $phase.UserCompletionDeferred) { 'Info' } else { 'Error' })
                if ($phaseSucceeded) { Write-EventLogEntry -EventId 1004 -Message "$($phase.Name) complete: $phaseCount packages in $([math]::Round($elapsed.TotalMinutes,1)) min" }
            } catch {
                $elapsed = (Get-Date) - $phaseStart

                <# Console: styled failure #>
                Write-PhaseResult -Num $phaseNum -Total $enabledPhases.Count -Name $phase.Name -Success $false -Minutes $elapsed.TotalMinutes
                Write-Log "<<< [$phaseNum/$($enabledPhases.Count)] $($phase.Name) - FAILED ($([math]::Round($elapsed.TotalMinutes, 1)) min)" -Level Error
                Write-Log "  Error: $_" -Level Error
                if ($_.Exception.StackTrace) { Write-Log "  Stack: $($_.Exception.StackTrace)" -Level Error }
                if ($_.Exception.InnerException) { Write-Log "  Inner: $($_.Exception.InnerException.Message)" -Level Error }
                Write-EventLogEntry -EventId 1003 -EntryType Error -Message "$($phase.Name) failed: $_"
                $state.($phase.Flag) = $false
            }
            Set-BootUpdateState -State $state

            <# Per-phase hook — After<Name> (b3w) #>
            Invoke-PhaseHook -EventName "After$($phase.Name)"
            if ($script:ExplicitRebootRequests.Count -gt 0) {
                Write-Log "Reboot barrier raised by $($script:ExplicitRebootRequests[-1].Source); deferring remaining phases until after boot." -Level Warn
                $rebootBarrierRaised = $true
                break
            }
        }  <# end foreach sequential phase #>

        <# ── Parallel cohort: Pip / Npm / Scoop / DotnetTools / Vscode / Defender / Office365 / PowerShellModules ──
           These phases share no installer locks (no msiexec, no CBS) and have no inter-dependencies.
           Each is launched as a Start-ThreadJob.  Because thread jobs run in a separate runspace,
           the parent's function definitions are unavailable, so each job carries a self-contained
           scriptblock.  Log lines are accumulated in the result and replayed on the parent thread
           via Write-Log after all jobs complete.  State is written ONCE atomically after the cohort.

           Crash-recovery: phases already marked Done in $state are skipped (not re-launched). #>

        $pendingCohort = if ($rebootBarrierRaised) { @() } else { @($parallelCohort | Where-Object { (-not $_.Skip) -and (-not $_.Defer) -and (-not [bool]$state.($_.Flag)) }) }

        if ($pendingCohort.Count -gt 0) {
            $cohortStart = Get-Date
            Write-Log "--- Parallel cohort: $($pendingCohort.Count) phase(s): $(($pendingCohort | ForEach-Object { $_.Name }) -join ', ') ---"

            <# Mark crash-recovery intent for the whole cohort as a group #>
            $state.LastPhaseStarted = 'ParallelCohort'; $state.LastPhaseTimestamp = Get-Date -Format 'o'; $state.Phase = 'ParallelCohort'
            Set-BootUpdateState -State $state

            <# Shared values to pass into thread jobs via $using: #>
            $cohortExcludePatterns = $script:ExcludePatterns
            $cohortWhatIf          = [bool]$WhatIfPreference
            $cohortTimeoutSec      = $script:PackageTimeoutMinutes * 60

            <# Per-phase self-contained scriptblocks.
               Each returns: @{ Phase=[string]; Success=[bool]; Count=[int]; LogLines=[string[]] }
               Write-Log is NOT called inside jobs — lines are collected and replayed by the parent. #>

            $pipSb = {
                param($ExcludePatterns, $IsWhatIf, $IncludePatterns = @())
                <# Inline copy of Test-PackageExcluded semantics (isolated runspace) #>
                $testExcluded = {
                    param($Name)
                    foreach ($p in $ExcludePatterns) {
                        if ($p -match '[\*\?]') { if ($Name -like $p) { return "excluded by pattern '$p'" } }
                        elseif ($Name.IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return "excluded by pattern '$p'" }
                    }
                    if (@($IncludePatterns).Count -gt 0) {
                        foreach ($p in $IncludePatterns) {
                            if ($p -match '[\*\?]') { if ($Name -like $p) { return $null } }
                            elseif ($Name.IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $null }
                        }
                        return 'not in IncludePatterns allowlist'
                    }
                    return $null
                }
                $log = [System.Collections.Generic.List[string]]::new()
                $count = 0; $success = $true
                $pip = Get-Command pip -ErrorAction SilentlyContinue
                if (-not $pip) { $log.Add('[Warn] pip not found, skipping.'); return @{ Phase='Pip'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                $log.Add('Updating pip packages...')
                if ($IsWhatIf) {
                    $log.Add('  [WHATIF] Would run: pip install --upgrade <outdated packages>')
                    return @{ Phase='Pip'; Success=$true; Count=0; LogLines=$log.ToArray() }
                }
                try {
                    & python -m pip install --upgrade pip 2>&1 | ForEach-Object { $log.Add($_.ToString()) }
                    if ($LASTEXITCODE -ne 0) { $success = $false; $log.Add("[Error] pip self-update exited with code $LASTEXITCODE") }
                    $outdated = @(& pip list --outdated --format=json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue)
                    if ($LASTEXITCODE -ne 0) { $success = $false; $log.Add("[Error] pip inventory exited with code $LASTEXITCODE") }
                    foreach ($pkg in $outdated) {
                        $skipReason = & $testExcluded $pkg.name
                        if ($skipReason) { $log.Add("Pip: skipping $($pkg.name) ($skipReason)"); continue }
                        $log.Add("Upgrading: $($pkg.name)")
                        & pip install --upgrade "$($pkg.name)" 2>&1 | ForEach-Object { $log.Add($_.ToString()) }
                        if ($LASTEXITCODE -eq 0) { $count++ } else { $success = $false; $log.Add("[Error] pip update for $($pkg.name) exited with code $LASTEXITCODE") }
                    }
                } catch { $success = $false; $log.Add("[Error] pip: $_") }
                return @{ Phase='Pip'; Success=$success; Count=$count; LogLines=$log.ToArray() }
            }

            $npmSb = {
                param($IsWhatIf)
                $log = [System.Collections.Generic.List[string]]::new()
                $count = 0; $success = $true
                $npm = Get-Command npm -ErrorAction SilentlyContinue
                if (-not $npm) { $log.Add('[Warn] npm not found, skipping.'); return @{ Phase='Npm'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                $log.Add('Updating npm global packages...')
                if ($IsWhatIf) {
                    $log.Add('  [WHATIF] Would run: npm update -g')
                    return @{ Phase='Npm'; Success=$true; Count=0; LogLines=$log.ToArray() }
                }
                try {
                    & npm update -g 2>&1 | ForEach-Object { if ($_ -match 'added|updated') { $count++ }; $log.Add($_.ToString()) }
                    if ($LASTEXITCODE -ne 0) { $success = $false; $log.Add("[Error] npm update exited with code $LASTEXITCODE") }
                } catch { $success = $false; $log.Add("[Error] npm: $_") }
                return @{ Phase='Npm'; Success=$success; Count=$count; LogLines=$log.ToArray() }
            }

            $scoopSb = {
                param($IsWhatIf)
                $log = [System.Collections.Generic.List[string]]::new()
                $count = 0; $success = $true
                $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
                if ($isSystem) { $log.Add('[Warn] Scoop skipped: SYSTEM context (user-scoped).'); return @{ Phase='Scoop'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                $scoop = Get-Command scoop -ErrorAction SilentlyContinue
                if (-not $scoop) { $log.Add('[Warn] Scoop not found, skipping.'); return @{ Phase='Scoop'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                $log.Add('Updating Scoop...')
                if ($IsWhatIf) {
                    $log.Add('  [WHATIF] Would run: scoop update && scoop update *')
                    return @{ Phase='Scoop'; Success=$true; Count=0; LogLines=$log.ToArray() }
                }
                try {
                    & scoop update 2>&1 | ForEach-Object { $log.Add($_.ToString()) }
                    if ($LASTEXITCODE -ne 0) { $success = $false; $log.Add("[Error] Scoop metadata update exited with code $LASTEXITCODE") }
                    $log.Add('Updating all Scoop packages...')
                    & scoop update * 2>&1 | ForEach-Object {
                        if ($_ -match '^\s*\S+:\s+\S+\s+->\s+\S+') { $count++ }
                        $log.Add($_.ToString())
                    }
                    if ($LASTEXITCODE -ne 0) { $success = $false; $log.Add("[Error] Scoop package update exited with code $LASTEXITCODE") }
                    $log.Add("Scoop: $count package(s) updated.")
                } catch { $success = $false; $log.Add("[Error] Scoop: $_") }
                return @{ Phase='Scoop'; Success=$success; Count=$count; LogLines=$log.ToArray() }
            }

            $dotnetSb = {
                param($IsWhatIf)
                $log = [System.Collections.Generic.List[string]]::new()
                $count = 0; $success = $true
                $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
                if (-not $dotnet) { $log.Add('[Warn] dotnet not found, skipping.'); return @{ Phase='DotnetTools'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                $log.Add('*** DOTNET TOOLS UPDATE - HIGH RISK ***')
                $log.Add('    May break SDK-dependent builds. To disable: -SkipDotnetTools')
                try {
                    $listOutput = & dotnet tool list --global 2>&1
                    if ($LASTEXITCODE -ne 0) { $log.Add("[Error] dotnet tool inventory exited with code $LASTEXITCODE"); return @{ Phase='DotnetTools'; Success=$false; Count=0; LogLines=$log.ToArray() } }
                    $tools = @($listOutput | Select-Object -Skip 2 | Where-Object { $_ -match '^\S' } | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    if ($tools.Count -eq 0) { $log.Add('No .NET global tools found.'); return @{ Phase='DotnetTools'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                    $log.Add("Found $($tools.Count) tool(s): $($tools -join ', ')")
                    foreach ($tool in $tools) {
                        $log.Add("Updating: $tool")
                        if ($IsWhatIf) { $log.Add("  [WHATIF] Would run: dotnet tool update --global $tool"); continue }
                        try {
                            $output = & dotnet tool update --global $tool 2>&1
                            $output | ForEach-Object { $log.Add($_.ToString()) }
                            if ($LASTEXITCODE -ne 0) { $success = $false; $log.Add("[Error] $tool update exited with code $LASTEXITCODE") }
                            elseif ($output -match 'was successfully updated') { $count++ }
                        } catch { $success = $false; $log.Add("[Error] $tool error: $_") }
                    }
                    $log.Add("dotnet tools: $count updated.")
                } catch { $success = $false; $log.Add("[Error] dotnet tools: $_") }
                return @{ Phase='DotnetTools'; Success=$success; Count=$count; LogLines=$log.ToArray() }
            }

            $vscodeSb = {
                param($IsWhatIf)
                $log = [System.Collections.Generic.List[string]]::new()
                $count = 0; $success = $true
                $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
                if ($isSystem) { $log.Add('[Warn] VS Code skipped: SYSTEM context (per-user).'); return @{ Phase='Vscode'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                $codeCmd = Get-Command code -ErrorAction SilentlyContinue
                if (-not $codeCmd) { $codeCmd = Get-Command code-insiders -ErrorAction SilentlyContinue }
                if (-not $codeCmd) { $log.Add('[Warn] VS Code not found, skipping.'); return @{ Phase='Vscode'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                $log.Add("Updating VS Code extensions via: $($codeCmd.Name)")
                if ($IsWhatIf) {
                    $log.Add('  [WHATIF] Would run: code --update-extensions')
                    return @{ Phase='Vscode'; Success=$true; Count=0; LogLines=$log.ToArray() }
                }
                try {
                    $output = & $codeCmd.Name --update-extensions 2>&1
                    $output | ForEach-Object { $log.Add($_.ToString()) }
                    if ($LASTEXITCODE -ne 0) { $success = $false; $log.Add("[Error] VS Code extension update exited with code $LASTEXITCODE") }
                    $count = @($output | Where-Object { $_ -match '(?i)updating extension|updated to version' }).Count
                    if ($count -eq 0) {
                        $upToDate = $output | Where-Object { $_ -match '(?i)already installed|up.to.date' }
                        if ($upToDate) { $log.Add('VS Code extensions: all up to date.'); $count = 0 }
                        else { $log.Add('VS Code extensions: update ran (exact count unavailable).'); $count = 1 }
                    } else { $log.Add("VS Code extensions: $count updated.") }
                } catch { $success = $false; $log.Add("[Error] VS Code: $_") }
                return @{ Phase='Vscode'; Success=$success; Count=$count; LogLines=$log.ToArray() }
            }

            $defenderSb = {
                param($IsWhatIf)
                <# Process-based (MpCmdRun.exe) rather than Update-MpSignature: the Defender
                   PS module rides Windows PowerShell compat remoting, which is not safe to
                   share across ThreadJob runspaces. A requested refresh failure stays pending. #>
                $log = [System.Collections.Generic.List[string]]::new()
                $mpCmdRun = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
                if (-not (Test-Path $mpCmdRun)) { $log.Add('[Warn] Defender skipped: MpCmdRun.exe not found (Defender may be disabled or absent).'); return @{ Phase='Defender'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                $log.Add('Updating Windows Defender signatures...')
                if ($IsWhatIf) {
                    $log.Add('  [WHATIF] Would run: MpCmdRun.exe -SignatureUpdate -MMPC')
                    return @{ Phase='Defender'; Success=$true; Count=0; LogLines=$log.ToArray() }
                }
                try {
                    & $mpCmdRun -SignatureUpdate -MMPC 2>&1 | ForEach-Object { $log.Add($_.ToString()) }
                    if ($LASTEXITCODE -eq 0) {
                        $log.Add('Defender signatures updated.')
                        return @{ Phase='Defender'; Success=$true; Count=1; LogLines=$log.ToArray() }
                    }
                    $log.Add("[Error] Defender signature update exit code $LASTEXITCODE")
                } catch { $log.Add("[Error] Defender signature update failed: $_") }
                return @{ Phase='Defender'; Success=$false; Count=0; LogLines=$log.ToArray() }
            }

            $office365Sb = {
                param($IsWhatIf)
                $log = [System.Collections.Generic.List[string]]::new()
                $c2rClient = "${env:ProgramFiles}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
                if (-not (Test-Path $c2rClient)) { $log.Add('[Warn] Office 365 C2R not found, skipping.'); return @{ Phase='Office365'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                $log.Add('Updating Office 365 (Click-to-Run)...')
                if ($IsWhatIf) {
                    $log.Add('  [WHATIF] Would run: OfficeC2RClient.exe /update user')
                    return @{ Phase='Office365'; Success=$true; Count=0; LogLines=$log.ToArray() }
                }
                try {
                    & $c2rClient /update user updatepromptuser=false forceappshutdown=true displaylevel=false 2>&1 | ForEach-Object { $log.Add($_.ToString()) }
                    if ($LASTEXITCODE -ne 0) { $log.Add("[Error] Office 365 updater exited with code $LASTEXITCODE"); return @{ Phase='Office365'; Success=$false; Count=0; LogLines=$log.ToArray() } }
                    $log.Add('Office 365 update triggered (may complete in background)')
                    return @{ Phase='Office365'; Success=$true; Count=1; LogLines=$log.ToArray() }
                } catch { $log.Add("[Error] Office 365: $_") }
                return @{ Phase='Office365'; Success=$false; Count=0; LogLines=$log.ToArray() }
            }

            $psModulesSb = {
                param($IsWhatIf, $TimeoutMinutes)
                <# Mirrors Update-PowerShellModules: PSResourceGet bulk path with legacy
                   Update-Module fallback. The inner Start-Job (child process) pattern is
                   preserved — nested process jobs are safe from a ThreadJob runspace. #>
                $log = [System.Collections.Generic.List[string]]::new()
                $count = 0; $success = $true
                $log.Add('Checking installed PowerShell modules...')
                try {
                    $usePSResourceGet = [bool](Get-Command Update-PSResource -ErrorAction SilentlyContinue)
                    $throttle = [Math]::Min(8, [Math]::Max(2, [Environment]::ProcessorCount))
                    if ($usePSResourceGet) {
                        $log.Add('Using PSResourceGet (Update-PSResource) for bulk module update...')
                        $installed = Get-InstalledPSResource -Scope AllUsers -ErrorAction SilentlyContinue
                        if (-not $installed) { $installed = Get-InstalledPSResource -ErrorAction SilentlyContinue }
                        $moduleNames = @($installed | Where-Object {
                            $_.Name -notlike 'Microsoft.PowerShell.*' -and
                            $_.Name -notlike 'AWS.Tools.*' -and
                            $_.Name -ne 'Az' -and
                            $_.Type -eq 'Module'
                        } | Select-Object -ExpandProperty Name -Unique)
                        if (-not $moduleNames) { $log.Add('No updatable modules found.'); return @{ Phase='PowerShellModules'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                        $log.Add("Found $($moduleNames.Count) module(s) to update.")
                        if ($IsWhatIf) { $log.Add("  [WHATIF] Would run: Update-PSResource for $($moduleNames.Count) modules"); return @{ Phase='PowerShellModules'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                        $log.Add("Running parallel updates (throttle: $throttle)...")
                        $job = Start-Job -ScriptBlock {
                            param($Names, $Throttle)
                            $Names | ForEach-Object -ThrottleLimit $Throttle -Parallel {
                                $n = $_
                                try {
                                    $before = (Get-InstalledPSResource -Name $n -EA SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1).Version
                                    Update-PSResource -Name $n -Scope AllUsers -TrustRepository -AcceptLicense -Quiet -EA Stop
                                    $after = (Get-InstalledPSResource -Name $n -EA SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1).Version
                                    if ($after -and $before -and $after -gt $before) { "UPDATED|$n|$before|$after" }
                                } catch { "ERROR|$n|$_" }
                            }
                        } -ArgumentList (,$moduleNames), $throttle
                    } else {
                        $log.Add('PSResourceGet not available - falling back to parallel Update-Module...')
                        $installed = Get-InstalledModule -ErrorAction SilentlyContinue
                        if (-not $installed) { $log.Add('[Warn] No user-installed modules found.'); return @{ Phase='PowerShellModules'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                        $modules = @($installed | Where-Object {
                            $_.Name -notlike 'Microsoft.PowerShell.*' -and
                            $_.Name -notlike 'AWS.Tools.*' -and
                            $_.Name -ne 'Az'
                        })
                        if (-not $modules) { $log.Add('Only built-in modules found.'); return @{ Phase='PowerShellModules'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                        $log.Add("Found $($modules.Count) module(s) to check.")
                        if ($IsWhatIf) { $log.Add("  [WHATIF] Would run: Update-Module for $($modules.Count) modules"); return @{ Phase='PowerShellModules'; Success=$true; Count=0; LogLines=$log.ToArray() } }
                        $modulePairs = $modules | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version.ToString() } }
                        $log.Add("Running parallel updates (throttle: $throttle)...")
                        $job = Start-Job -ScriptBlock {
                            param($Pairs, $Throttle)
                            $Pairs | ForEach-Object -ThrottleLimit $Throttle -Parallel {
                                $n = $_.Name; $curVer = $_.Version
                                try {
                                    Update-Module -Name $n -Force -EA Stop *> $null
                                    $newVer = (Get-InstalledModule -Name $n -EA SilentlyContinue).Version.ToString()
                                    if ($newVer -and ($newVer -ne $curVer)) { "UPDATED|$n|$curVer|$newVer" }
                                } catch {
                                    if ($_ -match 'already the latest') { return }
                                    "ERROR|$n|$_"
                                }
                            }
                        } -ArgumentList (,$modulePairs), $throttle
                    }

                    $done = $job | Wait-Job -Timeout ($TimeoutMinutes * 60)
                    if (-not $done) {
                        $success = $false
                        $log.Add("[Warn] TIMEOUT: module bulk update exceeded ${TimeoutMinutes}m")
                        try { Get-Process -Id $job.ChildJobs[0].ProcessId -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue } catch { }
                        $job | Stop-Job -PassThru | Remove-Job -Force
                    } else {
                        $results = @(Receive-Job $job -ErrorAction SilentlyContinue)
                        $jobFailed = $job.State -eq 'Failed'
                        Remove-Job $job -Force
                        foreach ($line in $results) {
                            if ($line -is [string] -and $line -match '^UPDATED\|(.+)\|(.+)\|(.+)$') {
                                $log.Add("  $($Matches[1]): $($Matches[2]) -> $($Matches[3])")
                                $count++
                            } elseif ($line -is [string] -and $line -match '^ERROR\|(.+)\|(.+)$') {
                                $success = $false
                                $log.Add("[Error]   $($Matches[1]) error: $($Matches[2])")
                            }
                        }
                        if ($jobFailed) { $success = $false; $log.Add('[Error] Module bulk update job reported failure') }
                    }
                    $log.Add("PowerShell modules: $count updated.")
                } catch { $success = $false; $log.Add("[Error] PowerShell modules: $_") }
                return @{ Phase='PowerShellModules'; Success=$success; Count=$count; LogLines=$log.ToArray() }
            }

            <# Before<Phase> hooks for parallel cohort phases — fired on the parent thread before jobs launch.
               Thread jobs run in isolated runspaces so Invoke-PhaseHook cannot be called from inside them. #>
            foreach ($cp in $pendingCohort) { Invoke-PhaseHook -EventName "Before$($cp.Name)" }

            <# Launch one ThreadJob per enabled pending phase #>
            $cohortJobs = [System.Collections.Generic.List[object]]::new()
            foreach ($cp in $pendingCohort) {
                $job = switch ($cp.Name) {
                    'Pip'               { Start-ThreadJob -ScriptBlock $pipSb       -ArgumentList $cohortExcludePatterns, $cohortWhatIf, $script:IncludePatterns }
                    'Npm'               { Start-ThreadJob -ScriptBlock $npmSb       -ArgumentList $cohortWhatIf }
                    'Scoop'             { Start-ThreadJob -ScriptBlock $scoopSb     -ArgumentList $cohortWhatIf }
                    'DotnetTools'       { Start-ThreadJob -ScriptBlock $dotnetSb    -ArgumentList $cohortWhatIf }
                    'Vscode'            { Start-ThreadJob -ScriptBlock $vscodeSb    -ArgumentList $cohortWhatIf }
                    'Defender'          { Start-ThreadJob -ScriptBlock $defenderSb  -ArgumentList $cohortWhatIf }
                    'Office365'         { Start-ThreadJob -ScriptBlock $office365Sb -ArgumentList $cohortWhatIf }
                    'PowerShellModules' { Start-ThreadJob -ScriptBlock $psModulesSb -ArgumentList $cohortWhatIf, $script:PackageTimeoutMinutes }
                }
                if ($job) {
                    $job | Add-Member -NotePropertyName 'PhaseName' -NotePropertyValue $cp.Name -Force
                    $cohortJobs.Add($job)
                }
            }

            <# Wait for all cohort jobs; timeout = sum of individual ceilings (count * PackageTimeoutMinutes) #>
            $cohortTimeoutSec = [math]::Max($cohortTimeoutSec, $script:PackageTimeoutMinutes * 60 * $pendingCohort.Count)
            if ($cohortJobs.Count -gt 0) {
                $cohortDeadline = [datetime]::UtcNow.AddSeconds($cohortTimeoutSec)
                do {
                    $finished = @($cohortJobs | Where-Object { $_.State -in @('Completed','Failed','Stopped') }).Count
                    $overallDone = $phaseNum + $finished
                    $overallPercent = if ($enabledPhases.Count -gt 0) {
                        [math]::Min(99, [math]::Floor(($overallDone / $enabledPhases.Count) * 100))
                    } else { 99 }
                    Write-BootUpdateProgress -Activity 'Parallel update cohort' `
                        -Status "$finished/$($cohortJobs.Count) phases complete" -PercentComplete $overallPercent
                    if ($finished -eq $cohortJobs.Count) { break }
                    Wait-BootUpdateUiInterval -Seconds 1 -Activity 'Parallel update cohort' `
                        -Status "$finished/$($cohortJobs.Count) phases complete" -PercentComplete $overallPercent
                } while ([datetime]::UtcNow -lt $cohortDeadline)
            }

            <# Collect results, replay logs, update state — one atomic write at the end #>
            foreach ($job in $cohortJobs) {
                $phaseName = $job.PhaseName
                $phaseDefn = $parallelCohort | Where-Object { $_.Name -eq $phaseName } | Select-Object -First 1

                $jr = $null
                try { $jr = Receive-Job -Job $job -ErrorAction SilentlyContinue } catch { }
                $jobState = $job.State
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

                if ($null -eq $jr -or $jobState -ne 'Completed') {
                    Write-Log "[$phaseName] Thread job did not complete (state: $jobState) — leaving pending for retry" -Level Error
                    $state.($phaseDefn.Flag) = $false
                    continue
                }

                <# Replay log lines through Write-Log on the parent thread #>
                foreach ($line in $jr.LogLines) {
                    $lvl = if ($line -match '^\[Warn\]') { 'Warn' }
                          elseif ($line -match '^\[Error\]') { 'Error' }
                          else { 'Info' }
                    $cleanLine = $line -replace '^\[(Warn|Error)\]\s*', ''
                    Write-Log $cleanLine -Level $lvl
                }

                $replayedFailure = @($jr.LogLines | Where-Object { $_ -match '^\[Error\]|^\[Warn\].*(failed|timed out|timeout|error)' }).Count -gt 0
                $phaseSucceeded = $jobState -eq 'Completed' -and [bool]$jr.Success -and (-not $replayedFailure)
                $state.($phaseDefn.Flag) = $phaseSucceeded
                if ($phaseDefn.Key -and $jr.Count) {
                    $state.Summary.($phaseDefn.Key) += $jr.Count
                }

                $phaseNum++
                $elapsed = (Get-Date) - $cohortStart
                Write-PhaseResult -Num $phaseNum -Total $enabledPhases.Count -Name $phaseName -Success $phaseSucceeded -Minutes $elapsed.TotalMinutes -Count $jr.Count
                Write-Log "<<< [parallel] $phaseName - $(if ($phaseSucceeded) { 'DONE' } else { 'FAILED; RETRY PENDING' }) ($($jr.Count) pkg)" -Level $(if ($phaseSucceeded) { 'Info' } else { 'Error' })
                if ($phaseSucceeded) { Write-EventLogEntry -EventId 1004 -Message "$phaseName complete: $($jr.Count) packages (parallel cohort)" }
                <# After<Phase> hook — fired on the parent thread as each result is collected (approximate order). #>
                Invoke-PhaseHook -EventName "After$phaseName"
            }

            <# Atomic state write — one write covers all five cohort phases #>
            $state.LastPhaseStarted = $null; $state.LastPhaseTimestamp = $null; $state.Phase = 'CohortDone'
            Set-BootUpdateState -State $state

            $cohortElapsed = (Get-Date) - $cohortStart
            Write-Log "--- Parallel cohort complete in $([math]::Round($cohortElapsed.TotalMinutes, 1)) min ---"

        } else {
            Write-Log '--- Parallel cohort: all phases already done or skipped ---'
        }
    }  <# end if (-not $script:StagedRollout) #>

    <# ---- Post-update health check ---- #>
    $healthCheck = if ($script:SkipHealthCheck) { $null } else { Test-PostUpdateHealth }
    if ($healthCheck -and -not $healthCheck.AllHealthy) {
        Write-Log "Health check detected failed services: $($healthCheck.FailedServices -join ', ')" -Level Warn
        $state.Summary.HealthFailed = $healthCheck.FailedServices.Count
        Set-BootUpdateState -State $state
    }

    <# ---- Post-update reboot decision ---- #>
    <# In WhatIf mode, always report clean — no reboot or task registration ever happens #>
    $pending = if ($WhatIfPreference) { @() } else { Get-ConfirmedPendingReboot }
    if ($pending) {
        Write-Log 'Pending reboot after updates: YES' -Level Warn
        $pending | ForEach-Object { Write-Log "  - $($_.Source): $($_.Detail)" -Level Warn }

        <# Stale-signal loop visibility: if this reboot is driven by exactly the same
           signal set as the previous one, say so — PendingFileRenameOperations in
           particular can be perpetually repopulated by AV/installers and is the
           classic cause of running to the max-iterations backstop. #>
        $signalKey = (($pending | ForEach-Object { $_.Source } | Sort-Object) -join ',')
        if ($state.LastRebootSignals -and $signalKey -eq $state.LastRebootSignals) {
            Write-Log "Same reboot-signal set as the previous reboot ($signalKey). If this repeats to the max-iterations limit, one of these signals is likely stale or perpetually repopulated — see the per-signal detail above." -Level Warn
        }
        $state.LastRebootSignals = $signalKey

        <# Reset phase Done flags for next iteration.
           Staged mode: reset ONLY the current phase's flag — completed phases are not re-run
           after the reboot (the current phase re-runs because the reboot may have been triggered
           by updates it installed).
           Non-staged mode: reset ALL flags — all phases re-run after each reboot (v2.0 behaviour). #>
        if ($script:StagedRollout -and $targetPhase) {
            $state.($targetPhase.Flag) = $false
            Write-Log "Staged rollout: reset only [$($targetPhase.Name)] flag for post-reboot re-run." -Level Info
        } else {
            $state.WingetDone = $false; $state.ChocolateyDone = $false; $state.WindowsUpdateDone = $false
            $state.AwsToolingDone = $false; $state.PipDone = $false; $state.NpmDone = $false; $state.Office365Done = $false
            $state.PowerShellModulesDone = $false; $state.ScoopDone = $false; $state.DotnetToolsDone = $false; $state.VscodeDone = $false
            $state.DefenderDone = $false; $state.DriverFirmwareDone = $false; $state.WslDone = $false; $state.ContainersDone = $false
        }
        $state.LastPhaseStarted = $null; $state.LastPhaseTimestamp = $null; $state.Phase = 'Rebooting'
        <# Clear network cache so the post-reboot iteration always re-probes from a clean boot state #>
        $state.LastPreflightNetworkAt = $null; $state.LastPreflightNetworkOk = $null
        Set-BootUpdateState -State $state

        <# Guard task registration and reboot — neither must fire in WhatIf mode #>
        if (-not $WhatIfPreference) {
            Start-BootUpdateRestart -State $state -Reason "Iteration $($state.Iteration) completed with pending reboot evidence."
        } else {
            Write-Log '  [WHATIF] Would register scheduled task and restart computer'
        }
    } else {
        <# No pending reboot. #>

        if ($script:StagedRollout) {
            <# Staged mode: check whether any enabled phases remain undone.
               If yes, stay registered and exit clean — next boot picks up the next phase.
               If no, fall through to normal cycle-complete cleanup. #>
            $remainingPhases = @($allPhasesFlat | Where-Object { (-not $_.Skip) -and (-not $_.UserCompletionDeferred) -and (-not [bool]$state.($_.Flag)) })
            if ($remainingPhases.Count -gt 0) {
                $nextPhase = $remainingPhases[0]
                $state.StagedNextPhase = $nextPhase.Name
                Set-BootUpdateState -State $state
                Write-Log "Staged rollout: $($remainingPhases.Count) phase(s) remaining. A near-term checkpoint will run [$($nextPhase.Name)]." -Level Info
                Write-Log "  Remaining: $(($remainingPhases | ForEach-Object { $_.Name }) -join ', ')"
                if (-not $WhatIfPreference) { $null = Register-BootUpdateTaskForReboot -RetrySoon }
                Write-BootUpdateProgress -Completed
                return  <# Cycle not complete — exit without cleanup #>
            }
            Write-Log 'Staged rollout: all phases complete, no pending reboots — cycle done.' -Level Info
        }

        if (-not $WhatIfPreference -and [bool]$state.WindowsUpdateDone) {
            $wuConvergence = Test-WindowsUpdateConvergence
            if (-not $wuConvergence.Verified -or $wuConvergence.Count -gt 0) {
                $state.WindowsUpdateDone = $false
                Set-BootUpdateState -State $state
                $why = if (-not $wuConvergence.Verified) { 'the final scan could not be verified' } else { "$($wuConvergence.Count) update(s) remain applicable" }
                Write-Log "Windows Update convergence withheld: $why." -Level Warn
            } else {
                Write-Log 'Windows Update convergence verified: zero applicable updates remain in the configured category scope.'
            }
        }

        <# A clean reboot probe is not a successful cycle if an enabled phase failed or
           timed out. Queue a near-term checkpoint retry instead of printing a false
           all-clear. The same task also retains its boot/logon trigger. #>
        $incompletePhases = @($enabledPhases | Where-Object { -not [bool]$state.($_.Flag) })
        $disposition = Resolve-BootUpdateCompletionDisposition -IncompletePhases $incompletePhases
        if (-not $WhatIfPreference -and $disposition.Kind -eq 'Retry') {
            $state.Phase = 'RetryPending'
            Set-BootUpdateState -State $state
            $incompleteNames = $disposition.Phases.Name -join ', '
            Write-Log "Verification withheld: incomplete phase(s): $incompleteNames. Automatic retry queued for two minutes." -Level Warn
            $null = Register-BootUpdateTaskForReboot -RetrySoon
            Write-BootUpdateProgress -Completed
            Show-CycleBanner -Title 'R E C O V E R Y   P A S S   Q U E U E D' -AnsiColor "$([char]27)[33m" -Info @(
                'Not calling this complete yet — the checkpoint is safe.'
                "Retrying in about 2 minutes: $incompleteNames"
                'The reboot/logon resume chain remains armed.'
            )
            exit 1
        }
        if (-not $WhatIfPreference -and $disposition.Kind -eq 'UserContext') {
            $state.Phase = 'UserContextPending'
            Set-BootUpdateState -State $state
            $deferredNames = $disposition.Phases.Name -join ', '
            $retryForUnknownUser = [string]::IsNullOrWhiteSpace([string]$state.ResumeUser)
            $null = Register-BootUpdateTaskForReboot -RetrySoon:$retryForUnknownUser
            Write-BootUpdateProgress -Completed
            Show-CycleBanner -Title 'U S E R   P A S S   P E N D I N G' -AnsiColor "$([char]27)[36m" -Info @(
                'Machine-level work is safe; full verification is intentionally withheld.'
                $(if ($retryForUnknownUser) { "No interactive user is known yet; rediscovery retries in about 2 minutes: $deferredNames" } else { "Waiting for $($state.ResumeUser) to sign in: $deferredNames" })
                $(if ($retryForUnknownUser) { 'The SYSTEM watchdog is armed; completion remains blocked on user context.' } else { 'The user-at-logon continuation remains armed.' })
            )
            return
        }

        if ($WhatIfPreference) { Write-Log '[WHATIF] Pending reboot check skipped — reporting clean (no actual updates ran)' }
        $duration = if ($state.StartTime) { (Get-Date) - [datetime]$state.StartTime } else { [timespan]::Zero }
        $s = $state.Summary
        $total = $s.Winget + $s.Chocolatey + $s.WindowsUpdate + $s.Pip + $s.Npm + $s.Office365 + $s.PowerShellModules + $s.Scoop + $s.DotnetTools + $s.Vscode
        $reboots = [int]$state.RebootCount
        $durMin = [math]::Round($duration.TotalMinutes, 1)
        $pkgLine = "Winget=$($s.Winget) Choco=$($s.Chocolatey) WU=$($s.WindowsUpdate) Pip=$($s.Pip) Npm=$($s.Npm) O365=$($s.Office365) PSMod=$($s.PowerShellModules) Scoop=$($s.Scoop) Dotnet=$($s.DotnetTools) VSCode=$($s.Vscode)"

        <# Console: styled completion banner #>
        $healthIsGreen = $null -ne $healthCheck -and $healthCheck.AllHealthy
        $completionTitle = if ($WhatIfPreference) { 'W H A T I F   C H E C K   C O M P L E T E' }
                           elseif ($healthIsGreen) { 'C O N F I G U R E D   P A T C H   P A S S   V E R I F I E D' }
                           elseif ($null -eq $healthCheck) { 'C O N F I G U R E D   S C O P E   C O M P L E T E' }
                           else { 'P A T C H   P A S S   C O M P L E T E' }
        $congratulations = if ($WhatIfPreference) { 'Preview complete — no changes were made.' }
                           elseif ($healthIsGreen) { 'YOU DID IT — THE CONFIGURED PATCH PASS IS VERIFIED. NICE WORK.' }
                           elseif ($null -eq $healthCheck) { 'Configured updates are complete; health verification was skipped.' }
                           else { 'Updates landed, but one health check needs attention.' }
        $healthLine = if ($null -eq $healthCheck) { '[--] Service health check skipped by policy' }
                      elseif ($healthCheck.AllHealthy) { "[OK] $($healthCheck.CheckedServices.Count) critical service(s) healthy" }
                      else { "[!!] Service attention: $($healthCheck.FailedServices -join ', ')" }
        <# Log file: structured entries #>
        Write-Log "BOOT UPDATE CYCLE${whatIfTag} COMPLETE | $durMin min | $($state.Iteration) iteration(s) | $reboots reboot(s) | $total packages"
        Write-Log "  $pkgLine"
        Write-Log "Info: View trends with: Show-BootUpdateHistory.ps1 -Format Graph"

        Save-CycleHistory -State $state -Duration $duration

        <# PostCycle hook — cycle complete, no pending reboots, before self-removal (74r) #>
        Invoke-Hook -Path $script:PostCycleScript -HookName 'PostCycle'

        if (-not $WhatIfPreference) {
            <# Build enriched summary data: per-manager counts + scalar metrics for webhook/email #>
            $summaryData = [pscustomobject]@{
                Winget           = $s.Winget
                Chocolatey       = $s.Chocolatey
                WindowsUpdate    = $s.WindowsUpdate
                Pip              = $s.Pip
                Npm              = $s.Npm
                Office365        = $s.Office365
                PowerShellModules = $s.PowerShellModules
                Scoop            = $s.Scoop
                DotnetTools      = $s.DotnetTools
                Vscode           = $s.Vscode
                _total           = $total
                _iterations      = $state.Iteration
                _durMin          = $durMin
            }
            Unregister-BootUpdateTask
            Clear-BootUpdateState
            $leftoverTasks = @('BootUpdateCycle','BootUpdateCycleFallback') | Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue }
            if ($leftoverTasks -or (Test-Path -LiteralPath $script:StatePath)) {
                throw "Terminal cleanup verification failed; refusing the verified completion banner. Tasks: $($leftoverTasks -join ', ')"
            }
            Send-CompletionNotification -Title 'Boot Update Cycle Complete' -Message "$total packages updated in $($state.Iteration) iteration(s), $durMin min" -Data $summaryData
        }
        <# The congratulatory banner is the terminal commit point: hooks, notifications,
           task retirement, state removal, and cleanup verification have all finished. #>
        Write-BootUpdateProgress -Completed
        Show-CycleBanner -Title $completionTitle -AnsiColor "$([char]27)[32m" -Info @(
            $congratulations
            "[OK] $($enabledPhases.Count)/$($enabledPhases.Count) configured phases completed"
            if (-not $WhatIfPreference) { "[OK] Reboot state clean twice across $($script:RebootSignalSettleSeconds) seconds" }
            $healthLine
            if (-not $WhatIfPreference) { '[OK] Resume tasks retired; no retry is queued' }
            "$durMin min | $($state.Iteration) iteration(s) | $reboots completed reboot(s)"
            "$total packages updated"
            $pkgLine
        )
    }
}
#endregion

<# Entry point #>
if ($Force) { $ConfirmPreference = 'None' }

<# Splash preview mode: render every theme and exit. No mutex, no state, no
   updates — safe to run alongside a live cycle. Reachable via `upd splash`. #>
if ($PreviewSplash) {
    $savedTheme = $env:BOOT_UPDATE_SPLASH_THEME
    $themeNames = @('neon gradient', 'outline dither', 'classic 16-color / non-VT fallback')
    foreach ($t in 0, 1, 2) {
        Write-Host ''
        Write-Host "  -- splash theme $t : $($themeNames[$t]) --  (pin with BOOT_UPDATE_SPLASH_THEME=$t)" -ForegroundColor DarkGray
        $env:BOOT_UPDATE_SPLASH_THEME = "$t"
        Show-StartupArt
    }
    $env:BOOT_UPDATE_SPLASH_THEME = $savedTheme
    exit 0
}

function Enter-BootUpdateMutex {
    <# Acquire the cycle mutex or validate that this process is the replacement
       child of its current owner. Returning false keeps the exit decision at
       script scope and makes the complete arbitration path process-testable. #>
    param([string]$MutexName = 'Global\BootUpdateCycle')

    try {
        $script:BootUpdateMutex = [System.Threading.Mutex]::new($false, $MutexName)
        $acquired = $false
        try {
            $acquired = $script:BootUpdateMutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            Write-Log 'Named mutex was abandoned (previous instance exited uncleanly). Claiming ownership.' -Level Warn
            $acquired = $true
        }
        if ($acquired) { return $true }

        if (Test-SelfUpdateHandoff) {
            Write-Log 'Self-update: accepted authenticated mutex handoff from parent updater.' -Level Info
        } elseif (Test-LegacySelfUpdateHandoff) {
            Write-Log 'Self-update: inheriting mutex handoff from an older updater.' -Level Info
        } else {
            Write-Log 'Another BootUpdateCycle instance is already running (mutex held). Exiting.' -Level Warn
            $script:BootUpdateMutex.Dispose()
            $script:BootUpdateMutex = $null
            return $false
        }

        $script:BootUpdateMutex.Dispose()
        $script:BootUpdateMutex = $null
        return $true
    } catch {
        Write-Log "Named mutex acquisition failed (non-fatal): $_" -Level Warn
        $script:BootUpdateMutex = $null
        return $true
    }
}

<# Named-mutex guard — prevents two instances racing on a fast boot (9ls).
   AbandonedMutexException means the prior owner crashed without releasing; we inherit ownership. #>
if (-not (Enter-BootUpdateMutex)) { exit 0 }
<# Release mutex on any exit path, including exit 0/1 inside the function #>
Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action {
    if ($script:BootUpdateMutex) {
        try { $script:BootUpdateMutex.ReleaseMutex() } catch { }
        $script:BootUpdateMutex.Dispose()
        $script:BootUpdateMutex = $null
    }
} | Out-Null

<# Render splash BEFORE self-update / remote-config chatter so the BBS art is the
   first thing on screen and never gets pushed off the visible viewport on small
   consoles.  Invoke-BootUpdateCycle skips its own splash call when this flag is set. #>
if (Test-BootUpdateOutputAtLeast -Minimum Normal) {
    Show-StartupArt
    $script:_splashShown = $true
} else {
    $script:_splashShown = $false
}

<# lz1: Self-update — runs after mutex, before pre-flight. Skips under SYSTEM.
   If a newer version is downloaded and validated, re-execs and never returns.
   $PSBoundParameters is captured at script scope (before the function call). #>
Update-OrchestratorSelf -ScriptBoundParams $script:ScriptBoundParams

<# jzw: Remote config — fetch fleet-wide overrides from $ConfigUrl and apply any
   key NOT explicitly passed by the user.  No-op when ConfigUrl is empty. #>
$script:_remoteConfig = Get-RemoteConfig
Apply-RemoteConfig -RemoteConfig $script:_remoteConfig -UserBoundParams $script:ScriptBoundParams

try {
    Invoke-BootUpdateCycle
} finally {
    <# Idempotent safety net for normal return, terminating errors, and exit paths. #>
    Write-BootUpdateProgress -Completed
}
