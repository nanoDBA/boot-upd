BeforeAll {
    $readinessPath = Join-Path $PSScriptRoot 'integration\lab\Test-LabReadiness.ps1'
    . $readinessPath

    function New-LabReadinessFixture {
        param([Parameter(Mandatory)][string]$Root)

        $source = Join-Path $Root 'source'
        $evidence = Join-Path $Root 'evidence'
        $null = New-Item -ItemType Directory -Path $source, $evidence, (Join-Path $source 'tests/integration/lab') -Force
        $gitOutput = & git init --quiet $source 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not create fixture Git checkout: $gitOutput" }
        foreach ($file in 'Invoke-BootUpdateCycle.ps1', 'Deploy-BootUpdateCycle.ps1', 'upd.cmd', 'tests/integration/lab/Invoke-LabRow.ps1', 'tests/integration/lab/LabCredential.ps1') {
            Set-Content -LiteralPath (Join-Path $source $file) -Value '# fixture'
        }
        $configPath = Join-Path $Root 'lab.local.json'
        [ordered]@{
            CredentialTarget='fixture-target'; GuestUser='updtest'; SourceRoot=$source
            EvidenceRoot=$evidence; ModuleCachePath=''; ModuleCacheSha256=''
            Guests=@(@{ Name='lab-a'; Checkpoint='fresh' })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath
        return $configPath
    }

    function New-LabReadinessFixtureSecureString {
        $secure = [Security.SecureString]::new()
        foreach ($character in 'fixture'.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        return $secure
    }
}

Describe 'Hyper-V lab readiness preflight' {
    It 'validates the machine-local config schema and rejects secret properties' {
        $path = Join-Path $TestDrive 'lab.local.json'
        @'
{"CredentialTarget":"lab-secret","GuestUser":"updtest","SourceRoot":"src","EvidenceRoot":"evidence","ModuleCachePath":"cache.zip","ModuleCacheSha256":"","Guests":[{"Name":"lab-a","Checkpoint":"fresh"}]}
'@ | Set-Content -LiteralPath $path

        $config = Read-LabReadinessConfig -Path $path
        $config.CredentialTarget | Should -Be 'lab-secret'
        { Read-LabReadinessConfig -Path (Join-Path $PSScriptRoot 'integration\lab\lab.local.example.json') } | Should -Not -Throw
        $config.GuestPassword = 'must-not-be-stored-here'
        $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path
        { Read-LabReadinessConfig -Path $path } | Should -Throw '*Store secrets in Windows Credential Manager*'
    }

    It 'returns a structured failure when the local config is absent' {
        $result = Invoke-LabReadiness -Path (Join-Path $TestDrive 'missing.json')

        $result.Ready | Should -BeFalse
        $result.Checks.Count | Should -Be 1
        $result.Checks[0].Status | Should -Be 'FAIL'
        $result.Checks[0].Name | Should -Be 'config'
    }

    It 'does not start an Off guest when authentication probing is requested' {
        $configPath = New-LabReadinessFixture -Root $TestDrive

        Mock Get-LabStoredCredential { [pscredential]::new('updtest', (New-LabReadinessFixtureSecureString)) }
        Mock Get-VM { [pscustomobject]@{ Name='lab-a'; State='Off' } }
        Mock Get-VMCheckpoint { [pscustomobject]@{ Name='fresh'; State='Off' } }
        Mock Invoke-LabGuestReadOnlyProbe { throw 'an Off guest must never be probed' }

        $previousPassword = $env:BOOTUPD_LAB_PASSWORD
        try {
            $env:BOOTUPD_LAB_PASSWORD = $null
            $result = Invoke-LabReadiness -Path $configPath -Probe
        } finally {
            $env:BOOTUPD_LAB_PASSWORD = $previousPassword
        }

        ($result.Checks | Where-Object Name -eq 'guest:lab-a:state').Status | Should -Be 'PASS'
        ($result.Checks | Where-Object Name -eq 'guest:lab-a:authentication').Status | Should -Be 'NOT RUN'
        ($result.Checks | Where-Object Name -eq 'credential-override').Status | Should -Be 'PASS'
        ($result.Checks | Where-Object Name -eq 'module-cache-hash').Status | Should -Be 'NOT RUN'
        $result.GuestAuthentication | Should -Be 'NOT RUN'
        Assert-MockCalled Invoke-LabGuestReadOnlyProbe -Times 0 -Exactly
    }

    It 'fails when the selected checkpoint is not Off' {
        $configPath = New-LabReadinessFixture -Root $TestDrive
        Mock Get-LabStoredCredential { [pscredential]::new('updtest', (New-LabReadinessFixtureSecureString)) }
        Mock Get-VM { [pscustomobject]@{ Name='lab-a'; State='Off' } }
        Mock Get-VMCheckpoint { [pscustomobject]@{ Name='fresh'; State='Running' } }
        $previousPassword = $env:BOOTUPD_LAB_PASSWORD
        try {
            $env:BOOTUPD_LAB_PASSWORD = $null
            $result = Invoke-LabReadiness -Path $configPath
        } finally {
            $env:BOOTUPD_LAB_PASSWORD = $previousPassword
        }

        $result.Ready | Should -BeFalse
        ($result.Checks | Where-Object Name -eq 'guest:lab-a:checkpoint').Status | Should -Be 'FAIL'
        ($result.Checks | Where-Object Name -eq 'guest:lab-a:checkpoint').Message | Should -Match 'Off is required'
    }

    It 'limits a running guest probe with a bounded PowerShell job' {
        $completedJob = Start-Job -ScriptBlock { 'LAB-A' }
        $completedJob | Wait-Job | Out-Null
        Mock Invoke-Command { $completedJob }
        Mock Wait-Job { $completedJob }
        Mock Receive-Job { 'LAB-A' }
        Mock Remove-Job {}
        $credential = [pscredential]::new('updtest', (New-LabReadinessFixtureSecureString))

        Invoke-LabGuestReadOnlyProbe -VMName 'lab-a' -Credential $credential -TimeoutSeconds 7 | Should -BeTrue

        Assert-MockCalled Wait-Job -Times 1 -Exactly -ParameterFilter { $Timeout -eq 7 }
        Assert-MockCalled Invoke-Command -Times 1 -Exactly -ParameterFilter { $VMName -eq 'lab-a' -and $AsJob }
        Assert-MockCalled Remove-Job -Times 1 -Exactly
        Microsoft.PowerShell.Core\Remove-Job -Job $completedJob -Force -ErrorAction SilentlyContinue
    }
}
