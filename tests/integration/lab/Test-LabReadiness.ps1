#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'lab.local.json'),
    [switch]$ProbeGuest,
    [ValidateRange(1, 60)]
    [int]$ProbeTimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

function New-LabReadinessCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'NOT RUN')][string]$Status,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Name = $Name; Status = $Status; Message = $Message }
}

function Read-LabReadinessConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Lab config not found: $Path. Copy lab.local.example.json to lab.local.json and fill in machine-local values."
    }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $allowedProperties = @('CredentialTarget', 'GuestUser', 'SourceRoot', 'EvidenceRoot', 'ModuleCachePath', 'ModuleCacheSha256', 'Guests')
    $unknownProperties = @($config.Keys | Where-Object { $_ -notin $allowedProperties })
    if ($unknownProperties.Count) {
        throw "Lab config contains unsupported properties: $($unknownProperties -join ', '). Store secrets in Windows Credential Manager, not lab.local.json."
    }
    foreach ($name in 'CredentialTarget', 'GuestUser', 'SourceRoot', 'EvidenceRoot', 'ModuleCachePath', 'ModuleCacheSha256', 'Guests') {
        if (-not $config.ContainsKey($name)) { throw "Lab config is missing required property '$name'." }
    }
    foreach ($name in 'CredentialTarget', 'GuestUser', 'SourceRoot', 'EvidenceRoot') {
        if ([string]::IsNullOrWhiteSpace([string]$config[$name])) { throw "Lab config property '$name' must be a non-empty string." }
    }
    if ($config.Guests -isnot [array] -or $config.Guests.Count -eq 0) {
        throw "Lab config property 'Guests' must be a non-empty array."
    }
    foreach ($guest in $config.Guests) {
        if ($guest -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$guest.Name) -or
            [string]::IsNullOrWhiteSpace([string]$guest.Checkpoint)) {
            throw "Each Guests entry must contain non-empty Name and Checkpoint properties."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$config.ModuleCacheSha256) -and
        [string]$config.ModuleCacheSha256 -notmatch '^(?i)[0-9a-f]{64}$') {
        throw "Lab config property 'ModuleCacheSha256' must be blank or a 64-character SHA-256 hex digest."
    }
    return $config
}

function Get-LabStoredCredential {
    param([Parameter(Mandatory)][string]$Target)

    if (-not (Get-Module -ListAvailable -Name BetterCredentials)) {
        throw 'BetterCredentials is not installed for this user; preflight does not install modules.'
    }
    Import-Module BetterCredentials -ErrorAction Stop
    try {
        return [CredentialManagement.Store]::Load(
            $Target, [CredentialManagement.CredentialType]::Generic, $false)
    } catch {
        if ($_.Exception.InnerException.NativeErrorCode -eq 1168) { return $null }
        throw
    }
}

function Invoke-LabGuestReadOnlyProbe {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $job = $null
    try {
        # The VMName parameter set does not accept PSSessionOption. Run the read-only
        # command as a job so Wait-Job can bound both PowerShell Direct connection and
        # execution time without ever starting or changing the guest.
        $job = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -AsJob -ErrorAction Stop
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "Read-only PowerShell Direct probe exceeded ${TimeoutSeconds}s."
        }
        if ($job.State -ne 'Completed') {
            $null = Receive-Job -Job $job -ErrorAction Stop
            throw "Read-only PowerShell Direct probe ended in state '$($job.State)'."
        }
        $probeOutput = @(Receive-Job -Job $job -ErrorAction Stop)
        if ($probeOutput.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$probeOutput[0])) {
            throw 'Read-only PowerShell Direct probe returned no guest identity.'
        }
        return $true
    } finally {
        if ($job) {
            if ($job.State -notin 'Completed', 'Failed', 'Stopped') { Stop-Job -Job $job -ErrorAction SilentlyContinue }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-LabSourceRoot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ Passed = $false; Message = "Source directory is missing: '$Path'." }
    }
    $gitRoot = & git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$gitRoot)) {
        return [pscustomobject]@{ Passed = $false; Message = "Source directory is not a valid Git checkout: '$Path'." }
    }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullGitRoot = [IO.Path]::GetFullPath([string]$gitRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not [string]::Equals($fullPath, $fullGitRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Passed = $false; Message = "SourceRoot must be the Git checkout root '$fullGitRoot', not '$fullPath'." }
    }
    $requiredFiles = @(
        'Invoke-BootUpdateCycle.ps1',
        'Deploy-BootUpdateCycle.ps1',
        'upd.cmd',
        'tests/integration/lab/Invoke-LabRow.ps1',
        'tests/integration/lab/LabCredential.ps1'
    )
    $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Path $_) -PathType Leaf) })
    if ($missing.Count) {
        return [pscustomobject]@{ Passed = $false; Message = "Source checkout is missing required files: $($missing -join ', ')." }
    }
    return [pscustomobject]@{ Passed = $true; Message = "Valid Git checkout and required lab/update scripts are present at '$Path'." }
}

function Invoke-LabReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Probe,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    $config = $null
    try {
        $config = Read-LabReadinessConfig -Path $Path
        $checks.Add((New-LabReadinessCheck 'config' PASS "Loaded machine-local config from '$Path'."))
    } catch {
        $checks.Add((New-LabReadinessCheck 'config' FAIL $_.Exception.Message))
        return [pscustomobject]@{ Ready = $false; HostReady = $false; GuestAuthentication = 'NOT RUN'; Checks = $checks.ToArray() }
    }

    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $checks.Add((New-LabReadinessCheck 'elevation' PASS 'Running as an administrator.'))
    } else {
        $checks.Add((New-LabReadinessCheck 'elevation' FAIL 'Run this preflight in an elevated PowerShell session.'))
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $checks.Add((New-LabReadinessCheck 'powershell' PASS "PowerShell $($PSVersionTable.PSVersion) is running."))
    } else {
        $checks.Add((New-LabReadinessCheck 'powershell' FAIL "PowerShell 7 or newer is required; found $($PSVersionTable.PSVersion)."))
    }
    $missingCommands = @('Get-VM', 'Get-VMCheckpoint', 'Invoke-Command', 'Wait-Job', 'Stop-Job', 'Remove-Job') |
        Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
    if ($missingCommands.Count -eq 0) {
        $checks.Add((New-LabReadinessCheck 'hyperv-tools' PASS 'Hyper-V inventory and bounded PowerShell Direct commands are available.'))
    } else {
        $checks.Add((New-LabReadinessCheck 'hyperv-tools' FAIL "Required commands are unavailable: $($missingCommands -join ', ')."))
    }

    $sourceStatus = Test-LabSourceRoot -Path $config.SourceRoot
    $sourceResult = if ($sourceStatus.Passed) { 'PASS' } else { 'FAIL' }
    $checks.Add((New-LabReadinessCheck 'source' $sourceResult $sourceStatus.Message))
    if (Test-Path -LiteralPath $config.EvidenceRoot -PathType Container) {
        $checks.Add((New-LabReadinessCheck 'evidence' PASS "Directory exists: '$($config.EvidenceRoot)'."))
    } else {
        $checks.Add((New-LabReadinessCheck 'evidence' FAIL "Directory is missing: '$($config.EvidenceRoot)'."))
    }
    $hasCachePath = -not [string]::IsNullOrWhiteSpace([string]$config.ModuleCachePath)
    $hasCacheHash = -not [string]::IsNullOrWhiteSpace([string]$config.ModuleCacheSha256)
    if (-not $hasCachePath -and -not $hasCacheHash) {
        $checks.Add((New-LabReadinessCheck 'module-cache-hash' 'NOT RUN' 'No module cache is configured; bootstrap must provide dependencies.'))
    } elseif ($hasCachePath -xor $hasCacheHash) {
        $checks.Add((New-LabReadinessCheck 'module-cache-hash' FAIL 'Configure both ModuleCachePath and ModuleCacheSha256, or leave both blank for cache-free bootstrap.'))
    } elseif (-not (Test-Path -LiteralPath $config.ModuleCachePath -PathType Leaf)) {
        $checks.Add((New-LabReadinessCheck 'module-cache-hash' FAIL "Module cache file is missing: '$($config.ModuleCachePath)'."))
    } else {
        $actualHash = (Get-FileHash -LiteralPath $config.ModuleCachePath -Algorithm SHA256).Hash
        if ($actualHash -eq $config.ModuleCacheSha256) {
            $checks.Add((New-LabReadinessCheck 'module-cache-hash' PASS 'Module cache SHA-256 matches the configured digest.'))
        } else {
            $checks.Add((New-LabReadinessCheck 'module-cache-hash' FAIL 'Module cache SHA-256 does not match the configured digest.'))
        }
    }

    $storedCredential = $null
    try {
        $storedCredential = Get-LabStoredCredential -Target $config.CredentialTarget
        if ($storedCredential -and $storedCredential.UserName -eq $config.GuestUser -and $storedCredential.Password.Length -gt 0) {
            $checks.Add((New-LabReadinessCheck 'credential' PASS "Credential target '$($config.CredentialTarget)' exists for the configured guest user."))
        } elseif ($storedCredential) {
            $checks.Add((New-LabReadinessCheck 'credential' FAIL "Credential target '$($config.CredentialTarget)' exists but its user does not match GuestUser or its password is empty."))
        } else {
            $checks.Add((New-LabReadinessCheck 'credential' FAIL "Credential target '$($config.CredentialTarget)' was not found in Windows Credential Manager."))
        }
    } catch {
        $checks.Add((New-LabReadinessCheck 'credential' FAIL $_.Exception.Message))
    }
    if (-not [string]::IsNullOrEmpty($env:BOOTUPD_LAB_PASSWORD)) {
        $checks.Add((New-LabReadinessCheck 'credential-override' FAIL 'BOOTUPD_LAB_PASSWORD is set and may override the stored lab credential. Clear it before relying on Credential Manager.'))
    } else {
        $checks.Add((New-LabReadinessCheck 'credential-override' PASS 'No BOOTUPD_LAB_PASSWORD override is active.'))
    }

    foreach ($guest in $config.Guests) {
        $vm = $null
        try { $vm = Get-VM -Name $guest.Name -ErrorAction Stop } catch { }
        if (-not $vm) {
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name)" FAIL 'VM was not found.'))
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):authentication" 'NOT RUN' 'VM was not found; guest authentication cannot be tested.'))
            continue
        }
        $isOff = [string]$vm.State -eq 'Off'
        if ($isOff) {
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):state" PASS 'VM is Off as required for checkpoint-based lab runs.'))
        } else {
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):state" FAIL "VM state is '$($vm.State)'; Off is required before restoring/running a checkpoint."))
        }
        $checkpoint = @()
        try { $checkpoint = @(Get-VMCheckpoint -VMName $guest.Name -Name $guest.Checkpoint -ErrorAction SilentlyContinue) } catch { }
        if ($checkpoint.Count -eq 1 -and [string]$checkpoint[0].State -eq 'Off') {
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):checkpoint" PASS "Checkpoint '$($guest.Checkpoint)' exists."))
        } elseif ($checkpoint.Count -eq 1) {
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):checkpoint" FAIL "Checkpoint '$($guest.Checkpoint)' has state '$($checkpoint[0].State)'; Off is required for deterministic restore."))
        } elseif ($checkpoint.Count -gt 1) {
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):checkpoint" FAIL "Checkpoint name '$($guest.Checkpoint)' matches $($checkpoint.Count) checkpoints; the configured checkpoint must resolve uniquely."))
        } else {
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):checkpoint" FAIL "Checkpoint '$($guest.Checkpoint)' is missing."))
        }
        if (-not $Probe) {
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):authentication" 'NOT RUN' 'Authentication probe was not requested; credential presence does not prove guest authentication.'))
        } elseif (-not $isOff) {
            try {
                if (-not $storedCredential) { throw 'No stored guest credential is available.' }
                $psCredential = [pscredential]::new([string]$storedCredential.UserName, $storedCredential.Password)
                $null = Invoke-LabGuestReadOnlyProbe -VMName $guest.Name -Credential $psCredential -TimeoutSeconds $TimeoutSeconds
                $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):authentication" PASS 'Read-only PowerShell Direct authentication succeeded.'))
            } catch {
                $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):authentication" FAIL "Read-only PowerShell Direct probe failed: $($_.Exception.Message)"))
            }
        } else {
            $checks.Add((New-LabReadinessCheck "guest:$($guest.Name):authentication" 'NOT RUN' 'VM is Off; preflight does not start guests.'))
        }
    }

    $failedChecks = @($checks | Where-Object Status -eq 'FAIL')
    $authenticationChecks = @($checks | Where-Object { $_.Name -like 'guest:*:authentication' })
    $failedAuthentication = @($authenticationChecks | Where-Object Status -eq 'FAIL')
    $notRunAuthentication = @($authenticationChecks | Where-Object Status -eq 'NOT RUN')
    $hostFailures = @($failedChecks | Where-Object { $_.Name -notlike 'guest:*:authentication' })
    $guestAuthentication = if ($failedAuthentication.Count) { 'FAIL' } elseif ($notRunAuthentication.Count -or -not $authenticationChecks.Count) { 'NOT RUN' } else { 'PASS' }
    [pscustomobject]@{
        Ready = ($failedChecks.Count -eq 0)
        HostReady = ($hostFailures.Count -eq 0)
        GuestAuthentication = $guestAuthentication
        Checks = $checks.ToArray()
    }
}

# Dot-sourcing exposes the functions to focused Pester tests without running the preflight.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-LabReadiness -Path $ConfigPath -Probe:$ProbeGuest -TimeoutSeconds $ProbeTimeoutSeconds
}
