BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $repairPath = Join-Path $repoRoot 'Repair-AwsTooling.ps1'
    $repairSource = Get-Content -LiteralPath $repairPath -Raw
    $tokens = $null; $errors = $null
    $repairAst = [Management.Automation.Language.Parser]::ParseFile($repairPath,[ref]$tokens,[ref]$errors)
    $errors | Should -BeNullOrEmpty

    $match = [regex]::Match($repairSource, '(?s)\$scriptBlock\s*=\s*@''\r?\n(?<Body>.*?)\r?\n''@')
    $match.Success | Should -BeTrue
    $childSource = $match.Groups['Body'].Value
    $childTokens = $null; $childErrors = $null
    $childAst = [Management.Automation.Language.Parser]::ParseInput($childSource,[ref]$childTokens,[ref]$childErrors)
    $childErrors | Should -BeNullOrEmpty

    function Get-ChildFunctionText {
        param([Parameter(Mandatory)][string]$Name)
        $function = $childAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        },$true)
        $function | Should -Not -BeNullOrEmpty
        return $function.Extent.Text
    }

    . ([scriptblock]::Create((Get-ChildFunctionText -Name 'Test-AwsToolsPublisherMismatchMessage')))
}

Describe 'AWS.Tools publisher certificate rollover' {
    It 'does not terminate unrelated PowerShell processes' {
        $repairSource | Should -Not -Match 'Stop-Process'
        $repairSource | Should -Not -Match 'Get-Process\s+-Name\s+[''\"]pwsh'
    }

    It 'recognizes only the PowerShellGet AWS.Tools issuer-continuity error' {
        $valid = @'
Authenticode issuer 'CN="Amazon Web Services, Inc.", OU=SDKs and Tools, O="Amazon Web Services, Inc."' of the new module 'AWS.Tools.Common' with version '5.0.256' is not matching with the authenticode issuer 'CN="Amazon Web Services, Inc.", OU=AWS, O="Amazon Web Services, Inc."' of the previously-installed module 'AWS.Tools.Common' with version '4.1.14'.
'@
        Test-AwsToolsPublisherMismatchMessage -Message $valid | Should -BeTrue
    }

    It 'rejects unrelated failures without enabling the bypass' -TestCases @(
        @{ Message='The PSGallery repository is unavailable.' }
        @{ Message='Access to the module path is denied.' }
        @{ Message='The authenticode signature is invalid.' }
        @{ Message="Authenticode issuer 'Evil' of the new module 'Other.Module' is not matching with the authenticode issuer 'Old'." }
        @{ Message="Authenticode issuer 'Evil' of the new module 'AWS.Tools.Common' failed validation." }
        @{ Message="Authenticode issuer 'CN=Evil Corp, O=Evil Corp' of the new module 'AWS.Tools.Common' is not matching with the authenticode issuer 'CN=Evil Corp, O=Evil Corp' of the previously-installed module 'AWS.Tools.Common'." }
    ) {
        param($Message)
        Test-AwsToolsPublisherMismatchMessage -Message $Message | Should -BeFalse
    }

    It 'tries the ordinary cleanup update before considering a rollover fallback' {
        $normal = $childSource.IndexOf('Update-AWSToolsModule -CleanUp -Force -Confirm:$false -ErrorAction Stop')
        $decision = $childSource.IndexOf('Test-AwsToolsPublisherMismatchMessage -Message', $normal)
        $fallback = $childSource.IndexOf('Update-AWSToolsModule -RequiredVersion $candidate.Version -Force -SkipPublisherCheck')
        $normal | Should -BeGreaterThan 0
        $decision | Should -BeGreaterThan $normal
        $fallback | Should -BeGreaterThan $decision
        $childSource | Should -Not -Match 'Update-AWSToolsModule[^\r\n]*-CleanUp[^\r\n]*-SkipPublisherCheck'
    }

    It 'fails closed unless every staged and installed module is Amazon-signed and trusted' {
        $verifier = Get-ChildFunctionText -Name 'Test-AwsToolsSignedModuleDirectory'
        $candidate = Get-ChildFunctionText -Name 'Get-VerifiedAwsToolsRolloverCandidate'
        $verifier | Should -Match 'SignatureStatus\]::Valid'
        $verifier | Should -Match 'Amazon Web Services, Inc'
        $verifier | Should -Match '1\.3\.6\.1\.5\.5\.7\.3\.3'
        $verifier | Should -Match 'X509RevocationMode\]::Online'
        $verifier | Should -Match 'X509VerificationFlags\]::NoFlag'
        $candidate | Should -Match "PSGallery resolves to an unexpected source"
        $candidate | Should -Match 'Save-Module -Name \$moduleName'
        $candidate | Should -Match 'distinctVersions.Count -ne 1'
        $candidate | Should -Match 'Get-AwsToolsDirectoryManifest'
        (Get-ChildFunctionText -Name 'Get-AwsToolsDirectoryManifest') |
            Should -Match "Name -ne 'PSGetModuleInfo\.xml'"
    }

    It 'retains old versions until the installed target passes post-install verification' {
        $fallback = $childSource.IndexOf('Update-AWSToolsModule -RequiredVersion $candidate.Version')
        $postVerify = $childSource.IndexOf('Test-AwsToolsSignedModuleDirectory -ModuleRoot $installed.ModuleBase', $fallback)
        $fullHashVerify = $childSource.IndexOf('Test-AwsToolsDirectoryManifest -ModuleRoot $installed.ModuleBase', $fallback)
        $cleanup = $childSource.IndexOf('Invoke-VerifiedAwsToolsCleanup -ExceptVersion $candidate.Version', $fallback)
        $fallback | Should -BeGreaterThan 0
        $postVerify | Should -BeGreaterThan $fallback
        $fullHashVerify | Should -BeGreaterThan $postVerify
        $cleanup | Should -BeGreaterThan $fullHashVerify
        $childSource | Should -Not -Match 'Where-Object Version -eq \$candidate.Version \| Select-Object -First 1'
    }

    It 'suppresses only exact already-absent cleanup records and inventories stale copies' {
        $cleanup = Get-ChildFunctionText -Name 'Invoke-VerifiedAwsToolsCleanup'
        $cleanup | Should -Match '\^NoMatchFoundForCriteria'
        $cleanup | Should -Match "MyCommand\.Name -eq 'Uninstall-Package'"
        $cleanup | Should -Match 'unexpectedErrors\.Count'
        $cleanup | Should -Match 'Get-Module -ListAvailable'
        $cleanup | Should -Match 'older managed module copies remain'
    }
}
