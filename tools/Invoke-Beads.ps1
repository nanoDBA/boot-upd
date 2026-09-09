#requires -Version 7.0
<#
.SYNOPSIS
    Run bd with the central Dolt username and password from Windows Credential Manager.

.DESCRIPTION
    Retrieves the generic credential identified by the repository-local
    beads.credentialTarget Git setting, makes its username and password available
    only for the lifetime of the bd invocation, and clears both in a finally block.

    The password is never printed, passed on the command line, or persisted as
    a User/Machine environment variable.

.EXAMPLE
    ./tools/Invoke-Beads.ps1 ready

.EXAMPLE
    ./tools/Invoke-Beads.ps1 show boot-upd-123
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

function Initialize-BetterCredentialsModule {
    if (-not (Get-Module -ListAvailable -Name BetterCredentials)) {
        $installModule = Get-Command Install-Module -ErrorAction SilentlyContinue
        if (-not $installModule) {
            throw 'BetterCredentials is not installed and Install-Module is unavailable. Install PowerShellGet, then rerun this command.'
        }

        Install-Module -Name BetterCredentials -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }

    Import-Module BetterCredentials -ErrorAction Stop
}

function ConvertTo-SanitizedBeadsExport {
    <#
    .SYNOPSIS
        Rewrites real-identity assignee/owner values left by `bd export` so a
        public git history never carries them.

    .DESCRIPTION
        This repository is public (see .claude/rules/public-repository-privacy.md).
        `bd export` writes the maintainer's real name into "assignee" and real
        email address into "owner" on every row. Ticket -35qb.3 chose a
        forward-only fix over a git-history rewrite (personal repo; the name
        and address are already on the maintainer's public GitHub profile), so
        every export from this point on is sanitized in place immediately
        after bd writes the file:
          - assignee: any non-empty value other than the placeholder below is
            rewritten to the literal string "maintainer".
          - owner: any non-empty value is dropped entirely (rewritten to the
            empty string) rather than replaced with a fake placeholder email.
        Only those two JSON string values are touched, via a targeted regex
        substitution on each raw line rather than a parse/re-serialize round
        trip, so every other field - its escaping, spacing, and the file's
        line order - is preserved byte-for-byte. The transform is idempotent:
        a line whose assignee/owner is already the placeholder, empty, or
        JSON null comes back unchanged, so re-running export never drifts the
        file or corrupts those rows.

    .PARAMETER Path
        Path to the JSONL file bd export just wrote.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    function New-BeadsFieldSanitizer {
        param(
            [string]$FieldName,
            [string]$Replacement
        )

        # Matches a top-level JSON string value for $FieldName, capturing its
        # (still-escaped) contents so an already-sanitized/empty/null value
        # can be recognized and left untouched.
        $pattern = '"' + [regex]::Escape($FieldName) + '":"((?:[^"\\]|\\.)*)"'
        $evaluator = {
            param($match)
            $current = $match.Groups[1].Value
            if ([string]::IsNullOrEmpty($current) -or $current -eq $Replacement) {
                return $match.Value
            }
            return '"' + $FieldName + '":"' + $Replacement + '"'
        }.GetNewClosure()

        [pscustomobject]@{
            Pattern   = $pattern
            Evaluator = $evaluator
        }
    }

    $sanitizers = @(
        (New-BeadsFieldSanitizer -FieldName 'assignee' -Replacement 'maintainer')
        (New-BeadsFieldSanitizer -FieldName 'owner' -Replacement '')
    )

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrEmpty($raw)) {
        return
    }

    # Preserve the file's own line-ending style and trailing-newline state
    # instead of imposing one, since this repo's CRLF/LF handling depends on
    # git normalizing on commit.
    $newline = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $hadTrailingNewline = $raw.EndsWith($newline)
    $lines = $raw -split "`r?`n"
    if ($hadTrailingNewline -and $lines.Count -gt 0 -and $lines[-1] -eq '') {
        $lines = $lines[0..($lines.Count - 2)]
    }

    $sanitizedLines = foreach ($line in $lines) {
        $updated = $line
        if (-not [string]::IsNullOrWhiteSpace($updated)) {
            foreach ($sanitizer in $sanitizers) {
                $updated = [regex]::Replace($updated, $sanitizer.Pattern, $sanitizer.Evaluator)
            }
        }
        $updated
    }

    $content = $sanitizedLines -join $newline
    if ($hadTrailingNewline) {
        $content += $newline
    }

    Set-Content -LiteralPath $Path -Value $content -NoNewline -Encoding utf8
}

function Get-BeadsExportOutputPath {
    <#
    .SYNOPSIS
        Finds the -o/--output value in a `bd export` argument list, if any.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($arg -eq '-o' -or $arg -eq '--output') {
            if ($i + 1 -lt $Arguments.Count) {
                return $Arguments[$i + 1]
            }
            return $null
        }
        if ($arg -like '--output=*') {
            return $arg.Substring('--output='.Length)
        }
    }

    return $null
}

$credentialTarget = & git -C $repoRoot config --local --get beads.credentialTarget
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($credentialTarget)) {
    throw 'Missing repository-local beads.credentialTarget setting. Run: ./tools/Initialize-BeadsCredential.ps1'
}

Initialize-BetterCredentialsModule

function Get-StoredGenericCredential {
    param(
        [Parameter(Mandatory)]
        [string]$Target
    )

    try {
        return [CredentialManagement.Store]::Load($Target, [CredentialManagement.CredentialType]::Generic, $false)
    }
    catch {
        if ($_.Exception.InnerException.NativeErrorCode -eq 1168) {
            return $null
        }
        throw
    }
}

$credential = Get-StoredGenericCredential -Target $credentialTarget
if (-not $credential) {
    throw "Windows Credential Manager has no generic credential for '$credentialTarget'. Run: ./tools/Initialize-BeadsCredential.ps1"
}

$exitCode = 1
try {
    $doltUsername = $credential.UserName
    if ([string]::IsNullOrWhiteSpace($doltUsername)) {
        throw "Windows Credential Manager credential '$credentialTarget' has no Dolt username. Run: ./tools/Initialize-BeadsCredential.ps1 -Replace"
    }

    $env:BEADS_DOLT_SERVER_USER = $doltUsername
    $env:BEADS_DOLT_PASSWORD = $credential.GetNetworkCredential().Password
    & bd -C $repoRoot @args
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0 -and $args.Count -gt 0 -and $args[0] -eq 'export') {
        $remainingArgs = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
        $exportPath = Get-BeadsExportOutputPath -Arguments $remainingArgs
        if ($exportPath) {
            if (-not [System.IO.Path]::IsPathRooted($exportPath)) {
                $exportPath = Join-Path $repoRoot $exportPath
            }
            ConvertTo-SanitizedBeadsExport -Path $exportPath
        }
    }
}
finally {
    Remove-Item Env:BEADS_DOLT_SERVER_USER -ErrorAction SilentlyContinue
    Remove-Item Env:BEADS_DOLT_PASSWORD -ErrorAction SilentlyContinue
    $credential = $null
}

exit $exitCode
