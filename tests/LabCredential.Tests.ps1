BeforeAll {
    $credentialPath = Join-Path $PSScriptRoot 'integration\lab\LabCredential.ps1'
    . $credentialPath
}

Describe 'Boot-upd lab credential helpers' {
    It 'converts plaintext input to a SecureString that round-trips' {
        $value = ' fixture password ''quoted'' "double" Café '
        $outputs = @(ConvertTo-BootUpdLabSecureString -Value $value)

        $outputs.Count | Should -Be 1
        $outputs[0] | Should -BeOfType [Security.SecureString]
        (New-Object System.Net.NetworkCredential('', $outputs[0])).Password | Should -Be $value
    }

    It 'keeps the environment override ahead of credential storage for custom targets' {
        $previous = $env:BOOTUPD_LAB_PASSWORD
        try {
            Mock -CommandName Initialize-BootUpdLabCredentialModule -MockWith { throw 'credential store should not be touched' }
            $env:BOOTUPD_LAB_PASSWORD = 'environment-fixture-password'
            Get-BootUpdLabPassword -Target 'custom-fixture-target' | Should -Be $env:BOOTUPD_LAB_PASSWORD
            Assert-MockCalled Initialize-BootUpdLabCredentialModule -Times 0 -Exactly
        } finally {
            $env:BOOTUPD_LAB_PASSWORD = $previous
        }
    }

    It 'dot-sources without emitting credential material' {
        $outputs = @(. $credentialPath)
        $outputs | Should -BeNullOrEmpty
    }

    It 'stores a new password without writing plaintext to the pipeline' {
        Mock -CommandName Initialize-BootUpdLabCredentialModule {}
        Mock -CommandName Get-BootUpdLabStoredCredential { $null }
        Mock -CommandName Set-BootUpdLabStoredCredential {}

        $outputs = @(Set-BootUpdLabPassword -Password 'new-fixture-password' -Target 'fixture-target')

        $outputs | Should -BeNullOrEmpty
        Assert-MockCalled Set-BootUpdLabStoredCredential -Times 1 -Exactly
    }

    It 'preserves an existing credential unless Replace is explicit' {
        Mock -CommandName Initialize-BootUpdLabCredentialModule {}
        Mock -CommandName Get-BootUpdLabStoredCredential { [pscustomobject]@{ Target = 'fixture-target' } }
        Mock -CommandName Set-BootUpdLabStoredCredential {}

        { Set-BootUpdLabPassword -Password 'replacement-fixture-password' -Target 'fixture-target' } |
            Should -Throw '*already exists*'

        Assert-MockCalled Set-BootUpdLabStoredCredential -Times 0 -Exactly
    }

    It 'replaces an existing credential only when Replace is explicit' {
        Mock -CommandName Initialize-BootUpdLabCredentialModule {}
        Mock -CommandName Get-BootUpdLabStoredCredential { [pscustomobject]@{ Target = 'fixture-target' } }
        Mock -CommandName Set-BootUpdLabStoredCredential {}

        $outputs = @(Set-BootUpdLabPassword -Password 'replacement-fixture-password' -Target 'fixture-target' -Replace)

        $outputs | Should -BeNullOrEmpty
        Assert-MockCalled Set-BootUpdLabStoredCredential -Times 1 -Exactly
    }

    It 'does not emit a generated password unless RevealGeneratedPassword is explicit' {
        Mock -CommandName Initialize-BootUpdLabCredentialModule {}
        Mock -CommandName Get-BootUpdLabStoredCredential { $null }
        Mock -CommandName Set-BootUpdLabStoredCredential {}

        $outputs = @(Set-BootUpdLabPassword -Generate -Length 28 -Target 'fixture-target')

        $outputs | Should -BeNullOrEmpty
        Assert-MockCalled Set-BootUpdLabStoredCredential -Times 1 -Exactly
    }

    It 'allows generated plaintext output only with the explicit reveal switch' {
        Mock -CommandName Initialize-BootUpdLabCredentialModule {}
        Mock -CommandName Get-BootUpdLabStoredCredential { $null }
        Mock -CommandName Set-BootUpdLabStoredCredential {}

        $outputs = @(Set-BootUpdLabPassword -Generate -Length 28 -Target 'fixture-target' -RevealGeneratedPassword)

        $outputs.Count | Should -Be 1
        $outputs[0] | Should -Match '^[a-zA-Z0-9_-]{28}$'
        Assert-MockCalled Set-BootUpdLabStoredCredential -Times 1 -Exactly
    }

    It 'initializes a missing stored credential without output or implicit environment persistence' {
        Mock -CommandName Initialize-BootUpdLabCredentialModule {}
        Mock -CommandName Get-BootUpdLabStoredCredential { $null }
        Mock -CommandName Set-BootUpdLabPassword {}
        $previous = $env:BOOTUPD_LAB_PASSWORD
        try {
            $env:BOOTUPD_LAB_PASSWORD = 'environment-override-fixture'

            $outputs = @(Initialize-BootUpdLabCredential -Target 'fixture-target')

            $outputs | Should -BeNullOrEmpty
            Assert-MockCalled Set-BootUpdLabPassword -Times 1 -Exactly -ParameterFilter {
                $Generate -and $Target -eq 'fixture-target'
            }
        } finally {
            $env:BOOTUPD_LAB_PASSWORD = $previous
        }
    }

    It 'reuses an existing stored credential and returns only optional nonsecret status' {
        Mock -CommandName Initialize-BootUpdLabCredentialModule {}
        Mock -CommandName Get-BootUpdLabStoredCredential { [pscustomobject]@{ Target = 'fixture-target' } }
        Mock -CommandName Set-BootUpdLabPassword { throw 'existing credentials must not be changed' }

        $result = Initialize-BootUpdLabCredential -Target 'fixture-target' -PassThru

        $result.Created | Should -BeFalse
        $result.Target | Should -Be 'fixture-target'
        ($result | Get-Member -MemberType NoteProperty).Name | Should -Be @('Created', 'Target')
        Assert-MockCalled Set-BootUpdLabPassword -Times 0 -Exactly
    }
}
