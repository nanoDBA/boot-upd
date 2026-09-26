[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$LabGuestName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-GateCondition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Chocolatey {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Action
    )

    Write-Host "--- $Action"
    & $Executable @Arguments 2>&1 | ForEach-Object { Write-Host "$_" }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Chocolatey $Action failed with exit code $exitCode."
    }
}

# This script may uninstall only its randomly named local fixture. Requiring all three
# guest facts prevents a host invocation or an accidental run on an ordinary workstation.
Assert-GateCondition ($env:COMPUTERNAME -ieq $LabGuestName) `
    "Refusing to run: COMPUTERNAME '$env:COMPUTERNAME' does not match -LabGuestName '$LabGuestName'."

$computer = Get-CimInstance -ClassName Win32_ComputerSystem
Assert-GateCondition ($computer.Model -eq 'Virtual Machine') `
    "Refusing to run: expected Hyper-V Model 'Virtual Machine', found '$($computer.Model)'."
Assert-GateCondition ($computer.Manufacturer -match '^Microsoft(?: Corporation)?$') `
    "Refusing to run: expected Microsoft Hyper-V Manufacturer, found '$($computer.Manufacturer)'."
Assert-GateCondition (Test-Path -LiteralPath 'C:\Lab\boot-upd' -PathType Container) `
    'Refusing to run: deployed source directory C:\Lab\boot-upd is missing.'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-GateCondition ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'Run this gate from an elevated PowerShell Direct session in the disposable guest.'

$choco = Get-Command -Name choco.exe -ErrorAction SilentlyContinue
if (-not $choco) { $choco = Get-Command -Name choco -ErrorAction SilentlyContinue }
Assert-GateCondition ($null -ne $choco) 'Chocolatey CLI (choco.exe) is not installed in the guest.'

$chocolateyRoot = $env:ChocolateyInstall
if ([string]::IsNullOrWhiteSpace($chocolateyRoot)) {
    $chocolateyRoot = Join-Path $env:ProgramData 'chocolatey'
}
$registrationRoot = Join-Path $chocolateyRoot 'lib'

$runId = [guid]::NewGuid().ToString('N')
$packageId = "bootupd-choco-record-gate-$runId"
$tempRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $env:TEMP).Path)
$runRootName = "BootUpdateCycle-ChocoRecordGate-$runId"
$runRoot = Join-Path $tempRoot $runRootName
$sourceRoot = Join-Path $runRoot 'source'
$toolsRoot = Join-Path $sourceRoot 'tools'
$appRoot = Join-Path $runRoot 'installed-app'
$appFile = Join-Path $appRoot 'fixture.txt'
$uninstallSentinel = Join-Path $runRoot 'uninstall-sentinel.txt'
$registrationPath = Join-Path $registrationRoot $packageId
$packageNuspec = Join-Path $sourceRoot "$packageId.nuspec"
$chocoExe = $choco.Source
$fixtureInstalled = $false
$failure = $null
$result = $null

try {
    $null = New-Item -ItemType Directory -Path $toolsRoot -Force

    $installScript = @'
$ErrorActionPreference = 'Stop'
$appDirectory = '__APP_DIRECTORY__'
$appPath = '__APP_FILE__'
$null = New-Item -ItemType Directory -Path $appDirectory -Force
Set-Content -LiteralPath $appPath -Value 'external application fixture' -Encoding UTF8
'@
    $installScript = $installScript.Replace('__APP_DIRECTORY__', $appRoot.Replace("'", "''"))
    $installScript = $installScript.Replace('__APP_FILE__', $appFile.Replace("'", "''"))

    $uninstallScript = @'
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath '__UNINSTALL_SENTINEL__' -Value 'chocolateyUninstall.ps1 ran' -Encoding UTF8
if (Test-Path -LiteralPath '__APP_FILE__') {
    Remove-Item -LiteralPath '__APP_FILE__' -Force
}
'@
    $uninstallScript = $uninstallScript.Replace('__UNINSTALL_SENTINEL__', $uninstallSentinel.Replace("'", "''"))
    $uninstallScript = $uninstallScript.Replace('__APP_FILE__', $appFile.Replace("'", "''"))

    Set-Content -LiteralPath (Join-Path $toolsRoot 'chocolateyInstall.ps1') -Value $installScript -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $toolsRoot 'chocolateyUninstall.ps1') -Value $uninstallScript -Encoding UTF8

    $nuspec = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>$packageId</id>
    <version>1.0.0</version>
    <title>Boot Update Cycle Chocolatey Record Removal Gate Fixture</title>
    <authors>Boot Update Cycle integration gate</authors>
    <description>Local disposable fixture for Chocolatey package record removal behavior.</description>
  </metadata>
  <files>
    <file src="tools\**" target="tools" />
  </files>
</package>
"@
    Set-Content -LiteralPath $packageNuspec -Value $nuspec -Encoding UTF8

    Invoke-Chocolatey -Executable $chocoExe -Arguments @(
        'pack', $packageNuspec, '--outputdirectory', $sourceRoot, '--no-progress'
    ) -Action 'pack local fixture'

    $packageFile = Join-Path $sourceRoot "$packageId.1.0.0.nupkg"
    Assert-GateCondition (Test-Path -LiteralPath $packageFile -PathType Leaf) `
        "Chocolatey pack did not create expected package '$packageFile'."
    Assert-GateCondition (-not (Test-Path -LiteralPath $registrationPath)) `
        "Refusing to touch pre-existing Chocolatey registration '$registrationPath'."

    Invoke-Chocolatey -Executable $chocoExe -Arguments @(
        'install', $packageId, '--yes', '--source', $sourceRoot, '--no-progress'
    ) -Action 'install control fixture from local source'
    $fixtureInstalled = $true
    Assert-GateCondition (Test-Path -LiteralPath $appFile -PathType Leaf) `
        'Control install did not create the external application fixture.'
    Assert-GateCondition ((Get-Content -LiteralPath $appFile -Raw).Trim() -eq 'external application fixture') `
        'Control install created unexpected external application fixture content.'

    Invoke-Chocolatey -Executable $chocoExe -Arguments @(
        'uninstall', $packageId, '--yes', '--no-progress'
    ) -Action 'normal uninstall control'
    $fixtureInstalled = $false
    Assert-GateCondition (Test-Path -LiteralPath $uninstallSentinel -PathType Leaf) `
        'Control failed: normal uninstall did not run chocolateyUninstall.ps1.'
    Assert-GateCondition (-not (Test-Path -LiteralPath $registrationPath)) `
        'Control failed: normal uninstall left the Chocolatey package registration.'
    Assert-GateCondition (-not (Test-Path -LiteralPath $appFile)) `
        'Control failed: normal uninstall did not remove the external application fixture.'

    Remove-Item -LiteralPath $uninstallSentinel -Force
    Invoke-Chocolatey -Executable $chocoExe -Arguments @(
        'install', $packageId, '--yes', '--source', $sourceRoot, '--no-progress'
    ) -Action 'reinstall fixture for record-removal case'
    $fixtureInstalled = $true
    Assert-GateCondition (Test-Path -LiteralPath $appFile -PathType Leaf) `
        'Reinstall did not restore the external application fixture.'
    Assert-GateCondition (-not (Test-Path -LiteralPath $uninstallSentinel)) `
        'The uninstall sentinel unexpectedly exists before the record-removal case.'

    Invoke-Chocolatey -Executable $chocoExe -Arguments @(
        'uninstall', $packageId, '--yes', '--skip-autouninstaller', '--skip-powershell', '--no-progress'
    ) -Action 'record-only uninstall with production-intended switches'
    $fixtureInstalled = $false

    Assert-GateCondition (-not (Test-Path -LiteralPath $registrationPath)) `
        'Record-removal case failed: Chocolatey package registration remains.'
    Assert-GateCondition (-not (Test-Path -LiteralPath $uninstallSentinel)) `
        'Record-removal case failed: chocolateyUninstall.ps1 ran despite --skip-powershell.'
    Assert-GateCondition (Test-Path -LiteralPath $appFile -PathType Leaf) `
        'Record-removal case failed: external application fixture was removed.'
    Assert-GateCondition ((Get-Content -LiteralPath $appFile -Raw).Trim() -eq 'external application fixture') `
        'Record-removal case failed: external application fixture content changed.'

    $result = [pscustomobject]@{
        Result = 'PASS'
        Guest = $env:COMPUTERNAME
        Control = 'normal uninstall ran chocolateyUninstall.ps1 and removed package registration'
        RecordRemoval = 'registration removed; uninstall sentinel absent; external app fixture retained'
        Command = "choco uninstall $packageId -y --skip-autouninstaller --skip-powershell"
        Limitations = 'Does not exercise registry-based auto-uninstaller behavior or AWS publisher rollover.'
        AwsPublisherRollover = 'NOT RUN (local Chocolatey package-record behavior only)'
    }
}
catch {
    $failure = $_
    throw
}
finally {
    # Cleanup is constrained to this unique package ID and the files created below this
    # unique run directory. Never use `all`, broad package searches, or updates.
    if ($fixtureInstalled -or (Test-Path -LiteralPath $registrationPath)) {
        try {
            Invoke-Chocolatey -Executable $chocoExe -Arguments @(
                'uninstall', $packageId, '--yes', '--skip-autouninstaller', '--skip-powershell', '--no-progress'
            ) -Action 'cleanup fixture registration'
        }
        catch {
            throw "Cleanup failed for fixture package '$packageId' under '$runRoot': $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $runRoot) {
        $resolvedRunRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $runRoot).Path)
        $tempRootPrefix = $tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $isWithinTempRoot = $resolvedRunRoot.StartsWith($tempRootPrefix, [StringComparison]::OrdinalIgnoreCase)
        $hasExpectedUniqueName = [IO.Path]::GetFileName($resolvedRunRoot) -ceq $runRootName
        Assert-GateCondition ($isWithinTempRoot -and $hasExpectedUniqueName) `
            "Refusing recursive cleanup outside the unique fixture directory under '$tempRoot'."
        Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force
    }
    if ($null -ne $failure) {
        Write-Host 'Chocolatey record-removal gate: FAIL' -ForegroundColor Red
    }
}

$result
