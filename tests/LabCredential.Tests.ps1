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
}
