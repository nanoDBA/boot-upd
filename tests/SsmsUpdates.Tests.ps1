BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $tokens = $null; $errors = $null
    $invokeAst = [Management.Automation.Language.Parser]::ParseFile($invokePath,[ref]$tokens,[ref]$errors)
    $errors | Should -BeNullOrEmpty
    function Get-SsmsProductionFunctionText {
        param([Parameter(Mandatory)][string]$Name)
        $function = $invokeAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
        $function | Should -Not -BeNullOrEmpty -Because "production function '$Name' must exist"
        $function.Extent.Text
    }
    foreach ($name in @('Write-SsmsUpdateLog','ConvertTo-SsmsVersion','Test-SsmsSafeProviderArgument','Get-SsmsVswherePath','Test-SsmsInstallationHint','Get-SsmsInstances','Get-SsmsJsonDocument','Get-SsmsChannelTarget','Test-SsmsProcessOpen','Find-SsmsInstance','New-SsmsUpdateResult','Register-SsmsRebootEvidence','Get-SsmsPendingUpdate','Save-SsmsPendingUpdate','Confirm-SsmsPendingUpdate','Complete-SsmsUpdateAccounting','Reset-SsmsPendingVerification','Update-SsmsInstances')) {
        . ([scriptblock]::Create((Get-SsmsProductionFunctionText $name)))
    }

    function New-SsmsFixture {
        param(
            [string]$Version = '22.9.11519.84',
            [string]$Path = 'C:\SSMS22',
            [string]$Id = 'ssms-22',
            [bool]$RebootRequired = $false
        )
        [pscustomobject]@{
            InstanceId = $Id; InstallationPath = $Path; InstallationVersion = [version]$Version
            ChannelId = 'SSMS.22.SSMS.Release'; ChannelUri = 'https://example.invalid/channel.json'
            IsComplete = $true; IsLaunchable = $true; IsRebootRequired = $RebootRequired
        }
    }

    function New-SsmsInventory { param([object[]]$Instances = @()) @{ Instances = @($Instances); Absent = (@($Instances).Count -eq 0); Broken = $false; Detail = $null } }
    function New-SsmsRun { param([bool]$Failed = $false, [bool]$TimedOut = $false, [bool]$RebootRequired = $false, [int]$ExitCode = 0, [string[]]$Output = @()) @{ Failed=$Failed; TimedOut=$TimedOut; RebootRequired=$RebootRequired; ExitCode=$ExitCode; Output=@($Output) } }
    function Write-Log { param($Message, $Level, $Visibility) }
    function Set-BootUpdateState { param($State) }
    function Invoke-PackageManagerWithTimeout { param($Name, $Status, $ScriptBlock, $ArgumentList, $IdleTimeoutMinutes, $HardTimeoutMinutes) }
}

Describe 'SSMS native provider contract' {
    BeforeEach {
        $script:CurrentState = $null
        $script:ExplicitRebootRequests = [Collections.Generic.List[object]]::new()
    }

    It 'requires the production updater to contain the provider before release' {
        $function = $invokeAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-SsmsInstances' }, $true)
        $function | Should -Not -BeNullOrEmpty
    }

    It 'treats no SSMS evidence as a no-op' {
        Mock Get-SsmsInstances { New-SsmsInventory }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeTrue
        $result.Count | Should -Be 0
        $result.Triggered | Should -BeFalse
    }

    It 'fails closed when SSMS evidence exists but discovery is broken' {
        Mock Get-SsmsInstances { @{ Instances=@(); Absent=$false; Broken=$true; Detail='vswhere unavailable' } }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeFalse
        $result.TerminalFailure | Should -BeFalse
        $result.AttentionDetails[0].Detail | Should -Match 'vswhere unavailable'
    }

    It 'uses the native setup update contract and waits outside the installer directory' {
        $before = New-SsmsFixture -Version '22.9.11519.84'
        $after = New-SsmsFixture -Version '22.10.12210.168'
        $script:calls = 0
        Mock Get-SsmsInstances { $script:calls++; if ($script:calls -eq 1) { New-SsmsInventory -Instances @($before) } else { New-SsmsInventory -Instances @($after) } }
        Mock Get-SsmsChannelTarget { [pscustomobject]@{ Version=[version]'22.10.12210.168' } }
        Mock Test-Path { $true }
        Mock Test-SsmsProcessOpen { $false }
        Mock Invoke-PackageManagerWithTimeout { New-SsmsRun }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\VSInstaller\setup.exe'
        $result.Success | Should -BeTrue
        $result.Count | Should -Be 1
        Should -Invoke Invoke-PackageManagerWithTimeout -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'SSMS-native-update' -and $IdleTimeoutMinutes -eq 10 -and $ScriptBlock.ToString() -match 'Start-Process' -and
            $ScriptBlock.ToString() -match '-Wait' -and $ScriptBlock.ToString() -match '--installPath' -and
            $ScriptBlock.ToString() -match '--quiet' -and $ScriptBlock.ToString() -match '--norestart' -and
            $ScriptBlock.ToString() -notmatch 'updateall' -and $ScriptBlock.ToString() -notmatch '--wait' -and
            $ScriptBlock.ToString() -match 'GetTempPath'
        }
    }

    It 'does not invoke the installer when the installed SSMS version meets the validated target' {
        $current = New-SsmsFixture -Version '22.10.12210.168'
        Mock Get-SsmsInstances { New-SsmsInventory -Instances @($current) }
        Mock Get-SsmsChannelTarget { [pscustomobject]@{ Version=[version]'22.10.12210.168' } }
        Mock Test-Path { $true }
        Mock Invoke-PackageManagerWithTimeout { throw 'must not run' }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeTrue
        $result.Count | Should -Be 0
        $result.Triggered | Should -BeFalse
        Should -Invoke Invoke-PackageManagerWithTimeout -Times 0
    }

    It 'does not count a zero-exit installer invocation whose version stayed stale' {
        $current = New-SsmsFixture -Version '22.9.11519.84'
        $script:calls = 0
        Mock Get-SsmsInstances { $script:calls++; New-SsmsInventory -Instances @($current) }
        Mock Get-SsmsChannelTarget { [pscustomobject]@{ Version=[version]'22.10.12210.168' } }
        Mock Test-Path { $true }; Mock Test-SsmsProcessOpen { $false }; Mock Invoke-PackageManagerWithTimeout { New-SsmsRun }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeFalse
        $result.Count | Should -Be 0
        $result.AttentionDetails[0].Detail | Should -Match 'did not advance'
    }

    It 'keeps the phase incomplete when setup reports a reboot requirement' {
        $current = New-SsmsFixture -Version '22.9.11519.84'
        Mock Get-SsmsInstances { New-SsmsInventory -Instances @($current) }
        Mock Get-SsmsChannelTarget { [pscustomobject]@{ Version=[version]'22.10.12210.168' } }
        Mock Test-Path { $true }; Mock Test-SsmsProcessOpen { $false }; Mock Invoke-PackageManagerWithTimeout { New-SsmsRun -RebootRequired $true -ExitCode 3010 }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeFalse
        $result.Count | Should -Be 0
        $result.Triggered | Should -BeTrue
    }

    It 'updates every outdated SSMS 22 instance and counts only verified version changes' {
        $first = New-SsmsFixture -Id 'one' -Path 'C:\SSMS-Release' -Version '22.9.11519.84'
        $second = New-SsmsFixture -Id 'two' -Path 'C:\SSMS-Preview' -Version '22.9.12002.56'
        $firstAfter = New-SsmsFixture -Id 'one' -Path 'C:\SSMS-Release' -Version '22.10.12210.168'
        $secondAfter = New-SsmsFixture -Id 'two' -Path 'C:\SSMS-Preview' -Version '22.10.12210.168'
        $script:calls = 0
        Mock Get-SsmsInstances {
            $script:calls++
            switch ($script:calls) { 1 { New-SsmsInventory -Instances @($first,$second) }; 2 { New-SsmsInventory -Instances @($firstAfter,$second) }; default { New-SsmsInventory -Instances @($firstAfter,$secondAfter) } }
        }
        Mock Get-SsmsChannelTarget { [pscustomobject]@{ Version=[version]'22.10.12210.168' } }
        Mock Test-Path { $true }; Mock Test-SsmsProcessOpen { $false }; Mock Invoke-PackageManagerWithTimeout { New-SsmsRun }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeTrue
        $result.Count | Should -Be 2
        Should -Invoke Invoke-PackageManagerWithTimeout -Times 2 -Exactly
    }

    It 'defers safely when SSMS is open and never force-closes it' {
        $current = New-SsmsFixture -Version '22.9.11519.84'
        Mock Get-SsmsInstances { New-SsmsInventory -Instances @($current) }; Mock Get-SsmsChannelTarget { [pscustomobject]@{ Version=[version]'22.10.12210.168' } }
        Mock Test-Path { $true }; Mock Test-SsmsProcessOpen { $true }; Mock Invoke-PackageManagerWithTimeout { throw 'must not run' }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeFalse
        $result.AttentionDetails[0].Detail | Should -Match 'Close SSMS'
        Should -Invoke Invoke-PackageManagerWithTimeout -Times 0
    }

    It 'parses byte-backed channel JSON and accepts consistent duplicate SSMS product entries' {
        $channel = @{
            info = @{ manifestName = 'SSMS.22.SSMS.Release'; buildVersion = '22.10.12210.168' }
            channelItems = @(
                @{ id = 'Microsoft.VisualStudio.Manifests.SSMS'; version = '22.10.12210.168' },
                @{ id = 'Microsoft.VisualStudio.Product.Ssms'; version = '22.10.12210.168' },
                @{ id = 'Microsoft.VisualStudio.Product.Ssms'; version = '22.10.12210.168' }
            )
        } | ConvertTo-Json -Depth 5
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = [Text.Encoding]::UTF8.GetBytes($channel) } }
        $target = Get-SsmsChannelTarget -ChannelUri 'https://example.invalid/ssms-channel' -ChannelId 'SSMS.22.SSMS.Release'
        $target.Version | Should -Be ([version]'22.10.12210.168')
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 45 }
    }

    It 'accepts pretty-printed vswhere JSON but rejects null and shape-less inventory records' {
        $vswhere = Join-Path $TestDrive 'vswhere.cmd'
        $valid = @'
@echo off
echo [
echo   {
echo     "instanceId": "ssms-22",
echo     "productId": "Microsoft.VisualStudio.Product.Ssms",
echo     "installationPath": "C:\\SSMS22",
echo     "installationVersion": "22.9.11519.84",
echo     "channelId": "SSMS.22.SSMS.Release",
echo     "channelUri": "https://example.invalid/channel",
echo     "isComplete": true,
echo     "isLaunchable": true,
echo     "isRebootRequired": false
echo   }
echo ]
'@
        Set-Content -LiteralPath $vswhere -Value $valid -Encoding ascii
        $inventory = Get-SsmsInstances -VswherePath $vswhere
        $inventory.Broken | Should -BeFalse
        $inventory.Instances.Count | Should -Be 1
        foreach ($invalid in @('[null]','[{}]')) {
            Set-Content -LiteralPath $vswhere -Value "@echo off`r`necho $invalid" -Encoding ascii
            $result = Get-SsmsInstances -VswherePath $vswhere
            $result.Broken | Should -BeTrue -Because "$invalid is not absence evidence"
            $result.Absent | Should -BeFalse
        }
    }

    It 'does not verify an update when the post-update instance identity or source changed' -TestCases @(
        @{ Field = 'InstanceId'; Value = 'replacement-id' }
        @{ Field = 'ChannelUri'; Value = 'https://example.invalid/replacement-channel' }
    ) {
        param($Field,$Value)
        $before = New-SsmsFixture -Version '22.9.11519.84'
        $after = New-SsmsFixture -Version '22.10.12210.168'
        $after.$Field = $Value
        $script:calls = 0
        Mock Get-SsmsInstances { $script:calls++; if ($script:calls -eq 1) { New-SsmsInventory -Instances @($before) } else { New-SsmsInventory -Instances @($after) } }
        Mock Get-SsmsChannelTarget { [pscustomobject]@{ Version=[version]'22.10.12210.168' } }
        Mock Test-Path { $true }; Mock Test-SsmsProcessOpen { $false }; Mock Invoke-PackageManagerWithTimeout { New-SsmsRun }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeFalse
        $result.Count | Should -Be 0
        $result.TerminalFailure | Should -BeFalse
    }

    It 'does not verify an update when fresh inventory is unhealthy even at the target version' {
        $before = New-SsmsFixture -Version '22.9.11519.84'
        $after = New-SsmsFixture -Version '22.10.12210.168'; $after.IsLaunchable = $false
        $script:calls = 0
        Mock Get-SsmsInstances { $script:calls++; if ($script:calls -eq 1) { New-SsmsInventory -Instances @($before) } else { New-SsmsInventory -Instances @($after) } }
        Mock Get-SsmsChannelTarget { [pscustomobject]@{ Version=[version]'22.10.12210.168' } }
        Mock Test-Path { $true }; Mock Test-SsmsProcessOpen { $false }; Mock Invoke-PackageManagerWithTimeout { New-SsmsRun }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeFalse
        $result.Count | Should -Be 0
        $result.TerminalFailure | Should -BeFalse
    }

    It 'classifies documented installer-busy results as retryable without closing applications' -TestCases @(
        @{ ExitCode = 1001 }, @{ ExitCode = 1003 }, @{ ExitCode = 1618 }, @{ ExitCode = 8006 }
    ) {
        param($ExitCode)
        $current = New-SsmsFixture -Version '22.9.11519.84'
        Mock Get-SsmsInstances { New-SsmsInventory -Instances @($current) }
        Mock Get-SsmsChannelTarget { [pscustomobject]@{ Version=[version]'22.10.12210.168' } }
        Mock Test-Path { $true }; Mock Test-SsmsProcessOpen { $false }
        Mock Invoke-PackageManagerWithTimeout { New-SsmsRun -Failed $true -ExitCode $ExitCode }
        $result = Update-SsmsInstances -VswherePath 'C:\vswhere.exe' -InstallerPath 'C:\setup.exe'
        $result.Success | Should -BeFalse
        $result.TerminalFailure | Should -BeFalse
        $result.Triggered | Should -BeTrue
        $result.AttentionDetails[0].Detail | Should -Match 'busy'
    }
}
