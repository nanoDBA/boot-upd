BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $exportPath = Join-Path $repoRoot 'Export-BootUpdateDiagnostics.ps1'
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $exportTokens=$null; $exportErrors=$null
    $exportAst = [Management.Automation.Language.Parser]::ParseFile($exportPath,[ref]$exportTokens,[ref]$exportErrors)
    $exportErrors | Should -BeNullOrEmpty
    $invokeTokens=$null; $invokeErrors=$null
    $invokeAst = [Management.Automation.Language.Parser]::ParseFile($invokePath,[ref]$invokeTokens,[ref]$invokeErrors)
    $invokeErrors | Should -BeNullOrEmpty
    function Get-FunctionText {
        param($Ast,[string]$Name)
        $function = $Ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name },$true)
        $function | Should -Not -BeNullOrEmpty
        return $function.Extent.Text
    }
    foreach ($name in @('Protect-BootUpdateDiagnosticText','Assert-BootUpdateDiagnosticIsSanitized')) {
        . ([scriptblock]::Create((Get-FunctionText -Ast $exportAst -Name $name)))
    }
    foreach ($name in @('Enable-BootUpdateNtfsCompression','Invoke-BootUpdateLogRotation')) {
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name $name)))
    }
}

Describe 'Sanitized diagnostic export' {
    It 'redacts identity, organization, machine, network, and path material' {
        $raw = @'
[Info] CONTOSO\Jane.Doe on SECRET-PC
[Info] C:\Users\Jane.Doe\OneDrive - Contoso\Private Client\tool.exe
[Info] jane.doe@contoso.example https://internal.contoso.example/api?token=secret 10.20.30.40
[Info] S-1-5-21-123456789-123456789-123456789-1001 HKLM:\SOFTWARE\Contoso\Agent
'@
        $values = @('CONTOSO','Jane.Doe','SECRET-PC','Contoso','contoso.example','internal.contoso.example')
        $safe = Protect-BootUpdateDiagnosticText -Text $raw -SensitiveValues $values
        { Assert-BootUpdateDiagnosticIsSanitized -Text $safe -SensitiveValues $values } | Should -Not -Throw
        $safe | Should -Not -Match 'Jane|CONTOSO|SECRET-PC|contoso\.example|C:\\|10\.20\.30\.40|S-1-5-21'
        $safe | Should -Match '<REDACTED>|<PATH>|<EMAIL>|<URL>|<IP>|<SID>|<REGISTRY_PATH>'
    }

    It 'retains safe pending-cleanup provenance while redacting the underlying path' {
        $raw = '[Warn] Pending-file cleanup advisory [after updates]: EdgeUpdateCleanup=1, DropboxRecoveryCleanup=2; id=0123456789AB. Source C:\Program Files\Dropbox\secret.exe'
        $safe = Protect-BootUpdateDiagnosticText -Text $raw
        $safe | Should -Match 'EdgeUpdateCleanup=1, DropboxRecoveryCleanup=2'
        $safe | Should -Match 'id=0123456789AB'
        $safe | Should -Match '<PATH>'
        $safe | Should -Not -Match 'Dropbox\\secret'
    }

    It 'exports active and archived core, provider, and AWS logs into one safe zip' {
        $source = Join-Path $TestDrive 'source'; $output = Join-Path $TestDrive 'output'
        New-Item -ItemType Directory -Path $source,$output | Out-Null
        Set-Content (Join-Path $source 'BootUpdateCycle.log') '[Info] ACME\Alice on BUILD-PC at C:\Users\Alice\work\tool.exe'
        Set-Content (Join-Path $source 'BootUpdateCycle.providers.20260721-010203.log') '[Winget] alice@acme.example 192.168.10.4'
        Set-Content (Join-Path $source 'BootUpdateCycle.aws.log') '[AWS] E:\OneDrive\ACME Holdings\PowerShell\Modules'
        Set-Content (Join-Path $source 'BootUpdateCycle-winget-quarantine.json') '[{"PackageId":"Corsair.iCUE.5","UnpinCommand":"winget pin remove --id Corsair.iCUE.5 -e --disable-interactivity"}]'
        Set-Content (Join-Path $source 'BootUpdateCycle-winget-resolved-absent.json') '[{"SchemaVersion":2,"PackageId":"Microsoft.WindowsPCHealthCheck","Scope":"machine","FailureCode":1605,"ObservedVersion":"4.0","OutcomeKey":"microsoft.windowspchealthcheck|machine|1605|4.0|msi-unknown-product","Evidence":"MSI_ERROR_UNKNOWN_PRODUCT"}]'
        $redactions = @('ACME','Alice','BUILD-PC','acme.example','ACME Holdings')
        $exportArguments = @{
            SourceDirectory = $source; OutputDirectory = $output; AdditionalRedaction = $redactions
            NoClipboard = $true
        }
        $display = & $exportPath @exportArguments 6>&1
        $zip = @(Get-ChildItem -LiteralPath $output -Filter 'BootUpdateCycle-diagnostics-*.zip')[0]
        $zip | Should -Not -BeNullOrEmpty
        ($display -join "`n") | Should -Match ([regex]::Escape($zip.FullName))
        @($display | Where-Object { $_ -is [IO.FileInfo] }).Count | Should -Be 0
        $expanded = Join-Path $TestDrive 'expanded'
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expanded
        $safe = Get-Content (Join-Path $expanded 'BootUpdateCycle.sanitized.log') -Raw
        $safe | Should -Match 'BootUpdateCycle\.aws\.log'
        $safe | Should -Match 'BootUpdateCycle\.providers\.20260721-010203\.log'
        $safe | Should -Match 'BootUpdateCycle-winget-quarantine\.json'
        $safe | Should -Match 'BootUpdateCycle-winget-resolved-absent\.json'
        $safe | Should -Match 'winget pin remove --id Corsair\.iCUE\.5'
        $safe | Should -Not -Match 'ACME|Alice|BUILD-PC|acme\.example|C:\\|E:\\|192\.168\.10\.4'
        (Get-Content (Join-Path $expanded 'manifest.json') -Raw | ConvertFrom-Json).Sanitized | Should -BeTrue
    }

    It 'copies the one absolute ZIP path to the clipboard with a graceful fallback' {
        $source = Get-Content -LiteralPath $exportPath -Raw
        $source | Should -Match 'Set-Clipboard -Value \$Text'
        $source | Should -Match '\$Text \| & clip\.exe'
        $source | Should -Match 'Full ZIP path copied to the clipboard'
        $source | Should -Match 'could not be copied to the clipboard'
    }
}

Describe 'Bounded compressed log lifecycle' {
    It 'rotates independently and retains only three archives' {
        $path = Join-Path $TestDrive 'BootUpdateCycle.log'
        [IO.File]::WriteAllText($path, ('x' * 2048))
        1..5 | ForEach-Object {
            $archive = Join-Path $TestDrive ("BootUpdateCycle.2026070{0}-010203.log" -f $_)
            Set-Content $archive "archive $_"
            (Get-Item $archive).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-$_)
        }
        Invoke-BootUpdateLogRotation -Path $path -MaximumBytes 10 `
            -ArchiveNamePattern '^BootUpdateCycle\.\d{8}-\d{6}\.log$' -Keep 3
        Test-Path $path | Should -BeFalse
        @(Get-ChildItem $TestDrive -File | Where-Object Name -Match '^BootUpdateCycle\.\d{8}-\d{6}\.log$').Count | Should -Be 3
    }

    It 'applies compression to active and archived logs without making it a correctness dependency' {
        $compression = Get-FunctionText -Ast $invokeAst -Name 'Enable-BootUpdateNtfsCompression'
        $rotation = Get-FunctionText -Ast $invokeAst -Name 'Invoke-BootUpdateLogRotation'
        $compression | Should -Match 'compact\.exe /C /I /Q'
        $compression | Should -Match 'catch'
        $rotation | Should -Match 'Enable-BootUpdateNtfsCompression -Path \$Path'
        $rotation | Should -Match 'Enable-BootUpdateNtfsCompression -Path \$archivePath'
    }
}
