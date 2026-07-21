#requires -Version 7.0
<#
.SYNOPSIS
    Create a GitHub release with script assets and SHA256 sidecar files.

.DESCRIPTION
    Publishes the orchestrator, deployer, batch/raw/typed launchers, the
    historical compatibility installer, PS7 bootstrap, demo, and AWS repair helper plus a
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
& (Join-Path $PSScriptRoot 'Repair-LineEndings.ps1') -RepositoryRoot $root
$assetSpecs = @(
    [pscustomobject]@{ Source='Deploy-BootUpdateCycle.ps1';       Name='Deploy-BootUpdateCycle.ps1'; Kind='PowerShell' }
    [pscustomobject]@{ Source='Invoke-BootUpdateCycle.ps1';       Name='Invoke-BootUpdateCycle.ps1'; Kind='PowerShell' }
    [pscustomobject]@{ Source='upd.cmd';                           Name='upd.cmd';                    Kind='Batch' }
    [pscustomobject]@{ Source='tools/Invoke-UpdLauncher.ps1';      Name='Invoke-UpdLauncher.ps1';     Kind='PowerShell' }
    [pscustomobject]@{ Source='tools/Invoke-UpdBootstrap.ps1';     Name='Invoke-UpdBootstrap.ps1';    Kind='PowerShell' }
    [pscustomobject]@{ Source='tools/Install-UpdCompat.ps1';       Name='Install-UpdCompat.ps1';      Kind='PowerShell' }
    [pscustomobject]@{ Source='tools/Show-BootUpdateProgressDemo.ps1'; Name='Show-BootUpdateProgressDemo.ps1'; Kind='PowerShell' }
    [pscustomobject]@{ Source='tools/Install-PowerShell7.ps1';        Name='Install-PowerShell7.ps1'; Kind='PowerShell' }
    [pscustomobject]@{ Source='Repair-AwsTooling.ps1';             Name='Repair-AwsTooling.ps1';      Kind='PowerShell' }
)

function Export-GitBlob {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ObjectSpec,
        [Parameter(Mandatory)][string]$Destination
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-C', $RepositoryRoot, 'cat-file', 'blob', $ObjectSpec)) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $fileStream = $null
    try {
        if (-not $process.Start()) { throw 'Could not start git cat-file.' }
        $fileStream = [IO.File]::Open(
            $Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None
        )
        $process.StandardOutput.BaseStream.CopyTo($fileStream)
        $fileStream.Dispose()
        $fileStream = $null
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for '$ObjectSpec': $standardError"
        }
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        $process.Dispose()
    }
}

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

    foreach ($spec in $assetSpecs) {
        $name = $spec.Name
        $stagedAsset = Join-Path $stage $name
        $expectedBlob = "$( & git -C $root rev-parse "$headSha`:$($spec.Source)" )".Trim()
        Export-GitBlob -RepositoryRoot $root -ObjectSpec "$headSha`:$($spec.Source)" -Destination $stagedAsset
        $stagedBlob = "$( & git -C $root hash-object --no-filters -- $stagedAsset )".Trim()
        if ($LASTEXITCODE -ne 0 -or $stagedBlob -ne $expectedBlob) {
            throw "Staged asset '$name' does not match committed HEAD."
        }

        if ($spec.Kind -eq 'PowerShell') {
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $stagedAsset,
                [ref]$tokens,
                [ref]$errors
            )
            if ($errors) { throw "Parse errors in ${name}: $($errors[0].Message)" }
        } else {
            $batchText = Get-Content -LiteralPath $stagedAsset -Raw
            if ($batchText -notmatch '(?im)^@echo off\s*$' -or $batchText -notmatch 'Invoke-UpdLauncher\.ps1') {
                throw 'upd.cmd failed its launcher structure check.'
            }
        }

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
    $batchRaw = Get-Content -LiteralPath (Join-Path $stage 'upd.cmd') -Raw
    if ($batchRaw -notmatch '(?m)^:: BootUpdateCycleVersion=([\d.]+)\s*$' -or "v$($matches[1])" -ne $Tag) {
        throw "upd.cmd version marker does not match $Tag."
    }
    $compatHash = (Get-FileHash -LiteralPath (Join-Path $stage 'Install-UpdCompat.ps1') -Algorithm SHA256).Hash.ToUpperInvariant()
    $readmeRaw = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw
    if ($readmeRaw -notmatch [regex]::Escape("releases/download/$Tag/Install-UpdCompat.ps1") -or
        $readmeRaw -notmatch [regex]::Escape($compatHash)) {
        throw "README compatibility command must pin $Tag Install-UpdCompat.ps1 with SHA256 $compatHash."
    }

    $ghArgs = @('release', 'create', $Tag, '--repo', $Repo, '--target', $headSha, '--title', $Title, '--draft')
    if ($NotesPath) {
        $ghArgs += @('--notes-file', $NotesPath)
    } else {
        $ghArgs += @('--notes', $Notes)
    }

    if ($PSCmdlet.ShouldProcess("$Repo release $Tag", 'Create GitHub release')) {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw 'GitHub CLI (gh) is required to create a release.'
        }
        $draftCreated = $false
        try {
            & gh @ghArgs @uploads
            if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)" }
            $draftCreated = $true
            $releaseJson = & gh release view $Tag --repo $Repo --json isDraft,assets,targetCommitish
            if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the draft release.' }
            $published = $releaseJson | ConvertFrom-Json
            if (-not $published.isDraft) { throw 'Release was unexpectedly public before verification.' }
            if ($published.targetCommitish -ne $headSha) { throw 'Draft release target does not match the pushed commit.' }
            $expectedNames = @($uploads | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object)
            $actualNames = @($published.assets.name | Sort-Object)
            if (Compare-Object $expectedNames $actualNames) { throw 'Draft release asset set does not match the prepared bundle.' }
            $verifyDir = Join-Path $stage 'verify-download'
            $null = New-Item -ItemType Directory -Path $verifyDir -ErrorAction Stop
            & gh release download $Tag --repo $Repo --dir $verifyDir
            if ($LASTEXITCODE -ne 0) { throw 'Could not download the draft release for verification.' }
            foreach ($upload in $uploads) {
                $downloaded = Join-Path $verifyDir (Split-Path -Leaf $upload)
                if ((Get-FileHash -LiteralPath $upload -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $downloaded -Algorithm SHA256).Hash) {
                    throw "Uploaded asset verification failed: $(Split-Path -Leaf $upload)"
                }
            }
            & gh release edit $Tag --repo $Repo --draft=false
            if ($LASTEXITCODE -ne 0) { throw 'Draft assets verified, but publishing the release failed.' }
            Write-Host "Released $Tag with verified SHA256 sidecars." -ForegroundColor Green
        } catch {
            $existingDraft = $null
            try { $existingDraft = (& gh release view $Tag --repo $Repo --json isDraft 2>$null | ConvertFrom-Json) } catch {}
            if ($draftCreated -or $existingDraft.isDraft) {
                & gh release delete $Tag --repo $Repo --cleanup-tag --yes 2>$null
            }
            throw
        }
    } else {
        Write-Host "Prepared and validated $Tag release assets; publication skipped." -ForegroundColor Yellow
    }
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -WhatIf:$false
    }
}
