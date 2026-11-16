$ErrorActionPreference = 'Stop'
$logPath = [string]$env:BOOTUPD_LAB_NPM_FIXTURE_LOG
if ([string]::IsNullOrWhiteSpace($logPath)) { throw 'BOOTUPD_LAB_NPM_FIXTURE_LOG must name the lab-only evidence file.' }
New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = @($args | ForEach-Object { [string]$_ })
[pscustomobject]@{ AtUtc=[datetime]::UtcNow.ToString('o'); Identity=$identity; Arguments=$arguments } |
    ConvertTo-Json -Compress | Add-Content -LiteralPath $logPath -Encoding UTF8

$command = if ($arguments.Count) { $arguments[0].ToLowerInvariant() } else { '' }
if ($command -eq 'outdated') { '{}' ; exit 0 }
if ($command -eq 'update') { 'Lab npm fixture update succeeded.'; exit 0 }
exit 0
