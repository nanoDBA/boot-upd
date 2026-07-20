#requires -Version 5.1
<#
.SYNOPSIS
    Stable, raw-argument bootstrap for upd.cmd.

.DESCRIPTION
    This script intentionally has no param block. It receives the original
    command line through $args, refreshes the checksummed runtime bundle before
    operational dispatch, and only then invokes the current typed launcher.
    Keeping argument interpretation out of this stage lets future launchers add
    commands without an older parameter binder rejecting them first.
#>
$ErrorActionPreference = 'Stop'

$repoRoot = if ($env:UPD_ROOT) { [IO.Path]::GetFullPath($env:UPD_ROOT) } else { Split-Path $PSScriptRoot -Parent }
$launcherPath = Join-Path $repoRoot 'tools\Invoke-UpdLauncher.ps1'
$rawArguments = @($args)

if ($rawArguments.Count -eq 2 -and $rawArguments[0] -eq '--stage0-encoded') {
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rawArguments[1]))
        $decoded = ConvertFrom-Json -InputObject $json
        $rawArguments = @($decoded | ForEach-Object { [string]$_ })
    } catch {
        throw 'The elevated launcher handoff arguments are malformed.'
    }
}

function Test-UpdBootstrapAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-UpdBootstrapLauncher {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $launcherPath)) {
        throw "The typed UPD launcher is missing: $launcherPath"
    }
    $pwshPath = (Get-Process -Id $PID).Path
    & $pwshPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $launcherPath @Arguments
    $script:UpdBootstrapLauncherExitCode = $LASTEXITCODE
}

function Test-UpdBootstrapReadOnly {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)
    if ($Arguments.Count -eq 0) { return $false }
    $command = $Arguments[0].ToLowerInvariant()
    return $command -in @(
        '/?','?','/help','help','-help','--help','-h','usage','--usage',
        '-v','-d','-f','-st',
        'version','v','plan','p','status','st','splash','sp',
        'demo','d','--demo','/demo','fun','f','--fun','/fun','bootstrap','b'
    )
}

function Test-UpdBootstrapUpdateDisabled {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)
    foreach ($argument in $Arguments) {
        if ($argument.ToLowerInvariant() -in @('-nu','--no-update','--disable-self-update')) {
            return $true
        }
    }
    return $false
}

<# Read-only commands must remain local: no HTTP, writes, or UAC. #>
if (Test-UpdBootstrapReadOnly -Arguments $rawArguments) {
    Invoke-UpdBootstrapLauncher -Arguments $rawArguments
    exit $script:UpdBootstrapLauncherExitCode
}

<# An explicit no-update switch is also the offline escape hatch. #>
if (Test-UpdBootstrapUpdateDisabled -Arguments $rawArguments) {
    Invoke-UpdBootstrapLauncher -Arguments $rawArguments
    exit $script:UpdBootstrapLauncherExitCode
}

<# Operational and not-yet-known commands cross one UAC boundary here. The
   elevated copy updates first and then dispatches the untouched argv to the
   newly installed typed launcher, so there is no second elevation prompt. #>
if (-not (Test-UpdBootstrapAdministrator)) {
    $json = ConvertTo-Json -InputObject @($rawArguments) -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $quotedScript = '"{0}"' -f $PSCommandPath
    $process = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$quotedScript,
        '--stage0-encoded',$encoded
    )
    exit $process.ExitCode
}

$requestedCommand = if ($rawArguments.Count) { $rawArguments[0].ToLowerInvariant() } else { 'run' }
Invoke-UpdBootstrapLauncher -Arguments @('update')
$updateExit = $script:UpdBootstrapLauncherExitCode
if ($updateExit -ne 0) {
    Write-Error 'Verified UPD preflight failed; the operational command was not dispatched. Use -nu only when intentionally accepting the installed offline bundle.'
    exit $updateExit
}

if ($requestedCommand -in @('update','u')) { exit 0 }

<# Invoke the path again after refresh. PowerShell loads the new file contents,
   rather than continuing command dispatch in the old in-memory launcher. #>
$dispatchArguments = @('-BundlePreflighted') + @($rawArguments)
Invoke-UpdBootstrapLauncher -Arguments $dispatchArguments
exit $script:UpdBootstrapLauncherExitCode
