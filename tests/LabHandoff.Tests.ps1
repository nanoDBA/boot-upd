BeforeAll {
    $harness = Join-Path $PSScriptRoot 'integration/lab/Invoke-LabRow.ps1'
    $source = Split-Path $PSScriptRoot -Parent
    # Stubs let the failure-path tests run on CI without Hyper-V installed.
    function Get-VM { param($Name) }
    function Get-VMSnapshot { param($VMName,$Name) }
    function Restore-VMCheckpoint { param($VMName,$Name,[switch]$Confirm) }
}

Describe 'Lab row refuses unsafe starts and retains evidence' {
    BeforeEach {
        $oldProgramData = $env:ProgramData
        $env:ProgramData = $TestDrive
        $guestId = [guid]::NewGuid()
        Mock Get-VM { [pscustomobject]@{Id=$guestId;State='Off'} }
        Mock Get-VMSnapshot { [pscustomobject]@{State='Off'} }
        Mock Restore-VMCheckpoint { throw 'fixture restore stop' }
        $argsForRow = @{ VMName='fixture-vm'; Row='fixture'; SourceRoot=$source
            EvidenceRoot=(Join-Path $TestDrive 'evidence'); GuestPassword='fixture-only' }
    }
    AfterEach { $env:ProgramData = $oldProgramData }

    It 'does not restore a running guest' {
        Mock Get-VM { [pscustomobject]@{Id=$guestId;State='Running'} }
        { & $harness @argsForRow } | Should -Throw '*Cold restore requires guest Off*'
        Should -Invoke Restore-VMCheckpoint -Times 0 -Exactly
    }

    It 'rejects a row label that could escape its evidence directory' {
        $argsForRow.Row = '../escape'
        { & $harness @argsForRow } | Should -Throw '*simple label*'
        Should -Invoke Restore-VMCheckpoint -Times 0 -Exactly
    }

    It 'rejects a saved running-state checkpoint before restoring it' {
        Mock Get-VMSnapshot { [pscustomobject]@{State='Running'} }
        { & $harness @argsForRow } | Should -Throw '*cold (Off) checkpoint*'
        Should -Invoke Restore-VMCheckpoint -Times 0 -Exactly
    }

    It 'rejects a mismatched cache before touching the VM' {
        $cache = Join-Path $TestDrive 'cache.zip'
        Set-Content $cache 'fixture'
        { & $harness @argsForRow -ModuleCachePath $cache -ModuleCacheSha256 ('0' * 64) } |
            Should -Throw '*Host module cache hash mismatch*'
        Should -Invoke Restore-VMCheckpoint -Times 0 -Exactly
    }

    It 'blocks a competing row while the OS file lease is held' {
        $locks = Join-Path $TestDrive 'BootUpdateCycle-Lab/locks'
        New-Item -ItemType Directory $locks -Force | Out-Null
        $lease = [IO.File]::Open((Join-Path $locks "$guestId.lock"),'OpenOrCreate','ReadWrite','None')
        try {
            { & $harness @argsForRow } | Should -Throw '*exclusive VM lease*'
            Should -Invoke Restore-VMCheckpoint -Times 0 -Exactly
        } finally { $lease.Dispose() }
    }

    It 'releases the lease after failure and records failed attempts without credentials' {
        { & $harness @argsForRow } | Should -Throw '*fixture restore stop*'
        { & $harness @argsForRow } | Should -Throw '*fixture restore stop*'
        Should -Invoke Restore-VMCheckpoint -Times 2 -Exactly
        $manifests = @(Get-ChildItem $argsForRow.EvidenceRoot -Recurse -Filter run-manifest.json)
        $manifests.Count | Should -Be 2
        foreach ($file in $manifests) {
            $raw = Get-Content $file.FullName -Raw
            $raw | Should -Not -Match 'fixture-only'
            ($raw | ConvertFrom-Json).Status | Should -Be 'InterruptedOrFailed'
        }
    }

    It 'omits deliberately deleted tracked files from the source manifest' {
        $fixtureRepo = Join-Path $TestDrive 'source'
        New-Item -ItemType Directory $fixtureRepo | Out-Null
        Set-Content (Join-Path $fixtureRepo 'Invoke-BootUpdateCycle.ps1') '# fixture only'
        $removedFile = Join-Path $fixtureRepo 'removed.ps1'
        Set-Content $removedFile '# deliberately removed'
        & git -C $fixtureRepo init --quiet
        & git -C $fixtureRepo add .
        & git -C $fixtureRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
        if ($LASTEXITCODE -ne 0) { throw 'Cannot create fixture Git repository' }
        Remove-Item -LiteralPath $removedFile -Force
        $argsForRow.SourceRoot = $fixtureRepo
        { & $harness @argsForRow } | Should -Throw '*fixture restore stop*'
        $manifestFile = Get-ChildItem $argsForRow.EvidenceRoot -Recurse -Filter run-manifest.json | Select-Object -Last 1
        $manifest = Get-Content $manifestFile.FullName -Raw | ConvertFrom-Json
        @($manifest.SourceFiles.Path) | Should -Contain 'Invoke-BootUpdateCycle.ps1'
        @($manifest.SourceFiles.Path) | Should -Not -Contain 'removed.ps1'
    }
}
