$ErrorActionPreference = 'Stop'
$mode = [string]$env:BOOTUPD_LAB_WINGET_MODE
$arguments = @($args | ForEach-Object { [string]$_ })
$logPath = [string]$env:BOOTUPD_LAB_FIXTURE_LOG
if ([string]::IsNullOrWhiteSpace($logPath)) { throw 'BOOTUPD_LAB_FIXTURE_LOG must name the lab-only evidence file.' }
New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
[pscustomobject]@{ AtUtc=[datetime]::UtcNow.ToString('o'); Mode=$mode; Arguments=$arguments } |
    ConvertTo-Json -Compress | Add-Content -LiteralPath $logPath -Encoding UTF8

if ($mode -eq 'hang') {
    while ($true) { Start-Sleep -Seconds 60 }
}

if ($mode -ne 'repeat-failure') { exit 2 }
$command = if ($arguments.Count) { $arguments[0].ToLowerInvariant() } else { '' }
$scope = if ($arguments -contains 'user') { 'user' } else { 'machine' }
if ($command -eq 'list') {
    if ($scope -eq 'user') {
        'No installed package found matching input criteria.'
        exit 0
    }
    '{0,-20}{1,-19}{2,-8}{3,-10}{4}' -f 'Name','Id','Version','Available','Source'
    '--------------------------------------------------------------'
    '{0,-20}{1,-19}{2,-8}{3,-10}{4}' -f 'BootUpd Test','BootUpd.TestFixture','1.0','2.0','winget'
    exit 0
}
if ($command -eq 'upgrade' -and $scope -eq 'machine') {
    'Found BootUpd Test Fixture [BootUpd.TestFixture] Version 2.0'
    'Installer failed with exit code: 1603'
    exit 1603
}
exit 0
