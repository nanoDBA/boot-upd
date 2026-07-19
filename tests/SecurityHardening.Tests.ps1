BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'
    $initializerPath = Join-Path $repoRoot 'tools\Initialize-BootUpdateWebhook.ps1'

    function Get-ScriptAst {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null
        $errors = $null
        $parsed = [Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors
        )
        $errors | Should -BeNullOrEmpty
        return $parsed
    }

    function Get-FunctionText {
        param(
            [Parameter(Mandatory)]$Ast,
            [Parameter(Mandatory)][string]$Name
        )
        $function = $Ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
        }, $true)
        $function | Should -Not -BeNullOrEmpty -Because "production function '$Name' must exist"
        return $function.Extent.Text
    }

    $invokeAst = Get-ScriptAst -Path $invokePath
    $deployAst = Get-ScriptAst -Path $deployPath
    $initializerAst = Get-ScriptAst -Path $initializerPath
    $invokeSource = Get-Content -LiteralPath $invokePath -Raw
    $deploySource = Get-Content -LiteralPath $deployPath -Raw
    $initializerSource = Get-Content -LiteralPath $initializerPath -Raw

    . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Resolve-BootUpdateTrustedFile')))
}

Describe 'Fail-closed self-update integrity' {
    It 'refuses an orchestrator update without a valid SHA256' {
        $text = Get-FunctionText -Ast $invokeAst -Name 'Update-OrchestratorSelf'
        $text | Should -Match 'release provides no valid SHA256; refusing unverified update'
        $text | Should -Not -Match 'skipping integrity check'
        $text | Should -Match 'if \(\$actualSha -ne \$expectedSha\)'
    }

    It 'refuses source asset replacement without a valid SHA256' {
        $deploySource | Should -Match 'provides no valid SHA256 for \$assetName'
        $deploySource | Should -Not -Match 'skipping integrity check'
    }
}

Describe 'Webhook secret persistence' {
    It 'never forwards the webhook URL through scheduled-task arguments' {
        (Get-FunctionText -Ast $invokeAst -Name 'Register-BootUpdateTaskForReboot') |
            Should -Not -Match 'WebhookUrl'
        (Get-FunctionText -Ast $deployAst -Name 'Register-ScheduledTaskNow') |
            Should -Not -Match 'WebhookUrl'
        $deploySource | Should -Not -Match 'WebhookUrl\s*=\s*\$Config\.WebhookUrl'
    }

    It 'never forwards the webhook URL to the self-update child process' {
        $text = Get-FunctionText -Ast $invokeAst -Name 'Update-OrchestratorSelf'
        $text | Should -Match '\$p\.Key -eq ''WebhookUrl'''
        $text | Should -Match 'never expose it in child argv'
    }

    It 'uses no-echo input and a restricted file ACL in the initializer' {
        $initializerSource | Should -Match 'Read-Host.*-AsSecureString'
        $initializerSource | Should -Match 'SetAccessRuleProtection\(\$true, \$false\)'
        $initializerSource | Should -Match "S-1-5-32-544"
        $initializerSource | Should -Match "S-1-5-18"
        $initializerSource | Should -Not -Match 'Write-Output.*\$url'
    }
}

Describe 'Elevated hook trust boundary' {
    BeforeEach {
        $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('BootUpdateTrust-' + [guid]::NewGuid().ToString('N'))
        $outsideRoot = Join-Path ([IO.Path]::GetTempPath()) ('BootUpdateOutside-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $testRoot, $outsideRoot -Force
        $insideHook = Join-Path $testRoot 'hook.ps1'
        $outsideHook = Join-Path $outsideRoot 'hook.ps1'
        Set-Content -LiteralPath $insideHook -Value '# trusted test hook' -Encoding utf8
        Set-Content -LiteralPath $outsideHook -Value '# outside test hook' -Encoding utf8
    }

    AfterEach {
        Remove-Item -LiteralPath $testRoot, $outsideRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'rejects a hook outside the trusted root' {
        Resolve-BootUpdateTrustedFile -Path $outsideHook -TrustRoot $testRoot `
            -AllowedExtension @('.ps1') | Should -BeNullOrEmpty
    }

    It 'accepts an in-root hook when no broad write ACE exists' {
        Mock Get-Acl {
            [pscustomobject]@{
                Owner = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
                Access = @()
            }
        }
        Resolve-BootUpdateTrustedFile -Path $insideHook -TrustRoot $testRoot `
            -AllowedExtension @('.ps1') | Should -Be (Resolve-Path $insideHook).Path
    }

    It 'rejects an in-root hook writable by built-in Users' {
        $rule = [pscustomobject]@{
            AccessControlType = [Security.AccessControl.AccessControlType]::Allow
            IdentityReference = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
            FileSystemRights = [Security.AccessControl.FileSystemRights]::Modify
        }
        Mock Get-Acl {
            [pscustomobject]@{
                Owner = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
                Access = @($rule)
            }
        }
        Resolve-BootUpdateTrustedFile -Path $insideHook -TrustRoot $testRoot `
            -AllowedExtension @('.ps1') | Should -BeNullOrEmpty
    }

    It 'rejects an in-root hook not owned by Administrators or SYSTEM' {
        Mock Get-Acl {
            [pscustomobject]@{
                Owner = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
                Access = @()
            }
        }
        Resolve-BootUpdateTrustedFile -Path $insideHook -TrustRoot $testRoot `
            -AllowedExtension @('.ps1') | Should -BeNullOrEmpty
    }

    It 'checks reparse points and the complete path ACL chain' {
        $text = Get-FunctionText -Ast $invokeAst -Name 'Resolve-BootUpdateTrustedFile'
        $text | Should -Match 'FileAttributes\]::ReparsePoint'
        $text | Should -Match 'while \(\$true\)'
        $text | Should -Match 'S-1-5-11'
        $text | Should -Match 'trustedOwnerSids'
    }
}
