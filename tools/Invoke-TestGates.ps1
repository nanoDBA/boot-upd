#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$SkipOsBoundary,
    [switch]$SkipPublishedUpgrade,
    [string]$ResultPath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$results = [Collections.Generic.List[object]]::new()

function Invoke-Gate {
    param([string]$Name,[scriptblock]$Action)
    $started = Get-Date
    try {
        & $Action
        $results.Add([pscustomobject]@{ Gate=$Name; Result='passed'; Seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2) })
    } catch {
        $results.Add([pscustomobject]@{ Gate=$Name; Result='failed'; Seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2); Error=$_.Exception.Message })
        throw
    }
}

Push-Location $root
try {
    & ./tools/Repair-LineEndings.ps1
    Invoke-Gate 'unit-and-process-behavior' {
        Import-Module Pester -RequiredVersion 5.7.1
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = 'tests'
        $configuration.Run.ExcludePath = 'tests/integration'
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'Normal'
        $pester = Invoke-Pester -Configuration $configuration
        if ($pester.TotalCount -eq 0 -or $pester.FailedCount) {
            throw "Pester gate failed: $($pester.FailedCount) of $($pester.TotalCount) tests failed."
        }
    }
    if (-not $SkipOsBoundary) {
        Invoke-Gate 'user-system-security-boundary' { & ./tests/integration/Invoke-CrossContextMutexGate.ps1 | Write-Host }
    } else {
        $results.Add([pscustomobject]@{ Gate='user-system-security-boundary'; Result='not_run'; Reason='SkipOsBoundary was specified.' })
    }
    if (-not $SkipPublishedUpgrade) {
        Invoke-Gate 'published-launcher-upgrade' {
            # Pester deliberately exercises process, environment, and launcher
            # state. Verify the published upgrade from a clean PowerShell host so
            # test-runner residue cannot create a false adoption-log failure.
            $engine = (Get-Process -Id $PID).Path
            $gatePath = Join-Path $root 'tests\integration\Invoke-PublishedLauncherUpgradeGate.ps1'
            $gateOutput = & $engine -NoLogo -NoProfile -NonInteractive -File $gatePath 2>&1
            $gateExitCode = $LASTEXITCODE
            $gateOutput | Write-Host
            if ($gateExitCode -ne 0) {
                throw "Published launcher upgrade gate exited $gateExitCode."
            }
        }
    } else {
        $results.Add([pscustomobject]@{ Gate='published-launcher-upgrade'; Result='not_run'; Reason='SkipPublishedUpgrade was specified.' })
    }
} finally {
    Pop-Location
    $report = [pscustomobject]@{ GeneratedAt=(Get-Date).ToUniversalTime().ToString('o'); Computer=$env:COMPUTERNAME; Results=$results.ToArray() }
    $report | ConvertTo-Json -Depth 4 | Write-Host
    if ($ResultPath) {
        $parent = Split-Path $ResultPath -Parent
        if ($parent) { $null = New-Item -ItemType Directory -Path $parent -Force }
        $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding utf8
    }
}
