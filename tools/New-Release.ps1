#requires -Version 7.0
<#
.SYNOPSIS
    Create a GitHub release with script assets and SHA256 sidecar files.

.DESCRIPTION
    Publishes Deploy-BootUpdateCycle.ps1 and Invoke-BootUpdateCycle.ps1 plus a
    matching <asset>.sha256 sidecar for each, which activates the integrity
    checks in both self-update paths (Invoke lz1 and Deploy source self-update).

    Guards: the tag must match the version embedded in Invoke, and both scripts
    must parse cleanly, before anything is published. Assets are copied to an
    isolated staging directory before hashing so each script and its checksum
    sidecar always describe the same bytes.

.EXAMPLE
    ./tools/New-Release.ps1 -Tag v2.5.18 -Title 'v2.5.18 - self-update hardening' -NotesPath notes.md -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+$')][string]$Tag,
    [Parameter(Mandatory)][string]$Title,
    [string]$NotesPath = '',
    [string]$Notes = '',
    [string]$Repo = 'nanoDBA/boot-upd'
)
$ErrorActionPreference = 'Stop'
if (-not $NotesPath -and -not $Notes) { throw 'Provide -Notes or -NotesPath.' }
if ($NotesPath -and $Notes) { throw 'Provide only one of -Notes or -NotesPath.' }

$root = Split-Path $PSScriptRoot -Parent
$assetNames = @('Deploy-BootUpdateCycle.ps1', 'Invoke-BootUpdateCycle.ps1')

$worktreeChanges = @(& git -C $root status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the Git worktree.' }
if ($worktreeChanges) {
    throw 'Release requires a clean worktree; commit all intended release files first.'
}

# Bind the release to the exact commit currently published on this branch.
$headSha = "$( & git -C $root rev-parse --verify 'HEAD^{commit}' )".Trim()
if ($LASTEXITCODE -ne 0 -or -not $headSha) { throw 'Could not resolve the release commit.' }
$branch = "$( & git -C $root symbolic-ref --quiet --short HEAD )".Trim()
if ($LASTEXITCODE -ne 0 -or -not $branch) { throw 'Release requires a checked-out branch, not detached HEAD.' }
$remote = "$( & git -C $root config --get "branch.$branch.remote" )".Trim()
$mergeRef = "$( & git -C $root config --get "branch.$branch.merge" )".Trim()
if (-not $remote -or -not $mergeRef) { throw "Branch '$branch' has no configured upstream." }
$remoteHead = @(& git -C $root ls-remote --exit-code $remote $mergeRef)
if ($LASTEXITCODE -ne 0 -or $remoteHead.Count -ne 1) {
    throw "Could not resolve exactly one upstream ref '$remote/$mergeRef'."
}
$remoteHeadSha = ($remoteHead[0] -split '\s+')[0]
if ($headSha -ne $remoteHeadSha) {
    throw "HEAD $headSha is not the pushed upstream commit $remoteHeadSha."
}
$existingTag = @(& git -C $root ls-remote --tags --refs $remote "refs/tags/$Tag")
if ($LASTEXITCODE -ne 0) { throw "Could not check whether remote tag '$Tag' exists." }
if ($existingTag) { throw "Remote tag '$Tag' already exists; refusing ambiguous release creation." }

if ($NotesPath) {
    $NotesPath = (Resolve-Path -LiteralPath $NotesPath -ErrorAction Stop).Path
}

$stage = Join-Path ([System.IO.Path]::GetTempPath()) (
    'boot-upd-release-{0}-{1}' -f $Tag, [guid]::NewGuid().ToString('N')
)

try {
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop -WhatIf:$false | Out-Null
    $uploads = @()

    foreach ($name in $assetNames) {
        $source = Join-Path $root $name
        $stagedAsset = Join-Path $stage $name
        $expectedBlob = "$( & git -C $root rev-parse "$headSha`:$name" )".Trim()
        $sourceBlob = "$( & git -C $root hash-object --no-filters -- $source )".Trim()
        if ($LASTEXITCODE -ne 0 -or $sourceBlob -ne $expectedBlob) {
            throw "Working-tree asset '$name' does not match committed HEAD."
        }

        Copy-Item -LiteralPath $source -Destination $stagedAsset -ErrorAction Stop -WhatIf:$false
        $stagedBlob = "$( & git -C $root hash-object --no-filters -- $stagedAsset )".Trim()
        if ($LASTEXITCODE -ne 0 -or $stagedBlob -ne $expectedBlob) {
            throw "Staged asset '$name' does not match committed HEAD."
        }

        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $stagedAsset,
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors) { throw "Parse errors in ${name}: $($errors[0].Message)" }

        $hash = (Get-FileHash -LiteralPath $stagedAsset -Algorithm SHA256).Hash.ToLowerInvariant()
        $sidecar = Join-Path $stage "$name.sha256"
        Set-Content -LiteralPath $sidecar -Value "$hash  $name" -Encoding ascii -NoNewline -WhatIf:$false
        $uploads += $stagedAsset, $sidecar
        Write-Host "  $name  sha256=$hash"
    }

    <# Guard: tag must match the version in the exact Invoke asset being uploaded. #>
    $invokeRaw = Get-Content -LiteralPath (Join-Path $stage 'Invoke-BootUpdateCycle.ps1') -Raw
    if ($invokeRaw -notmatch "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
        throw 'Cannot parse BootUpdateCycleVersion from Invoke-BootUpdateCycle.ps1'
    }
    if ("v$($matches[1])" -ne $Tag) {
        throw "Tag $Tag does not match script version v$($matches[1]) - bump the version first."
    }

    $ghArgs = @('release', 'create', $Tag, '--repo', $Repo, '--target', $headSha, '--title', $Title)
    if ($NotesPath) {
        $ghArgs += @('--notes-file', $NotesPath)
    } else {
        $ghArgs += @('--notes', $Notes)
    }

    if ($PSCmdlet.ShouldProcess("$Repo release $Tag", 'Create GitHub release')) {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw 'GitHub CLI (gh) is required to create a release.'
        }
        & gh @ghArgs @uploads
        if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)" }
        Write-Host "Released $Tag with SHA256 sidecars." -ForegroundColor Green
    } else {
        Write-Host "Prepared and validated $Tag release assets; publication skipped." -ForegroundColor Yellow
    }
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -WhatIf:$false
    }
}
