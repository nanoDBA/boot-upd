#requires -Version 7.0
<##
.SYNOPSIS
    Committed setup and proof actions for PowerShell runtime lab rows D and E.

.DESCRIPTION
    Dot-source this file from an elevated PowerShell 7 session, select a row with
    Get-PowerShellRuntimeLabRow, then splat the returned parameters directly into
    Invoke-LabRow.ps1. The guest setup and proof remain versioned with the code under test.
#>

function Get-PowerShellRuntimeLabRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('A','B','C','D','E')][string]$Row)

    $prepareA = {
        param($User,$Password)
        $ErrorActionPreference = 'Stop'
        $bundle = 'C:\Lab\PowerShellRuntimeAssets\PowerShell-7.7.0.msixbundle'
        $sha = 'e00c349858c2d273f29485541ece91617b435accdd5e3f156d68d5cb97740022'
        New-Item -ItemType Directory -Path (Split-Path -Parent $bundle) -Force | Out-Null
        if (-not (Test-Path -LiteralPath $bundle) -or (Get-FileHash -LiteralPath $bundle).Hash -ine $sha) {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.7.0/PowerShell-7.7.0.msixbundle' -OutFile $bundle
        }
        if ((Get-FileHash -LiteralPath $bundle).Hash -ine $sha) { throw 'PowerShell 7.7.0 bundle hash mismatch.' }
        $legacy = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^PowerShell 7' })
        if (-not $legacy) { throw 'The clean checkpoint no longer has the MSI runtime needed by this row.' }
        Add-AppxPackage -Path $bundle -ErrorAction Stop
        $msix = Get-AppxPackage -Name Microsoft.PowerShell | Where-Object Version -eq '7.7.0.0' | Select-Object -First 1
        if (-not $msix) { throw 'PowerShell 7.7.0 did not register for the row user.' }
        $bootstrapLog = 'C:\Lab\row-a-bootstrap.txt'
        $command = '""C:\Lab\boot-upd\upd.cmd" bootstrap > "{0}" 2>&1"' -f $bootstrapLog
        $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d','/c',$command) -WorkingDirectory 'C:\Lab\boot-upd' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "upd bootstrap exited $($process.ExitCode): $(Get-Content $bootstrapLog -Raw -ErrorAction SilentlyContinue)" }
        $remaining = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^PowerShell 7' })
        if ($remaining.Count) { throw 'The PowerShell MSI entry remains after upd bootstrap.' }
        [pscustomobject]@{ Row='A'; MsixVersion=[string]$msix.Version; BootstrapExit=$process.ExitCode; MsiEntriesRemaining=$remaining.Count; BootstrapOutput=Get-Content $bootstrapLog -Raw }
    }

    $verifyA = {
        $task = Get-ScheduledTask -TaskName 'BootUpdateCycle' -ErrorAction Stop
        $action = [string]$task.Actions.Execute
        if ($action -notmatch '(?i)\\Microsoft\\WindowsApps\\pwsh\.exe$') { throw "Continuation task did not select the WindowsApps alias: $action" }
        [pscustomobject]@{ Row='A'; TaskAction=$action; Alias=Test-Path -LiteralPath $action; Result=if (Test-Path -LiteralPath $action) { 'PASS' } else { 'FAIL' } }
    }

    $prepareB = {
        param($User,$Password)
        $ErrorActionPreference = 'Stop'
        $bundle = 'C:\Lab\PowerShellRuntimeAssets\PowerShell-7.7.0.msixbundle'
        $sha = 'e00c349858c2d273f29485541ece91617b435accdd5e3f156d68d5cb97740022'
        New-Item -ItemType Directory -Path (Split-Path -Parent $bundle) -Force | Out-Null
        if (-not (Test-Path -LiteralPath $bundle) -or (Get-FileHash -LiteralPath $bundle).Hash -ine $sha) {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.7.0/PowerShell-7.7.0.msixbundle' -OutFile $bundle
        }
        if ((Get-FileHash -LiteralPath $bundle).Hash -ine $sha) { throw 'PowerShell 7.7.0 bundle hash mismatch.' }
        Add-AppxPackage -Path $bundle -ErrorAction Stop
        $terminal = Get-Command wt.exe -ErrorAction SilentlyContinue
        if (-not $terminal) {
            $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
            if (-not $winget) { throw 'Windows Terminal is absent and winget is unavailable on this checkpoint.' }
            & $winget.Source install --id Microsoft.WindowsTerminal --exact --source winget --silent --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0) { throw "Windows Terminal install exited $LASTEXITCODE." }
            $terminal = Get-Command wt.exe -ErrorAction SilentlyContinue
        }
        if (-not $terminal) { throw 'Windows Terminal was installed but wt.exe did not register for the row user.' }
        $before = Start-Process -FilePath $terminal.Source -PassThru
        Start-Sleep -Seconds 5
        $command = '""C:\Lab\boot-upd\upd.cmd" bootstrap > "C:\Lab\row-b-bootstrap.txt" 2>&1"'
        $bootstrap = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d','/c',$command) -WorkingDirectory 'C:\Lab\boot-upd' -Wait -PassThru
        if ($bootstrap.ExitCode -ne 0) { throw "upd bootstrap failed with exit $($bootstrap.ExitCode)." }
        Stop-Process -Name WindowsTerminal -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $restarted = Start-Process -FilePath $terminal.Source -PassThru
        $deadline = (Get-Date).AddSeconds(45)
        $child = $null
        do {
            $root = Get-CimInstance Win32_Process -Filter "ProcessId = $($restarted.Id)" -ErrorAction SilentlyContinue
            $ids = @($restarted.Id)
            if ($root) { $ids += @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object ParentProcessId -eq $root.ProcessId | Select-Object -ExpandProperty ProcessId) }
            $child = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.ParentProcessId -and $_.Name -eq 'pwsh.exe' } | Select-Object -First 1
            if (-not $child) { Start-Sleep -Seconds 2 }
        } while (-not $child -and (Get-Date) -lt $deadline)
        if (-not $child) { throw 'Restarted Windows Terminal did not start a PowerShell profile.' }
        [pscustomobject]@{ Row='B'; TerminalBeforeRemoval=$before.Id; TerminalRestarted=$restarted.Id; ChildImage=$child.Name; ChildPath=$child.ExecutablePath; MsiEntriesRemaining=@(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^PowerShell 7' }).Count; Result='PASS' }
    }

    $prepareC = {
        param($User,$Password)
        $ErrorActionPreference = 'Stop'
        $bundle = 'C:\Lab\PowerShellRuntimeAssets\PowerShell-7.7.0.msixbundle'
        $sha = 'e00c349858c2d273f29485541ece91617b435accdd5e3f156d68d5cb97740022'
        New-Item -ItemType Directory -Path (Split-Path -Parent $bundle) -Force | Out-Null
        if (-not (Test-Path -LiteralPath $bundle) -or (Get-FileHash -LiteralPath $bundle).Hash -ine $sha) {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.7.0/PowerShell-7.7.0.msixbundle' -OutFile $bundle
        }
        if ((Get-FileHash -LiteralPath $bundle).Hash -ine $sha) { throw 'PowerShell 7.7.0 bundle hash mismatch.' }
        Add-AppxPackage -Path $bundle -ErrorAction Stop
        $msiPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
        if (-not (Test-Path -LiteralPath $msiPath)) { throw 'The baseline MSI path is not available for the stored-password task scenario.' }
        $taskName = 'Lab-Stored-Credential-Probe'
        $action = New-ScheduledTaskAction -Execute $msiPath -Argument '-NoLogo -NoProfile -Command exit 0'
        $userName = "$env:COMPUTERNAME\$User"
        Register-ScheduledTask -TaskName $taskName -Action $action -User $userName -Password $Password -RunLevel Highest -Force | Out-Null
        $before = (Get-ScheduledTask -TaskName $taskName).Actions.Execute
        $command = '""C:\Lab\boot-upd\upd.cmd" bootstrap > "C:\Lab\row-c-bootstrap.txt" 2>&1"'
        $bootstrap = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d','/c',$command) -WorkingDirectory 'C:\Lab\boot-upd' -Wait -PassThru
        if ($bootstrap.ExitCode -ne 0) { throw "upd bootstrap failed with exit $($bootstrap.ExitCode)." }
        $status = 'C:\Lab\row-c-status.txt'
        $statusCommand = '""C:\Lab\boot-upd\upd.cmd" status > "{0}" 2>&1"' -f $status
        $statusProcess = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d','/c',$statusCommand) -WorkingDirectory 'C:\Lab\boot-upd' -Wait -PassThru
        $after = (Get-ScheduledTask -TaskName $taskName).Actions.Execute
        $statusText = Get-Content $status -Raw
        if ($before -cne $after) { throw 'The stored-password task action was modified.' }
        if ($statusText -notmatch [regex]::Escape((Get-AppxPackage Microsoft.PowerShell | Select-Object -First 1).InstallLocation)) { throw 'upd status did not report the stored-password task replacement path.' }
        [pscustomobject]@{ Row='C'; Task=$taskName; StoredPasswordTaskUnchanged=($before -ceq $after); TaskAction=$after; StatusExit=$statusProcess.ExitCode; StatusReportsReplacement=$true; Result='PASS' }
    }

    $prepareD = {
        $ErrorActionPreference = 'Stop'
        $assetRoot = 'C:\Lab\PowerShellRuntimeAssets'
        New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
        $bundle = Join-Path $assetRoot 'PowerShell-7.6.10.msixbundle'
        $sha = '911e652739e19de80c325fd0cbcc99b00c865536299ed5813844a4083a6d0268'
        if (-not (Test-Path -LiteralPath $bundle) -or (Get-FileHash -LiteralPath $bundle).Hash -ine $sha) {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10.msixbundle' -OutFile $bundle
        }
        if ((Get-FileHash -LiteralPath $bundle).Hash -ine $sha) { throw 'PowerShell 7.6.10 bundle hash mismatch.' }
        $result = 'C:\Lab\row-d-system-package.json'
        Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
        $installer = 'C:\Lab\boot-upd\tests\integration\lab\Install-LabPowerShellPackage.ps1'
        $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -BundlePath "{1}" -Sha256 "{2}" -ResultPath "{3}"' -f $installer,$bundle,$sha,$result)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'Lab-RegisterPowerShellPackage' -Action $taskAction -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName 'Lab-RegisterPowerShellPackage'
        $deadline = (Get-Date).AddMinutes(8)
        while (-not (Test-Path -LiteralPath $result) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
        if (-not (Test-Path -LiteralPath $result)) { throw 'SYSTEM did not register the PowerShell 7.6.10 package.' }
        $package = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
        if ($package.Version -ne '7.6.10.0') { throw "Unexpected SYSTEM package version: $($package.Version)" }
        $oldPath = [string]$package.PwshPath
        $probe = 'C:\Lab\row-d-system-launch.txt'
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        $runAction = New-ScheduledTaskAction -Execute $oldPath -Argument ('-NoLogo -NoProfile -Command "Set-Content -LiteralPath ''{0}'' -Value $PSVersionTable.PSVersion.ToString()"' -f $probe)
        Register-ScheduledTask -TaskName 'Lab-System-Upgrade-Probe' -Action $runAction -Principal $principal -Force | Out-Null
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $oldPath
        [pscustomobject]@{ Row='D'; OldVersion=$package.Version; OldPwshPath=$oldPath; SystemPackageRegistration='PASS'; ProbeTaskAction=(Get-ScheduledTask -TaskName 'Lab-System-Upgrade-Probe').Actions.Execute; OpenSSH=(Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH').DefaultShell }
    }

    $verifyD = {
        $ErrorActionPreference = 'Stop'
        $deadline = (Get-Date).AddMinutes(15)
        $package = $null
        do {
            $package = Get-AppxPackage -AllUsers -Name Microsoft.PowerShell -ErrorAction SilentlyContinue |
                Where-Object { [version]$_.Version -ge [version]'7.7.0.0' } |
                Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
            if (-not $package) { Start-Sleep -Seconds 5 }
        } while (-not $package -and (Get-Date) -lt $deadline)
        if (-not $package) { throw 'The post-cycle runtime upgrade did not register PowerShell 7.7.0 for SYSTEM.' }
        $newPath = Join-Path $package.InstallLocation 'pwsh.exe'
        $task = Get-ScheduledTask -TaskName 'Lab-System-Upgrade-Probe' -ErrorAction Stop
        $shell = [string](Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH').DefaultShell
        if ($task.Actions.Execute -ine $newPath) { throw "SYSTEM task still names the old package path: $($task.Actions.Execute)" }
        if ($shell -ine $newPath) { throw "OpenSSH DefaultShell still names the old package path: $shell" }
        $probe = 'C:\Lab\row-d-system-launch.txt'
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName 'Lab-System-Upgrade-Probe'
        $launchDeadline = (Get-Date).AddMinutes(2)
        while (-not (Test-Path -LiteralPath $probe) -and (Get-Date) -lt $launchDeadline) { Start-Sleep -Seconds 2 }
        if (-not (Test-Path -LiteralPath $probe)) { throw 'The SYSTEM task did not create its launch proof after the MSIX upgrade.' }
        $version = (Get-Content -LiteralPath $probe -Raw).Trim()
        if ($version -notmatch '^7\.7\.') { throw "The SYSTEM task launched an unexpected PowerShell version: $version" }
        [pscustomobject]@{ Row='D'; NewVersion=[string]$package.Version; NewPwshPath=$newPath; TaskAction=$task.Actions.Execute; OpenSSH=$shell; TaskLaunchVersion=$version; Result='PASS' }
    }

    $prepareE = {
        $ErrorActionPreference = 'Stop'
        $assetRoot = 'C:\Lab\PowerShellRuntimeAssets'
        New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
        $oldBundle = Join-Path $assetRoot 'PowerShell-7.6.10.msixbundle'
        $oldSha = '911e652739e19de80c325fd0cbcc99b00c865536299ed5813844a4083a6d0268'
        if (-not (Test-Path -LiteralPath $oldBundle) -or (Get-FileHash -LiteralPath $oldBundle).Hash -ine $oldSha) {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10.msixbundle' -OutFile $oldBundle
        }
        if ((Get-FileHash -LiteralPath $oldBundle).Hash -ine $oldSha) { throw 'PowerShell 7.6.10 bundle hash mismatch.' }
        Add-AppxPackage -Path $oldBundle -ErrorAction Stop
        $old = Get-AppxPackage -Name Microsoft.PowerShell | Where-Object Version -eq '7.6.10.0' | Select-Object -First 1
        if (-not $old) { throw 'PowerShell 7.6.10 was not registered for the row user.' }
        $oldPath = Join-Path $old.InstallLocation 'pwsh.exe'
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $probe = 'C:\Lab\row-e-system-launch.txt'
        $action = New-ScheduledTaskAction -Execute $oldPath -Argument ('-NoLogo -NoProfile -Command "Set-Content -LiteralPath ''{0}'' -Value $PSVersionTable.PSVersion.ToString()"' -f $probe)
        Register-ScheduledTask -TaskName 'Lab-System-Upgrade-Probe' -Action $action -Principal $principal -Force | Out-Null
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $oldPath
        $newBundle = Join-Path $assetRoot 'PowerShell-7.7.0.msixbundle'
        $newSha = 'e00c349858c2d273f29485541ece91617b435accdd5e3f156d68d5cb97740022'
        if (-not (Test-Path -LiteralPath $newBundle) -or (Get-FileHash -LiteralPath $newBundle).Hash -ine $newSha) {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.7.0/PowerShell-7.7.0.msixbundle' -OutFile $newBundle
        }
        if ((Get-FileHash -LiteralPath $newBundle).Hash -ine $newSha) { throw 'PowerShell 7.7.0 bundle hash mismatch.' }
        Add-AppxPackage -Path $newBundle -ErrorAction Stop
        $new = Get-AppxPackage -Name Microsoft.PowerShell | Where-Object Version -eq '7.7.0.0' | Select-Object -First 1
        if (-not $new) { throw 'The outside upgrade did not register PowerShell 7.7.0.' }
        [pscustomobject]@{ Row='E'; UpgradeSource='PowerShell release MSIX, outside boot-upd'; OldVersion=[string]$old.Version; OldPwshPath=$oldPath; NewVersion=[string]$new.Version; NewPwshPath=(Join-Path $new.InstallLocation 'pwsh.exe'); SeededTaskAction=(Get-ScheduledTask -TaskName 'Lab-System-Upgrade-Probe').Actions.Execute; SeededOpenSSH=(Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH').DefaultShell }
    }

    $verifyE = {
        $ErrorActionPreference = 'Stop'
        $package = Get-AppxPackage -AllUsers -Name Microsoft.PowerShell -ErrorAction Stop |
            Where-Object { [version]$_.Version -ge [version]'7.7.0.0' } |
            Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
        if (-not $package) { throw 'PowerShell 7.7.0 is not installed after the outside upgrade.' }
        $newPath = Join-Path $package.InstallLocation 'pwsh.exe'
        $task = Get-ScheduledTask -TaskName 'Lab-System-Upgrade-Probe' -ErrorAction Stop
        $shell = [string](Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH').DefaultShell
        if ($task.Actions.Execute -ine $newPath) { throw "upd startup did not repoint the SYSTEM task: $($task.Actions.Execute)" }
        if ($shell -ine $newPath) { throw "upd startup did not repoint OpenSSH DefaultShell: $shell" }
        [pscustomobject]@{ Row='E'; InstalledVersion=[string]$package.Version; InstalledPwshPath=$newPath; TaskAction=$task.Actions.Execute; OpenSSH=$shell; Result='PASS' }
    }

    if ($Row -eq 'A') {
        return @{ VMName='lab-b'; Row='A-bootstrap-final'; Checkpoint='baseline-clean'; SystemContext=$false; Launcher='upd'; DeployArgs='run --no-update'; ArmReboots=0; TimeoutMinutes=60; PrepareAction=$prepareA; InjectWhen='BOOT UPDATE CYCLE STARTED'; InjectAction=$verifyA }
    }
    if ($Row -eq 'B') {
        return @{ VMName='lab-b'; Row='B-terminal-final'; Checkpoint='baseline-clean'; SystemContext=$false; Launcher='upd'; DeployArgs='run --no-update'; ArmReboots=0; TimeoutMinutes=45; PrepareAction=$prepareB }
    }
    if ($Row -eq 'C') {
        return @{ VMName='lab-b'; Row='C-stored-password-final'; Checkpoint='baseline-clean'; SystemContext=$false; Launcher='upd'; DeployArgs='run --no-update'; ArmReboots=0; TimeoutMinutes=45; PrepareAction=$prepareC }
    }
    if ($Row -eq 'D') {
        return @{
            VMName='lab-b'; Row='D-system-msix-upgrade'; Checkpoint='baseline-no-autologon'; SystemContext=$true
            Launcher='deploy'; DeployArgs='-DisableSelfUpdate'; TimeoutMinutes=60
            PrepareAction=$prepareD; InjectWhen='PowerShell runtime: checking for a newer PowerShell 7'; InjectAction=$verifyD
        }
    }
    return @{
        VMName='lab-b'; Row='E-external-msix-upgrade'; Checkpoint='baseline-clean'; SystemContext=$false
        Launcher='upd'; DeployArgs='run --no-update'; TimeoutMinutes=60
        PrepareAction=$prepareE; InjectWhen='BOOT UPDATE CYCLE STARTED'; InjectAction=$verifyE
    }
}
