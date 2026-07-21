#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
$batchFiles = @(& git -C $RepositoryRoot ls-files '*.cmd')
if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate tracked batch files.' }

foreach ($relativePath in $batchFiles) {
    $path = Join-Path $RepositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = [IO.File]::ReadAllText($path)
    $normalized = ($text -replace "`r?`n", "`r`n")
    if ($normalized -cne $text) {
        [IO.File]::WriteAllText($path, $normalized, [Text.UTF8Encoding]::new($false))
        Write-Host "Normalized CRLF line endings: $relativePath" -ForegroundColor DarkCyan
    }
}
