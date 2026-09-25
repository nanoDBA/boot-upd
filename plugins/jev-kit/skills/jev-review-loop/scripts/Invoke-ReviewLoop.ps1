# ------------------------------------------------------------------------------
# File:        Invoke-ReviewLoop.ps1
# Description: 🎛️ One-command-per-step CLI over the review-loop ledger
# Purpose:     Lets the orchestrating agent drive the loop without ever
#              hand-editing JSON: every mutation goes through ReviewLoop.psm1,
#              which enforces legal transitions and fingerprints findings.
#              All output is JSON on stdout.
# Created:     2026-09-25
# Modified:    2026-09-25
# ------------------------------------------------------------------------------

<#
.SYNOPSIS
    Drives the review-loop ledger one command at a time.

.DESCRIPTION
    Commands and -Data shapes:
      init          {base, head, branch, scopeProfile?, shadow?, maxIterations?, fixThreshold?, ...}
      next          (none)                     -> the step to perform now
      status        (none)                     -> summary incl. cost block
      frontier      {graphPath}  or  {nodes: []}
      add-finding   {file, line?, lens, severity, summary, evidence?, node?, inScope?}
      set-finding   {id, verdict?, status?, fixCommit?, note?, countAttempt?}
      gate          {name, result: passed|failed|not-run, detail?}
      cost          {tier?, dispatches?, chars?, avoided?, avoidedCount?, auditSampled?, auditMisses?}
      move          {to, reason}
      findings      {status?}                  -> list findings (optionally filtered)

.EXAMPLE
    ./Invoke-ReviewLoop.ps1 -LedgerPath .review-loop/ledger.json -Command next
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LedgerPath,

    [Parameter(Mandatory)]
    [ValidateSet('init', 'next', 'status', 'frontier', 'add-finding', 'set-finding', 'gate', 'cost', 'move', 'findings')]
    [string]$Command,

    # JSON object (string) or a path to a JSON file.
    [string]$Data = '{}'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReviewLoop.psm1') -Force -Verbose:$false

$d = if (Test-Path -LiteralPath $Data -PathType Leaf) { Get-Content -LiteralPath $Data -Raw | ConvertFrom-Json -AsHashtable -Depth 20 }
     else { $Data | ConvertFrom-Json -AsHashtable -Depth 20 }
function Get-D { param([string]$Key, $Default = $null) if ($d.Contains($Key) -and $null -ne $d[$Key]) { $d[$Key] } else { $Default } }
function Out-Json { param($Value) $Value | ConvertTo-Json -Depth 20 }

if ($Command -eq 'init') {
    $p = @{ Path = $LedgerPath; Base = (Get-D 'base'); Head = (Get-D 'head'); Branch = (Get-D 'branch') }
    foreach ($k in 'scopeProfile', 'maxIterations', 'maxFixesPerIteration', 'maxFixAttempts', 'maxWallClockMinutes', 'fixThreshold',
                   'maxOpusDispatches', 'maxSonnetDispatches', 'maxHaikuDispatches', 'jevSpendCapUsd') {
        $v = Get-D $k; if ($null -ne $v) { $p[$k] = $v }
    }
    if (Get-D 'shadow' $false) { $p.Shadow = $true }
    $ledger = New-ReviewLedger @p
    Out-Json (Get-ReviewNextStep -Ledger $ledger); return
}

$ledger = Get-ReviewLedger -Path $LedgerPath
$result = switch ($Command) {
    'next' { Get-ReviewNextStep -Ledger $ledger }
    'status' { Get-ReviewSummary -Ledger $ledger }
    'findings' {
        $s = Get-D 'status'
        @($ledger.findings | Where-Object { -not $s -or $_.status -eq $s })
    }
    'frontier' {
        $nodes = if (Get-D 'graphPath') {
            $g = Get-Content -LiteralPath (Get-D 'graphPath') -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            Set-ReviewFrontier -Ledger $ledger -Nodes @($g.impacted | ForEach-Object { $_.id }) -GraphSummary $g.counts
        } else { Set-ReviewFrontier -Ledger $ledger -Nodes @(Get-D 'nodes' @()) }
        [ordered]@{ frontier = @($ledger.frontier).Count }
    }
    'add-finding' {
        Add-ReviewFinding -Ledger $ledger -File (Get-D 'file') -Line ([int](Get-D 'line' 0)) -Lens (Get-D 'lens') -Severity (Get-D 'severity') `
            -Summary (Get-D 'summary') -Evidence ([string](Get-D 'evidence' '')) -Node ([string](Get-D 'node' '')) -InScope ([bool](Get-D 'inScope' $true))
    }
    'set-finding' {
        $p = @{ Ledger = $ledger; Id = (Get-D 'id') }
        foreach ($k in 'verdict', 'status', 'fixCommit', 'note') { $v = Get-D $k; if ($null -ne $v) { $p[$k] = $v } }
        if (Get-D 'countAttempt' $false) { $p.CountAttempt = $true }
        Set-ReviewFinding @p
    }
    'gate' { Add-ReviewGate -Ledger $ledger -Name (Get-D 'name') -Result (Get-D 'result') -Detail ([string](Get-D 'detail' '')) }
    'cost' {
        $p = @{ Ledger = $ledger }
        $map = @{ tier = 'Tier'; dispatches = 'Dispatches'; chars = 'Chars'; avoided = 'Avoided'; avoidedCount = 'AvoidedCount'; auditSampled = 'AuditSampled'; auditMisses = 'AuditMisses' }
        foreach ($k in $map.Keys) { $v = Get-D $k; if ($null -ne $v) { $p[$map[$k]] = $v } }
        [void](Add-ReviewCost @p); [ordered]@{ policy = $ledger.policy; cost = $ledger.cost }
    }
    'move' { Move-ReviewState -Ledger $ledger -To (Get-D 'to') -Reason (Get-D 'reason' 'unspecified'); Get-ReviewNextStep -Ledger $ledger }
}
if ($Command -notin 'next', 'status', 'findings') { Save-ReviewLedger -Ledger $ledger -Path $LedgerPath }
Out-Json $result
