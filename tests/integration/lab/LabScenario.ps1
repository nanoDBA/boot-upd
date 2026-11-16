function Get-LabScenarioContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('None','HardTimeout','RepeatedWingetFailure','SystemNpm')]
        [string]$Scenario
    )

    $fixtureRoot = 'C:\Lab\boot-upd\tests\integration\lab\fixtures'
    switch ($Scenario) {
        'HardTimeout' {
            return [pscustomobject]@{
                Mode = 'hang'
                RepeatCycles = 1
                WingetPath = "$fixtureRoot\bin"
                ModulePath = "$fixtureRoot\modules"
                WindowsUpdateModule = "$fixtureRoot\modules\PSWindowsUpdate\99.0.0"
                WindowsUpdateModuleTarget = 'C:\Program Files\WindowsPowerShell\Modules\PSWindowsUpdate\99.0.0'
                EvidenceFile = 'C:\ProgramData\BootUpdateCycle\LabFixture.jsonl'
            }
        }
        'RepeatedWingetFailure' {
            return [pscustomobject]@{
                Mode = 'repeat-failure'
                Version = '2.0'
                RepeatCycles = 3
                WingetPath = "$fixtureRoot\bin"
                ModulePath = "$fixtureRoot\modules"
                WindowsUpdateModule = "$fixtureRoot\modules\PSWindowsUpdate\99.0.0"
                WindowsUpdateModuleTarget = 'C:\Program Files\WindowsPowerShell\Modules\PSWindowsUpdate\99.0.0'
                EvidenceFile = 'C:\ProgramData\BootUpdateCycle\LabFixture.jsonl'
            }
        }
        'SystemNpm' {
            return [pscustomobject]@{
                Mode = $null
                Version = $null
                RepeatCycles = 1
                WingetPath = $null
                NpmPath = "$fixtureRoot\bin"
                NpmEvidenceFile = 'C:\ProgramData\BootUpdateCycle\LabNpmFixture.jsonl'
                ModulePath = "$fixtureRoot\modules"
                WindowsUpdateModule = "$fixtureRoot\modules\PSWindowsUpdate\99.0.0"
                WindowsUpdateModuleTarget = 'C:\Program Files\WindowsPowerShell\Modules\PSWindowsUpdate\99.0.0'
                EvidenceFile = $null
            }
        }
        default {
            return [pscustomobject]@{
                Mode = $null
                RepeatCycles = 1
                WingetPath = $null
                ModulePath = $null
                WindowsUpdateModule = $null
                WindowsUpdateModuleTarget = $null
                EvidenceFile = $null
            }
        }
    }
}

function Get-LabScenarioEnvironmentPrefix {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Scenario)

    $lines = @()
    if ($Scenario.Mode) {
        $lines += '$env:BOOTUPD_LAB_WINGET_MODE = [Environment]::GetEnvironmentVariable("BOOTUPD_LAB_WINGET_MODE","Machine")'
        $lines += '$env:BOOTUPD_LAB_WINGET_VERSION = [Environment]::GetEnvironmentVariable("BOOTUPD_LAB_WINGET_VERSION","Machine")'
        $lines += '$env:BOOTUPD_LAB_FIXTURE_LOG = [Environment]::GetEnvironmentVariable("BOOTUPD_LAB_FIXTURE_LOG","Machine")'
    }
    if ($Scenario.NpmEvidenceFile) {
        $lines += '$env:BOOTUPD_LAB_NPM_FIXTURE_LOG = [Environment]::GetEnvironmentVariable("BOOTUPD_LAB_NPM_FIXTURE_LOG","Machine")'
    }
    if ($Scenario.WingetPath -or $Scenario.NpmPath) {
        $lines += '$env:Path = [Environment]::GetEnvironmentVariable("BOOTUPD_LAB_FIXTURE_PATH","Machine") + ";" + $env:Path'
    }
    if ($Scenario.ModulePath) {
        $lines += '$env:PSModulePath = ' + (Quote-LabPowerShellString ([string]$Scenario.ModulePath + ';')) + ' + $env:PSModulePath'
    }
    return ($lines -join '; ') + '; '
}

function Quote-LabPowerShellString {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-LabScenarioCycleAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0,20)][int]$Completed,
        [ValidateRange(0,20)][int]$ManualAttentionCount = 0,
        [Parameter(Mandatory)][ValidateRange(1,20)][int]$Started,
        [Parameter(Mandatory)][ValidateRange(1,20)][int]$Expected
    )
    $settled = $Completed + $ManualAttentionCount
    if ($Started -ge $Expected -and $settled -ge $Started) { return 'Complete' }
    if ($settled -ge $Started) { return 'StartNext' }
    return 'Wait'
}

function Get-LabScenarioCycleFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Scenario,
        [Parameter(Mandatory)][ValidateRange(1,20)][int]$CycleNumber
    )

    if ($Scenario.Mode -eq 'repeat-failure' -and $CycleNumber -ge 3) {
        return [pscustomobject]@{ Mode='success'; Version='3.0' }
    }

    return [pscustomobject]@{ Mode=[string]$Scenario.Mode; Version=[string]$Scenario.Version }
}

function Test-LabManualAttentionEvidence {
    [CmdletBinding()]
    param([string[]]$Lines = @())

    return @($Lines | Where-Object {
        $_ -match '(?i)(?:Persistent non-transient failure requires manual attention|manual attention is required|requires manual attention|manual-attention handoff|Stop.*manual attention)'
    }).Count -gt 0
}

function Get-LabNpmFixtureSummary {
    [CmdletBinding()]
    param([object[]]$Records = @())

    return @($Records | ForEach-Object {
        [pscustomobject]@{
            Context = if ([string]$_.Identity -match '(?i)^NT AUTHORITY\\SYSTEM$') { 'SYSTEM' } else { 'signed-in user' }
            Arguments = @($_.Arguments | ForEach-Object { [string]$_ })
        }
    })
}
