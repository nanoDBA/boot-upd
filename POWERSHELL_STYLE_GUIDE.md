# 🐚 PowerShell Style Guide

> **Lightweight standards for scripts that don't suck to maintain**

---

## 🎯 Quick Reference

| Element | Standard |
|---------|----------|
| **Variables** | `$camelCase` |
| **Functions** | `Verb-PascalCase` (approved verbs only) |
| **State changes** | `[CmdletBinding(SupportsShouldProcess)]` |
| **Output** | Return `[pscustomobject]`, never format in functions |
| **Console** | `Write-Verbose` / `Write-Warning` over `Write-Host` |
| **Line width** | ~80 chars for comments, ~120 for code |
| **Periods** | Two spaces after periods in prose.  Like this. |

---

## 📜 File Header (Required)

Every script starts with a block comment header:

```powershell
# ------------------------------------------------------------------------------
# File:        Repair-AwsTooling.ps1
# Description: 🔧 Audits and repairs AWS CLI v2 + AWS.Tools module installations
# Purpose:     Ensures consistent AWS tooling across fleet by:
#              - Detecting multiple aws.exe on PATH (the "roulette" problem)
#              - Installing/updating AWS CLI v2 from official MSI
#              - Syncing AWS.Tools modules via Update-AWSToolsModule -CleanUp
#              Built for ops teams tired of "works on my machine" AWS issues.
# Created:     2025-01-10
# Modified:    2025-01-10
# ------------------------------------------------------------------------------
```

**Required Fields:**
- **File**: Filename
- **Description**: One-liner with optional emoji
- **Purpose**: What problem this solves, real-world context
- **Created/Modified**: Dates (update Modified when you edit)

---

## 💬 Comment-Based Help (Required for Functions)

Place immediately after the function declaration:

```powershell
function Repair-AwsTooling {
<#
.SYNOPSIS
    Audits and repairs AWS CLI v2 and AWS.Tools PowerShell module installations.

.DESCRIPTION
    Detects common AWS tooling problems (multiple CLI versions, stale modules)
    and optionally remediates them.  Runs in Audit mode by default for safety.

    Elevation required for CLI install/uninstall operations.

.PARAMETER Mode
    Audit = report only, no changes.  Remediate = fix issues found.

.PARAMETER MsiPath
    Optional path to a specific AWSCLIV2.msi.  If not provided, downloads
    the latest from https://awscli.amazonaws.com/AWSCLIV2.msi

.PARAMETER SkipCli
    Skip all AWS CLI operations (install, uninstall, version check).

.PARAMETER SkipModules
    Skip AWS.Tools module update/cleanup.

.PARAMETER UninstallCliV1
    Also uninstall legacy AWS CLI v1 if found.  Use with caution.

.EXAMPLE
    .\Repair-AwsTooling.ps1 -Mode Audit

    Reports current state without making changes.  Safe to run anytime.

.EXAMPLE
    .\Repair-AwsTooling.ps1 -Mode Remediate -Verbose

    Fixes detected issues with verbose output.  Requires elevation.

.EXAMPLE
    .\Repair-AwsTooling.ps1 -Mode Remediate -UninstallCliV1

    Full cleanup: installs v2, removes v1, updates modules.

.NOTES
    Requires: PowerShell 7+, elevation for Remediate mode
    Side effects: Installs software, modifies PATH (via MSI), removes old modules
    Safe to re-run: Yes (idempotent)
    
    Author: Your Name
    Version: 1.0.0
#>
```

**Minimum Required Sections:**
- `.SYNOPSIS` — One sentence
- `.DESCRIPTION` — Full context, prerequisites, caveats
- `.PARAMETER` — Each non-obvious param
- `.EXAMPLE` — At least 2 (basic + common use case)
- `.NOTES` — Permissions, side effects, idempotency

---

## 🎭 Tone Guidelines

### Professional but Fun
- **Accurate first**, entertaining second
- Metaphors welcome when they clarify ("PATH roulette", "Marie Kondo of modules")
- Snarky comments OK for warnings: `# Because AWS SDK v1 and v2 don't play nice`
- Avoid dry corporate language

### Explain the "Why"
```powershell
# BAD: Sets timeout
$timeout = 30

# GOOD: 30s timeout — AWS MSI installs can hang on slow networks
$timeout = 30
```

### DBA/Ops Context
- Reference real pain points ("2 AM callouts", "works on my machine")
- Include timing considerations (maintenance windows, reboot requirements)
- Warn about downstream effects

---

## 📐 Inline Comments

### Section Headers
```powershell
#region Configuration
# ...
#endregion

# Or simpler for scripts:
# ---- CONFIGURATION ----
# ---- MAIN ----
# ---- CLEANUP ----
```

### Comment Density
- **Every function**: Brief explanation of purpose
- **Complex logic**: Explain the "why", not the "what"
- **Magic numbers**: Always explain
- **Workarounds**: Document the bug/limitation being worked around

### Formatting
```powershell
# Single line for brief notes

# Multi-line for explanations that need context.  Notice
# the two spaces after periods.  Keep under 80 chars.

<#
  Block comment for longer explanations or temporarily
  disabling code sections.
#>
```

---

## ✅ Safety Patterns

### SupportsShouldProcess (for state changes)
```powershell
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$EnableException
)

process {
    if ($PSCmdlet.ShouldProcess($target, "Install AWS CLI v2")) {
        # Actual work here
    }
}
```

### EnableException Pattern
```powershell
# Default: warn and continue (human-friendly)
# With -EnableException: throw for automation

catch {
    $msg = $_.Exception.Message
    if ($EnableException) { throw }
    Write-Warning "Failed: $msg"
    [pscustomobject]@{ Target = $target; Success = $false; Error = $msg }
}
```

### Output Objects (not strings)
```powershell
# BAD
Write-Host "Processed $server successfully"

# GOOD
[pscustomobject]@{
    ComputerName = $server
    Success      = $true
    Message      = "Processed successfully"
}
```

---

## 🔧 Quick Checklist

Before committing a script:

- [ ] File header with Description/Purpose/Dates
- [ ] Comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`
- [ ] `$camelCase` variables
- [ ] `SupportsShouldProcess` if script changes state
- [ ] No `Format-Table` / `Out-Host` inside functions
- [ ] `Write-Verbose` / `Write-Warning` instead of `Write-Host`
- [ ] Two spaces after periods in comments
- [ ] Comments explain "why", not "what"

---

## 📋 Templates

<details>
<summary><b>Minimal Script Template</b></summary>

```powershell
#requires -Version 7.0
# ------------------------------------------------------------------------------
# File:        Script-Name.ps1
# Description: 🔧 One-liner description
# Purpose:     What problem this solves and when you'd use it.
# Created:     2025-01-10
# Modified:    2025-01-10
# ------------------------------------------------------------------------------

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Target,

    [switch]$EnableException
)

$ErrorActionPreference = 'Stop'

# ---- MAIN ----

try {
    if ($PSCmdlet.ShouldProcess($Target, "Do the thing")) {
        # Work here
        Write-Verbose "Processing $Target"
    }
}
catch {
    if ($EnableException) { throw }
    Write-Warning "Failed: $_"
}
```

</details>

<details>
<summary><b>Function Template (with full help)</b></summary>

```powershell
function Verb-Noun {
<#
.SYNOPSIS
    One sentence description.

.DESCRIPTION
    Full description with context, prerequisites, and caveats.

.PARAMETER Target
    What this parameter controls.

.EXAMPLE
    Verb-Noun -Target "value"

    Basic usage example.

.EXAMPLE
    Get-Content servers.txt | Verb-Noun -Verbose

    Pipeline usage with verbose output.

.NOTES
    Requires: List requirements
    Side effects: What changes
    Author: Your Name
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Target,

        [switch]$EnableException
    )

    begin {
        # One-time setup
    }

    process {
        foreach ($t in $Target) {
            try {
                if ($PSCmdlet.ShouldProcess($t, "Action description")) {
                    [pscustomobject]@{
                        Target  = $t
                        Success = $true
                        Message = "Completed"
                    }
                }
            }
            catch {
                $msg = $_.Exception.Message
                if ($EnableException) { throw }
                Write-Warning "Failed '$t': $msg"
                [pscustomobject]@{
                    Target  = $t
                    Success = $false
                    Error   = $msg
                }
            }
        }
    }

    end {
        # Cleanup
    }
}
```

</details>

---

## 🚫 Don'ts

| Don't | Why | Do Instead |
|-------|-----|------------|
| `$args` as variable name | Shadows automatic variable | `$msiArgs`, `$processArgs` |
| `Format-Table` in functions | Breaks pipeline | Return objects |
| `Write-Host` (usually) | Can't capture/redirect | `Write-Verbose`, `Write-Information` |
| `Invoke-Expression` | Security risk | Direct invocation or `& $cmd` |
| `exit` in functions | Kills entire session | `return` or `throw` |
| Global `$ErrorActionPreference` | Leaks to callers | Local scope or per-command `-ErrorAction` |

---

<div align="center">

**🎯 Keep it simple.  Document the why.  Return objects.** 🚀

*Future-you will mass the comments more than the code.*

</div>
