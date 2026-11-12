BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $tokens = $null
    $errors = $null
    $script:invokeAst = [Management.Automation.Language.Parser]::ParseFile($invokePath, [ref]$tokens, [ref]$errors)
    $errors | Should -BeNullOrEmpty
    $script:invokeText = Get-Content -LiteralPath $invokePath -Raw
    $script:deployText = Get-Content -LiteralPath (Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1') -Raw
    $script:launcherText = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/Invoke-UpdLauncher.ps1') -Raw

    function Get-FunctionText {
        param([Parameter(Mandatory)][string]$Name)
        $function = $script:invokeAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
        $function | Should -Not -BeNullOrEmpty -Because "production function '$Name' must exist"
        return $function.Extent.Text
    }
    foreach ($name in 'Get-WindowsUpdateVerificationScope','Get-WindowsUpdateOfferScanScriptBlock',
                      'ConvertFrom-WindowsUpdateOfferScanOutput','Select-WindowsUpdateOffer','Write-WindowsUpdateOfferLog') {
        . ([scriptblock]::Create((Get-FunctionText $name)))
    }
    $script:WindowsUpdateUpgradesCategoryId = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'
    function Write-Log { param($Message, $Level = 'Info', $Visibility = 'Normal') $script:LogLines.Add([pscustomobject]@{ Message = $Message; Level = $Level; Visibility = $Visibility }) }

    <# What the Windows Update Agent offered the machine this fix was written on, 2026-11-06,
       as the scan worker prints it: four optional vendor drivers and the 26H2 feature update
       (category Upgrades, DeploymentAction OptionalInstallation, already downloaded). #>
    $script:Offer26H2 = 'BOOTUPDATE_OFFER|2b22470a-8b6f-498f-9c88-66f7b9fb56b1|1|1|OptionalInstallation|KB5127648|1|96742|Upgrades|Windows 11, version 26H2'
    $script:OfferDriver = 'BOOTUPDATE_OFFER|dac82a19-f9ba-459d-a30a-f56d4b326faa|3|0|OptionalInstallation||0|1|Drivers|Example vendor - System - 11.7.0.1000'
    $script:OfferCumulative = 'BOOTUPDATE_OFFER|11111111-2222-3333-4444-555555555555|200|1|Installation|KB5066835|0|700|Security Updates;Windows 11|2026-11 Cumulative Update for Windows 11 Version 25H2 (KB5066835)'
    $script:OfferPreview = 'BOOTUPDATE_OFFER|66666666-7777-8888-9999-000000000000|1|0|OptionalInstallation|KB5070000|0|650|Updates;Windows 11|2026-11 Cumulative Update Preview for Windows 11 Version 25H2 (KB5070000)'
    $script:OfferSql = 'BOOTUPDATE_OFFER|abababab-abab-abab-abab-abababababab|1|1|Installation|KB5055000|0|300|Security Updates;SQL Server 2022|Security Update for SQL Server 2022 (KB5055000)'
}

Describe 'The Windows Update scope is one criteria string' {
    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[object]]::new()
        $script:ExcludePatterns = @()
        $script:SkipFeatureUpdates = $false
    }

    It 'includes everything Windows Update would install itself plus optional feature updates by default' {
        $scope = Get-WindowsUpdateVerificationScope
        $scope.IncludeFeatureUpdates | Should -BeTrue
        $scope.Criteria | Should -Match "IsInstalled=0 and IsHidden=0 and Type='Software' and DeploymentAction='Installation'"
        $scope.Criteria | Should -Match "DeploymentAction='OptionalInstallation' and CategoryIDs contains '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'"
        $scope.Criteria | Should -Not -Match 'Drivers' -Because 'drivers stay with the opt-in phase'
    }

    It 'drops the optional feature-update clause under -SkipFeatureUpdates and changes the signature' {
        $default = Get-WindowsUpdateVerificationScope
        $script:SkipFeatureUpdates = $true
        $skipped = Get-WindowsUpdateVerificationScope
        $skipped.IncludeFeatureUpdates | Should -BeFalse
        $skipped.Criteria | Should -Not -Match 'OptionalInstallation'
        $skipped.Criteria | Should -Match "DeploymentAction='Installation'"
        $skipped.Signature | Should -Not -Be $default.Signature -Because 'cached zero-work evidence from one scope must not satisfy the other'
    }

    It 'keeps SQL Server and operator exclusions out of the title filter' {
        $script:ExcludePatterns = @('Preview')
        (Get-WindowsUpdateVerificationScope).ExcludedTitle | Should -Be 'SQL|Preview'
    }

    It 'is the only place the Windows Update phase defines its scope' {
        $script:invokeText | Should -Not -Match '-RootCategories [@$]' -Because 'the PSWindowsUpdate category post-filter is what hid the feature update'
        $script:invokeText | Should -Not -Match 'RootCategories\s*=' -Because 'nor may it come back through the install parameter set'
        $script:invokeText | Should -Not -Match "'Security Updates','Critical Updates'" -Because 'no category allowlist may come back'
        $install = Get-FunctionText 'Install-WindowsUpdates'
        $install | Should -Match 'Criteria = \$verificationScope\.Criteria'
        $prefetch = $script:invokeText.Substring($script:invokeText.IndexOf('Windows Update prefetch (2uj)'))
        $prefetch.Substring(0, 2500) | Should -Match '-Criteria \$Criteria'
        $prefetch.Substring(0, 2500) | Should -Match '\$prefetchScope\.Criteria'
        $final = Get-FunctionText 'Test-WindowsUpdateConvergence'
        $final | Should -Match 'Invoke-WindowsUpdateOfferScan -Scope \$verificationScope -Online'
    }
}

Describe 'The scan worker output is parsed under a completion contract' {
    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[object]]::new()
        $script:ExcludePatterns = @()
        $script:SkipFeatureUpdates = $false
    }

    It 'parses every field of an offer record' {
        $parsed = ConvertFrom-WindowsUpdateOfferScanOutput -Output @($script:Offer26H2, $script:OfferDriver, 'BOOTUPDATE_SCAN_COMPLETE|2')
        $parsed.Verified | Should -BeTrue
        @($parsed.Offers).Count | Should -Be 2
        $fu = $parsed.Offers | Where-Object Title -eq 'Windows 11, version 26H2'
        $fu.UpdateID | Should -Be '2b22470a-8b6f-498f-9c88-66f7b9fb56b1'
        $fu.RevisionNumber | Should -Be 1
        $fu.InScope | Should -BeTrue
        $fu.DeploymentAction | Should -Be 'OptionalInstallation'
        $fu.KB | Should -Be 'KB5127648'
        $fu.IsDownloaded | Should -BeTrue
        $fu.SizeMB | Should -Be 96742
        @($fu.Categories) | Should -Be @('Upgrades')
        $driver = $parsed.Offers | Where-Object { @($_.Categories) -contains 'Drivers' }
        $driver.InScope | Should -BeFalse
        $driver.KB | Should -Be ''
    }

    It 'withholds when the worker count disagrees, errors, times out or fails' {
        (ConvertFrom-WindowsUpdateOfferScanOutput -Output @($script:Offer26H2, 'BOOTUPDATE_SCAN_COMPLETE|2')).Verified | Should -BeFalse
        (ConvertFrom-WindowsUpdateOfferScanOutput -Output @('BOOTUPDATE_ERROR|boom', 'BOOTUPDATE_SCAN_COMPLETE|0')).Error | Should -Be 'boom'
        (ConvertFrom-WindowsUpdateOfferScanOutput -Output @() -TimedOut $true -TimeoutDetail 'final scan timed out').Error | Should -Be 'final scan timed out'
        (ConvertFrom-WindowsUpdateOfferScanOutput -Output @('BOOTUPDATE_SCAN_COMPLETE|0') -Failed $true).Verified | Should -BeFalse
        (ConvertFrom-WindowsUpdateOfferScanOutput -Output @()).Verified | Should -BeFalse -Because 'no completion marker means the worker did not finish'
    }

    It 'treats a clean empty scan as verified with no offers and ignores foreign lines' {
        $parsed = ConvertFrom-WindowsUpdateOfferScanOutput -Output @('System.__ComObject', 'BOOTUPDATE_APPLICABLE||', 'BOOTUPDATE_SCAN_COMPLETE|0')
        $parsed.Verified | Should -BeTrue
        @($parsed.Offers).Count | Should -Be 0
    }

    It 'searches twice with the Windows Update Agent and marks membership by UpdateID' {
        $worker = (Get-WindowsUpdateOfferScanScriptBlock).ToString()
        $worker | Should -Match 'Microsoft\.Update\.Session'
        $worker | Should -Match '\$searcher\.Search\(\[string\]\$ScopeCriteria\)'
        $worker | Should -Match "DeploymentAction='OptionalInstallation'\)`"\)" -Because 'the broad search must see optional offers to report them'
        $worker | Should -Match '\$searcher\.Online = \[bool\]\$Online'
    }
}

Describe 'Offers are selected with a reason for everything left alone' {
    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[object]]::new()
        $script:ExcludePatterns = @()
        $script:SkipFeatureUpdates = $false
        $script:Parsed = ConvertFrom-WindowsUpdateOfferScanOutput -Output @(
            $script:Offer26H2, $script:OfferDriver, $script:OfferCumulative, $script:OfferPreview, $script:OfferSql, 'BOOTUPDATE_SCAN_COMPLETE|5')
        $script:Parsed.Verified | Should -BeTrue
    }

    It 'takes the cumulative update and the feature update, and names why the rest stays' {
        $selection = Select-WindowsUpdateOffer -Offers $script:Parsed.Offers -Scope (Get-WindowsUpdateVerificationScope)
        @($selection.Applicable | ForEach-Object Title) | Should -Be @('Windows 11, version 26H2', '2026-11 Cumulative Update for Windows 11 Version 25H2 (KB5066835)')
        $selection.HasFeatureUpdate | Should -BeTrue
        $reasons = @{}
        foreach ($offer in $selection.OutOfScope) { $reasons[$offer.Title] = $offer.Reason }
        $reasons['Example vendor - System - 11.7.0.1000'] | Should -Match '^driver; opt in with -IncludeDriverUpdates'
        $reasons['2026-11 Cumulative Update Preview for Windows 11 Version 25H2 (KB5070000)'] | Should -Match '^optional; Windows Update does not install it on its own'
        $reasons['Security Update for SQL Server 2022 (KB5055000)'] | Should -Be 'excluded by title pattern'
    }

    It 'explains a feature update left to Windows Update when -SkipFeatureUpdates is set' {
        $script:SkipFeatureUpdates = $true
        $scope = Get-WindowsUpdateVerificationScope
        <# With the clause gone the worker would not have marked 26H2 in scope either. #>
        $offers = @($script:Parsed.Offers | ForEach-Object { if ($_.Title -eq 'Windows 11, version 26H2') { $_.InScope = $false }; $_ })
        $selection = Select-WindowsUpdateOffer -Offers $offers -Scope $scope
        $selection.HasFeatureUpdate | Should -BeFalse
        ($selection.OutOfScope | Where-Object Title -eq 'Windows 11, version 26H2').Reason | Should -Be 'feature update; -SkipFeatureUpdates is set'
    }

    It 'sets aside a KB that already installed successfully during this run' {
        $selection = Select-WindowsUpdateOffer -Offers $script:Parsed.Offers -Scope (Get-WindowsUpdateVerificationScope) -SkipKbArticleIds @('KB5066835')
        @($selection.Applicable | ForEach-Object Title) | Should -Be @('Windows 11, version 26H2')
        ($selection.OutOfScope | Where-Object KB -eq 'KB5066835').Reason | Should -Be 'installed successfully earlier in this run'
    }

    It 'logs in-scope offers and non-driver exclusions at Normal and drivers at Verbose' {
        $selection = Select-WindowsUpdateOffer -Offers $script:Parsed.Offers -Scope (Get-WindowsUpdateVerificationScope)
        Write-WindowsUpdateOfferLog -Selection $selection
        $fuLine = $script:LogLines | Where-Object Message -like 'Windows Update offers: Windows 11, version 26H2*'
        $fuLine.Message | Should -Match 'feature update, optionalinstallation, up to 94\.5 GB, downloaded'
        $fuLine.Visibility | Should -Be 'Normal'
        ($script:LogLines | Where-Object Message -like '*Example vendor*').Visibility | Should -Be 'Verbose'
        ($script:LogLines | Where-Object Message -like '*Cumulative Update Preview*').Visibility | Should -Be 'Normal'
        ($script:LogLines | Where-Object Message -like '*Cumulative Update Preview*').Message | Should -Match 'outside scope'
    }

    It 'marks Windows cumulative updates, in either title style, as OS updates and nothing else' {
        $offers = @(
            [pscustomobject]@{ UpdateID='a'; RevisionNumber=1; Title='2026-09 Security Update (KB5129195) (26100.9457)'; KB='KB5129195'; Categories=@('Security Updates'); DeploymentAction='Installation'; IsDownloaded=$false; SizeMB=92365; InScope=$true }
            [pscustomobject]@{ UpdateID='b'; RevisionNumber=1; Title='2026-11 Cumulative Update for Windows 11 Version 25H2 (KB5066835)'; KB='KB5066835'; Categories=@('Security Updates'); DeploymentAction='Installation'; IsDownloaded=$false; SizeMB=900; InScope=$true }
            [pscustomobject]@{ UpdateID='c'; RevisionNumber=1; Title='2026-10 .NET Framework Security Update (KB5127690)'; KB='KB5127690'; Categories=@('Security Updates'); DeploymentAction='Installation'; IsDownloaded=$false; SizeMB=185; InScope=$true }
            [pscustomobject]@{ UpdateID='d'; RevisionNumber=1; Title='Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.463.271.0)'; KB='KB2267602'; Categories=@('Definition Updates'); DeploymentAction='Installation'; IsDownloaded=$false; SizeMB=1536; InScope=$true }
        )
        $selection = Select-WindowsUpdateOffer -Offers $offers -Scope (Get-WindowsUpdateVerificationScope)
        @($selection.Applicable | Where-Object IsOsUpdate | ForEach-Object KB) | Should -Be @('KB5129195', 'KB5066835')
        $selection.HasOsUpdate | Should -BeTrue
        $selection.HasFeatureUpdate | Should -BeFalse
        (Select-WindowsUpdateOffer -Offers @($offers[2], $offers[3]) -Scope (Get-WindowsUpdateVerificationScope)).HasOsUpdate | Should -BeFalse
    }

    It 'handles an empty scan and a null offer without inventing work' {
        $selection = Select-WindowsUpdateOffer -Offers @($null) -Scope (Get-WindowsUpdateVerificationScope)
        @($selection.Applicable).Count | Should -Be 0
        @($selection.OutOfScope).Count | Should -Be 0
        $selection.HasFeatureUpdate | Should -BeFalse
    }
}

Describe 'The install phase scans first, then budgets by what it found' {
    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[object]]::new()
        $script:ExcludePatterns = @()
        $script:SkipFeatureUpdates = $false
    }

    It 'runs the read-only scan before the install call and skips the call when nothing is applicable' {
        $install = Get-FunctionText 'Install-WindowsUpdates'
        $scanAt = $install.IndexOf('Invoke-WindowsUpdateOfferScan -Scope $verificationScope -Online')
        $installAt = $install.IndexOf("Invoke-BootUpdateBackgroundOperation -Name 'Installing Windows Updates'")
        $scanAt | Should -BeGreaterThan 0
        $scanAt | Should -BeLessThan $installAt
        $install | Should -Match 'if \(@\(\$selection\.Applicable\)\.Count -eq 0\)'
        $install | Should -Match '\$postSearchZero = \$true'
        $install | Should -Match 'throw "the pre-install scan did not complete' -Because 'an unverified scan is a phase failure, not a free pass'
    }

    It 'raises the hard timeout to the long budget only when a feature or cumulative update is in scope' {
        $install = Get-FunctionText 'Install-WindowsUpdates'
        $install | Should -Match '\$installTimeoutMinutes = \$script:PackageTimeoutMinutes'
        $install | Should -Match '(?s)if \(\$selection\.HasOsUpdate\) \{.*?\$installTimeoutMinutes = \[math\]::Max\(\[int\]\$script:FeatureUpdateTimeoutMinutes, \[int\]\$script:PackageTimeoutMinutes\)'
        $install | Should -Match '-TimeoutMinutes \$installTimeoutMinutes -ScriptBlock'
    }

    It 'passes the successful-KB set to both the selection and the install command' {
        $install = Get-FunctionText 'Install-WindowsUpdates'
        $install | Should -Match '-SkipKbArticleIds \$successfulKbIds'
        $install | Should -Match '\$params\.NotKBArticleID\s*=\s*\$successfulKbIds'
    }
}

Describe 'The new options travel through every launch path' {
    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[object]]::new()
        $script:ExcludePatterns = @()
        $script:SkipFeatureUpdates = $false
    }

    It 'declares the parameters and copies them to script scope' {
        $script:invokeText | Should -Match '\[switch\]\$SkipFeatureUpdates,'
        $script:invokeText | Should -Match '\[ValidateRange\(30,1440\)\]\s*\[int\]\$FeatureUpdateTimeoutMinutes = 240'
        $script:invokeText | Should -Match '\$script:SkipFeatureUpdates\s*=\s*\$SkipFeatureUpdates'
        $script:invokeText | Should -Match '\$script:FeatureUpdateTimeoutMinutes = \$FeatureUpdateTimeoutMinutes'
    }

    It 'forwards them to the resume task, the remote config and the launch contract' {
        $script:invokeText | Should -Match '"-FeatureUpdateTimeoutMinutes \$\(\$script:FeatureUpdateTimeoutMinutes\)"'
        $script:invokeText | Should -Match 'if \(\$script:SkipFeatureUpdates\)\s+\{ \$taskArgs \+= ''-SkipFeatureUpdates'' \}'
        $script:invokeText | Should -Match "'SkipFeatureUpdates', 'FeatureUpdateTimeoutMinutes'"
        (Get-FunctionText 'Get-BootUpdateLaunchContract') | Should -Match 'if \(\$script:SkipFeatureUpdates\)\s+\{ ''FeatureUpdates'' \}'
    }

    It 'reaches the deployment script in both the direct and the scheduled path' {
        $script:deployText | Should -Match '\[switch\]\$SkipFeatureUpdates,'
        $script:deployText | Should -Match '\[ValidateRange\(30,1440\)\]\[int\]\$FeatureUpdateTimeoutMinutes,'
        $script:deployText | Should -Match 'SkipFeatureUpdates\s*=\s*\$Config\.SkipFeatureUpdates'
        $script:deployText | Should -Match 'FeatureUpdateTimeoutMinutes = \$Config\.FeatureUpdateTimeoutMin'
        $script:deployText | Should -Match 'if \(\$Config\.SkipFeatureUpdates\)\s+\{ \$taskArgs \+= ''-SkipFeatureUpdates'' \}'
        $script:deployText | Should -Match '"-FeatureUpdateTimeoutMinutes \$\(\$Config\.FeatureUpdateTimeoutMin\)"'
    }

    It 'is spelled for the launcher as --skip-feature-updates and --feature-timeout' {
        $script:launcherText | Should -Match '\[Alias\(''no-fu'',''skip-feature-updates''\)\]\[switch\]\$SkipFeatureUpdates'
        $script:launcherText | Should -Match '\[Alias\(''feature-timeout'',''feature-update-timeout-minutes''\)\]\[ValidateRange\(30,1440\)\]\[int\]\$FeatureUpdateTimeoutMinutes = 240'
        $script:launcherText | Should -Match "SkipFeatureUpdates='SkipFeatureUpdates'"
        $script:launcherText | Should -Match 'FeatureUpdateTimeoutMinutes = \$FeatureUpdateTimeoutMinutes'
        $script:launcherText | Should -Match '--skip-feature-updates\s+Leave new Windows versions'
        $script:launcherText | Should -Match '--feature-timeout <minutes>'
    }
}
