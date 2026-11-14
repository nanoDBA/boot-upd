#requires -Version 7.0
[CmdletBinding()]
param([string]$FromTag = 'v2.5.43')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path $env:TEMP ('boot-upd-published-upgrade-' + [guid]::NewGuid().ToString('N'))
$tools = Join-Path $root 'tools'
$null = New-Item -ItemType Directory -Path $tools
$succeeded = $false

function Read-SharedTextFile {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $reader = [IO.StreamReader]::new($stream)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

try {
    $oldUrl = "https://github.com/nanoDBA/boot-upd/releases/download/$FromTag/upd.cmd"
    Invoke-WebRequest -Uri $oldUrl -OutFile (Join-Path $root 'upd.cmd')
    Copy-Item (Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1') $root
    Copy-Item (Join-Path $repoRoot 'upd.cmd') (Join-Path $root 'upd.cmd.next')
    Copy-Item (Join-Path $repoRoot 'tools\Invoke-UpdLauncher.ps1') $tools

    $target = Join-Path $root 'upd.cmd'
    $next = "$target.next"
    $expected = (Get-FileHash $next -Algorithm SHA256).Hash
    Set-Content "$next.sha256" $expected -NoNewline
    Set-Content "$next.baseline" (Get-FileHash $target -Algorithm SHA256).Hash -NoNewline

    $output = & cmd.exe /d /c "`"$target`" help" 2>&1
    $exitCode = $LASTEXITCODE
    $text = $output -join "`n"
    $text | Set-Content -LiteralPath (Join-Path $root 'launcher-output.txt')
    if ($exitCode -ne 0) { throw "$FromTag launcher exited $exitCode.`n$text" }
    if ($text -match 'Terminate batch job|The system cannot find the path specified') {
        throw "Published launcher upgrade emitted a cmd.exe handoff failure.`n$text"
    }
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while ((Test-Path $next) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (Test-Path $next) { throw 'Timed out waiting for compatibility adoption.' }
    if ((Get-FileHash $target -Algorithm SHA256).Hash -ne $expected) {
        throw 'Final upd.cmd does not match the candidate launcher.'
    }
    # The legacy helper deletes upd.cmd.next first, then the sidecars, then writes its
    # terminal log line. Check the sidecars only after that line: checking them as soon as
    # .next disappeared failed a successful adoption once (2026-11-02) by catching the
    # helper between the two deletions.
    $adoptionLog = Join-Path $root 'upd.cmd.adoption.log'
    $logDeadline = [datetime]::UtcNow.AddSeconds(10)
    while ([datetime]::UtcNow -lt $logDeadline) {
        try {
            if ((Test-Path -LiteralPath $adoptionLog) -and
                ((Read-SharedTextFile -Path $adoptionLog) -match 'completed')) { break }
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $adoptionLog) -or
        (Read-SharedTextFile -Path $adoptionLog) -notmatch 'completed') {
        throw 'Compatibility adoption did not publish its terminal completion record.'
    }
    foreach ($sidecar in "$next.sha256","$next.baseline") {
        if (Test-Path $sidecar) { throw "Compatibility adoption left $sidecar behind." }
    }
    [pscustomobject]@{ Gate='published-launcher-upgrade'; From=$FromTag; Result='passed'; CandidateHash=$expected } |
        ConvertTo-Json
    $succeeded = $true
} finally {
    if (-not $succeeded) { Write-Warning "Published launcher failure evidence retained at $root" }
    if ($succeeded -and (Test-Path -LiteralPath $root)) {
        $cleanupDeadline = [datetime]::UtcNow.AddSeconds(10)
        do {
            try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop; break }
            catch {
                if ([datetime]::UtcNow -ge $cleanupDeadline) { throw }
                Start-Sleep -Milliseconds 200
            }
        } while (Test-Path -LiteralPath $root)
    }
}
