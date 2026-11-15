function Get-LabScenarioContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('None','HardTimeout','RepeatedWingetFailure')]
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
                RepeatCycles = 2
                WingetPath = "$fixtureRoot\bin"
                ModulePath = "$fixtureRoot\modules"
                WindowsUpdateModule = "$fixtureRoot\modules\PSWindowsUpdate\99.0.0"
                WindowsUpdateModuleTarget = 'C:\Program Files\WindowsPowerShell\Modules\PSWindowsUpdate\99.0.0'
                EvidenceFile = 'C:\ProgramData\BootUpdateCycle\LabFixture.jsonl'
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

    if (-not $Scenario.Mode) { return '' }
    $lines = @(
        '$env:BOOTUPD_LAB_WINGET_MODE = ' + (Quote-LabPowerShellString ([string]$Scenario.Mode))
        '$env:BOOTUPD_LAB_FIXTURE_LOG = ' + (Quote-LabPowerShellString ([string]$Scenario.EvidenceFile))
        '$env:PATH = ' + (Quote-LabPowerShellString ([string]$Scenario.WingetPath + ';')) + ' + $env:PATH'
    )
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
        [Parameter(Mandatory)][ValidateRange(1,20)][int]$Started,
        [Parameter(Mandatory)][ValidateRange(1,20)][int]$Expected
    )
    if ($Completed -ge $Expected) { return 'Complete' }
    if ($Completed -ge $Started) { return 'StartNext' }
    return 'Wait'
}
