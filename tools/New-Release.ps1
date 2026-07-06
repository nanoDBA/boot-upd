#requires -Version 7.0
<#
.SYNOPSIS
    Create a GitHub release with script assets and SHA256 sidecar files.

.DESCRIPTION
    Publishes Deploy-BootUpdateCycle.ps1 and Invoke-BootUpdateCycle.ps1 plus a
    matching <asset>.sha256 sidecar for each, which activates the integrity
    checks in both self-update paths (Invoke lz1 and Deploy source self-update).

    Guards: the tag must match the version embedded in Invoke, and both scripts
    must parse cleanly, before anything is published.

.EXAMPLE
    ./tools/New-Release.ps1 -Tag v2.5.13 -Title 'v2.5.13 - hardening' -NotesPath notes.md
#>
param(
    [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+$')][string]$Tag,
    [Parameter(Mandatory)][string]$Title,
    [string]$NotesPath = '',
    [string]$Notes = '',
    [string]$Repo = 'nanoDBA/boot-upd'
)
$ErrorActionPreference = 'Stop'
if (-not $NotesPath -and -not $Notes) { throw 'Provide -Notes or -NotesPath.' }

$root = Split-Path $PSScriptRoot -Parent
$assetNames = @('Deploy-BootUpdateCycle.ps1', 'Invoke-BootUpdateCycle.ps1')

<# Guard: tag must match the version embedded in Invoke #>
$invokeRaw = Get-Content (Join-Path $root 'Invoke-BootUpdateCycle.ps1') -Raw
if ($invokeRaw -notmatch "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
    throw 'Cannot parse BootUpdateCycleVersion from Invoke-BootUpdateCycle.ps1'
}
if ("v$($matches[1])" -ne $Tag) {
    throw "Tag $Tag does not match script version v$($matches[1]) - bump the version first."
}

<# Guard: both scripts must parse #>
foreach ($name in $assetNames) {
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name), [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${name}: $($errs[0].Message)" }
}

<# SHA256 sidecars, staged in temp so the repo stays clean #>
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "boot-upd-release-$Tag"
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$uploads = @()
foreach ($name in $assetNames) {
    $file = Join-Path $root $name
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
    $sidecar = Join-Path $stage "$name.sha256"
    Set-Content -Path $sidecar -Value "$hash  $name" -Encoding ascii -NoNewline
    $uploads += $file, $sidecar
    Write-Host "  $name  sha256=$hash"
}

$ghArgs = @('release', 'create', $Tag, '--repo', $Repo, '--title', $Title)
if ($NotesPath) { $ghArgs += @('--notes-file', $NotesPath) } else { $ghArgs += @('--notes', $Notes) }
& gh @ghArgs @uploads
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)" }
Remove-Item -Recurse -Force $stage
Write-Host "Released $Tag with SHA256 sidecars." -ForegroundColor Green
