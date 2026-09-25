# ------------------------------------------------------------------------------
# File:        ReviewLoop.psm1
# Description: 🔁 Ledger + state graph for unattended review→fix→verify loops
# Purpose:     The loop's memory and its rules, kept in code instead of in the
#              model's head:
#              - A JSON ledger that survives crashes, restarts, and fresh
#                sessions (atomic writes, schema-versioned)
#              - An explicit state graph with legal transitions only
#              - Finding fingerprints that dedupe across iterations and catch
#                fix→reopen oscillation
#              - Budget, regression, and fixed-point stop rules evaluated
#                deterministically on every tick
#              - Cost ledger: exact Jev tokens, LLM dispatches per tier,
#                work avoided, audit misses; spend caps fail toward spending
# Created:     2026-09-25
# Modified:    2026-09-25
# ------------------------------------------------------------------------------

Set-StrictMode -Version Latest

$script:SchemaVersion = 1

# State graph.  Terminal states have no outgoing edges.
$script:Transitions = [ordered]@{
    SCOPE    = @('GRAPH', 'STOPPED')
    GRAPH    = @('REVIEW', 'STOPPED')
    REVIEW   = @('VERIFY', 'DONE', 'STOPPED')
    VERIFY   = @('FIX', 'DONE', 'STOPPED')
    FIX      = @('GATE', 'DONE', 'STOPPED')
    GATE     = @('REVIEW', 'FIX', 'DONE', 'STOPPED')
    DONE     = @()
    STOPPED  = @()
}

$script:Severities = 'critical', 'high', 'medium', 'low'

function New-ReviewLedger {
<#
.SYNOPSIS
    Creates a new review-loop ledger.  Refuses to overwrite an existing one.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$Branch,
        [string]$ScopeProfile = '',
        [ValidateRange(1, 20)][int]$MaxIterations = 5,
        [ValidateRange(1, 50)][int]$MaxFixesPerIteration = 5,
        [ValidateRange(1, 5)][int]$MaxFixAttempts = 2,
        [ValidateRange(5, 1440)][int]$MaxWallClockMinutes = 240,
        [ValidateSet('critical', 'high', 'medium', 'low')][string]$FixThreshold = 'medium',
        [ValidateRange(0, 500)][int]$MaxOpusDispatches = 20,
        [ValidateRange(0, 2000)][int]$MaxSonnetDispatches = 60,
        [ValidateRange(0, 5000)][int]$MaxHaikuDispatches = 200,
        [ValidateRange(0.0, 100.0)][double]$JevSpendCapUsd = 1.0,
        # Log D1 skips without applying them (first run on a new repo).
        [switch]$Shadow
    )

    if (Test-Path -LiteralPath $Path) { throw "Ledger already exists at '$Path'.  Resume it or remove it deliberately." }
    $now = [datetime]::UtcNow.ToString('o')
    $ledger = [ordered]@{
        schema    = $script:SchemaVersion
        runId     = '{0:yyyyMMdd-HHmmss}-{1}' -f [datetime]::UtcNow, ([guid]::NewGuid().ToString('N').Substring(0, 6))
        createdUtc = $now
        base      = $Base
        head      = $Head
        branch    = $Branch
        scopeProfile = $ScopeProfile
        budget    = [ordered]@{
            maxIterations = $MaxIterations; maxFixesPerIteration = $MaxFixesPerIteration
            maxFixAttempts = $MaxFixAttempts; maxWallClockMinutes = $MaxWallClockMinutes
            fixThreshold = $FixThreshold
            maxDispatches = [ordered]@{ opus = $MaxOpusDispatches; sonnet = $MaxSonnetDispatches; haiku = $MaxHaikuDispatches }
            jevSpendCapUsd = $JevSpendCapUsd
        }
        policy    = [ordered]@{
            shadow = [bool]$Shadow
            allowSkip = $true        # flipped off by an audit miss
            jevAvailable = $true     # flipped off by outage or spend cap: fail toward spending
        }
        cost      = [ordered]@{
            jev     = [ordered]@{ calls = 0; inputTokens = 0 }
            llm     = [ordered]@{
                opus = [ordered]@{ dispatches = 0; chars = 0 }
                sonnet = [ordered]@{ dispatches = 0; chars = 0 }
                haiku = [ordered]@{ dispatches = 0; chars = 0 }
            }
            avoided = [ordered]@{ nodesSkipped = 0; lensesPruned = 0; findingsSettledByJev = 0; fixesClearedByJev = 0 }
            audit   = [ordered]@{ sampled = 0; misses = 0 }
        }
        state     = 'SCOPE'
        iteration = 1
        graph     = $null
        frontier  = @()
        findings  = @()
        gates     = @()
        history   = @([ordered]@{ utc = $now; from = $null; to = 'SCOPE'; reason = 'ledger created' })
        stop      = $null
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Create review ledger')) { Save-ReviewLedger -Ledger $ledger -Path $Path }
    return $ledger
}

function Get-ReviewLedger {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "No ledger at '$Path'." }
    $ledger = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    if ($ledger.schema -ne $script:SchemaVersion) { throw "Ledger schema $($ledger.schema) is not supported (expected $script:SchemaVersion)." }
    foreach ($k in 'frontier', 'findings', 'gates', 'history') { $ledger[$k] = @($ledger[$k] | Where-Object { $null -ne $_ }) }
    return $ledger
}

function Save-ReviewLedger {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Ledger,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Process-unique temp + move: a killed tick never leaves half a ledger.
    $tmp = '{0}.tmp-{1}-{2}' -f $Path, $PID, ([guid]::NewGuid().ToString('N').Substring(0, 6))
    if ($PSCmdlet.ShouldProcess($Path, 'Save review ledger')) {
        $Ledger | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $tmp -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
}

function Get-ReviewFingerprint {
<#
.SYNOPSIS
    Stable id for a finding: file + lens + normalized claim.  Line numbers are
    excluded on purpose; they move every time anything above them changes.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Lens,
        [Parameter(Mandatory)][string]$Summary
    )
    $norm = ($Summary.ToLowerInvariant() -replace '`[^`]*`', '<code>' -replace '\d+', '#' -replace '[^a-z#<> ]', ' ' -replace '\s+', ' ').Trim()
    $key = '{0}|{1}|{2}' -f ($File -replace '\\', '/').ToLowerInvariant(), $Lens.ToLowerInvariant(), $norm
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))
    return 'F-' + [Convert]::ToHexString($hash).Substring(0, 10).ToLowerInvariant()
}

function Add-ReviewFinding {
<#
.SYNOPSIS
    Records a finding, deduping by fingerprint.  A previously fixed finding
    that shows up again is reopened and its reopenCount incremented: that is
    the oscillation signal.
.OUTPUTS
    The finding record, with an added 'outcome' of new | duplicate | reopened.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Ledger,
        [Parameter(Mandatory)][string]$File,
        [int]$Line = 0,
        [Parameter(Mandatory)][string]$Lens,
        [Parameter(Mandatory)][ValidateSet('critical', 'high', 'medium', 'low')][string]$Severity,
        [Parameter(Mandatory)][string]$Summary,
        [string]$Evidence = '',
        [string]$Node = '',
        [bool]$InScope = $true
    )
    $id = Get-ReviewFingerprint -File $File -Lens $Lens -Summary $Summary
    $existing = $Ledger.findings | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if ($existing) {
        $existing.lastSeenIteration = $Ledger.iteration
        $existing.line = $Line
        if ($existing.status -eq 'fixed') {
            $existing.status = 'open'
            $existing.verdict = 'unverified'
            $existing.reopenCount = [int]$existing.reopenCount + 1
            return [pscustomobject]@{ outcome = 'reopened'; finding = $existing }
        }
        return [pscustomobject]@{ outcome = 'duplicate'; finding = $existing }
    }
    $finding = [ordered]@{
        id = $id; file = ($File -replace '\\', '/'); line = $Line; node = $Node; lens = $Lens
        severity = $Severity; summary = $Summary; evidence = $Evidence; inScope = $InScope
        verdict = 'unverified'; status = 'open'; attempts = 0; reopenCount = 0
        firstIteration = $Ledger.iteration; lastSeenIteration = $Ledger.iteration
        fixCommits = @(); fixedIteration = $null; note = ''
    }
    $Ledger.findings = @($Ledger.findings) + $finding
    return [pscustomobject]@{ outcome = 'new'; finding = $finding }
}

function Set-ReviewFinding {
<#
.SYNOPSIS
    Updates a finding's verdict, status, fix commit, or note.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Ledger,
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet('confirmed', 'rejected', 'unverified')][string]$Verdict,
        [ValidateSet('open', 'fixed', 'escalated', 'wontfix')][string]$Status,
        [string]$FixCommit,
        [string]$Note,
        [switch]$CountAttempt
    )
    $f = $Ledger.findings | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $f) { throw "Unknown finding '$Id'." }
    if ($Verdict) {
        $f.verdict = $Verdict
        if ($Verdict -eq 'rejected') { $f.status = 'wontfix' }
    }
    if ($Status) {
        if ($Status -eq 'fixed' -and $f.verdict -ne 'confirmed') { throw "Finding '$Id' is $($f.verdict); only confirmed findings can be marked fixed." }
        if ($Status -eq 'fixed' -and -not $FixCommit -and @($f.fixCommits).Count -eq 0) { throw "Finding '$Id' needs -FixCommit to be marked fixed." }
        $f.status = $Status
        if ($Status -eq 'fixed') { $f.fixedIteration = $Ledger.iteration }
    }
    if ($FixCommit) { $f.fixCommits = @($f.fixCommits) + $FixCommit }
    if ($CountAttempt) { $f.attempts = [int]$f.attempts + 1 }
    if ($PSBoundParameters.ContainsKey('Note')) { $f.note = $Note }
    return $f
}

function Add-ReviewGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Ledger,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'not-run')][string]$Result,
        [string]$Detail = ''
    )
    $gate = [ordered]@{ iteration = $Ledger.iteration; utc = [datetime]::UtcNow.ToString('o'); name = $Name; result = $Result; detail = $Detail }
    $Ledger.gates = @($Ledger.gates) + $gate
    return $gate
}

function Set-ReviewFrontier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Ledger,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Nodes,
        [System.Collections.IDictionary]$GraphSummary
    )
    $Ledger.frontier = @($Nodes | Select-Object -Unique)
    if ($GraphSummary) { $Ledger.graph = $GraphSummary }
}

function Move-ReviewState {
<#
.SYNOPSIS
    Moves the ledger along a legal edge of the state graph and logs why.
    GATE -> REVIEW starts a new iteration.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Ledger,
        [Parameter(Mandatory)][ValidateSet('SCOPE', 'GRAPH', 'REVIEW', 'VERIFY', 'FIX', 'GATE', 'DONE', 'STOPPED')][string]$To,
        [Parameter(Mandatory)][string]$Reason
    )
    $from = $Ledger.state
    if ($To -notin $script:Transitions[$from]) {
        throw "Illegal transition $from -> $To.  Legal: $(@($script:Transitions[$from]) -join ', ')"
    }
    if ($from -eq 'GATE' -and $To -eq 'REVIEW') { $Ledger.iteration = [int]$Ledger.iteration + 1 }
    $Ledger.state = $To
    $Ledger.history = @($Ledger.history) + [ordered]@{ utc = [datetime]::UtcNow.ToString('o'); from = $from; to = $To; reason = $Reason }
    if ($To -in 'DONE', 'STOPPED') { $Ledger.stop = [ordered]@{ state = $To; reason = $Reason; utc = [datetime]::UtcNow.ToString('o') } }
}

function Get-ReviewNextStep {
<#
.SYNOPSIS
    Decides what the loop must do next from the ledger alone.

.DESCRIPTION
    Pure function of the ledger (plus the clock).  Returns:
      state    - the state the loop should be in / move to
      action   - what to do in that state
      reason   - why
      terminal - true when the run is over
    Hard stops are evaluated first and override everything: budget, wall
    clock, repeated gate failure, oscillation.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Ledger)

    $b = $Ledger.budget
    $state = $Ledger.state
    $it = [int]$Ledger.iteration
    $step = { param($s, $a, $r, [bool]$t = $false) [pscustomobject]@{ state = $s; action = $a; reason = $r; terminal = $t; iteration = $it } }

    if ($state -in 'DONE', 'STOPPED') { return & $step $state 'Write the final report (already terminal).' $Ledger.stop.reason $true }

    # --- hard stops -----------------------------------------------------------
    $elapsed = ([datetime]::UtcNow - [datetime]::Parse($Ledger.createdUtc).ToUniversalTime()).TotalMinutes
    if ($elapsed -gt [int]$b.maxWallClockMinutes) {
        return & $step 'STOPPED' 'Stop. Report open findings as not addressed.' ("wall clock budget exhausted ({0:N0} of {1} min)" -f $elapsed, $b.maxWallClockMinutes) $true
    }
    if ($it -gt [int]$b.maxIterations) {
        return & $step 'STOPPED' 'Stop. Report open findings as not addressed.' "iteration budget exhausted ($($it - 1) of $($b.maxIterations))" $true
    }
    foreach ($tier in 'opus', 'sonnet', 'haiku') {
        $used = [int]$Ledger.cost.llm[$tier].dispatches
        $cap = [int]$b.maxDispatches[$tier]
        if ($used -ge $cap -and $cap -ge 0 -and $used -gt 0) {
            return & $step 'STOPPED' 'Stop. Report open findings as not addressed.' "LLM dispatch budget exhausted for $tier ($used of $cap)" $true
        }
    }
    $thisGates = @($Ledger.gates | Where-Object { $_.iteration -eq $it })
    $failedRuns = @($thisGates | Where-Object result -eq 'failed')
    if ($failedRuns.Count -ge 2) {
        return & $step 'STOPPED' 'Revert this iteration''s fix commits (git revert, never reset), confirm gates are green again, then report.' "gates failed twice in iteration $it ($(@($failedRuns.name | Select-Object -Unique) -join ', '))" $true
    }

    $rank = @{ critical = 0; high = 1; medium = 2; low = 3 }
    $threshold = $rank[[string]$b.fixThreshold]
    $findings = @($Ledger.findings)
    $unverified = @($findings | Where-Object { $_.status -eq 'open' -and $_.verdict -eq 'unverified' })
    $oscillating = @($findings | Where-Object { $_.status -eq 'open' -and [int]$_.reopenCount -ge 1 })
    $exhausted = @($findings | Where-Object { $_.status -eq 'open' -and $_.verdict -eq 'confirmed' -and [int]$_.attempts -ge [int]$b.maxFixAttempts })
    $fixable = @($findings | Where-Object {
        $_.status -eq 'open' -and $_.verdict -eq 'confirmed' -and $_.inScope -and
        $rank[[string]$_.severity] -le $threshold -and [int]$_.reopenCount -lt 1 -and [int]$_.attempts -lt [int]$b.maxFixAttempts
    })
    $escalate = @(@($oscillating) + @($exhausted) + @($findings | Where-Object { $_.status -eq 'open' -and $_.verdict -eq 'confirmed' -and -not $_.inScope }) |
        Where-Object { $_ } | ForEach-Object { $_.id } | Select-Object -Unique)

    switch ($state) {
        'SCOPE' { return & $step 'SCOPE' 'Resolve base/head/branch, load the scope profile, verify the working tree is clean, then move to GRAPH.' 'run initialised' }
        'GRAPH' { return & $step 'GRAPH' 'Run Get-ReviewGraph.ps1 against base; record impacted nodes as the frontier (set-frontier), then move to REVIEW.' 'no frontier yet' }
        'REVIEW' {
            if (@($Ledger.frontier).Count -eq 0) { return & $step 'DONE' 'Fixed point: nothing left to review. Write the final report.' 'frontier is empty' $true }
            return & $step 'REVIEW' "Review the $(@($Ledger.frontier).Count) frontier node(s) with every applicable lens (dependencies first); add each finding, then move to VERIFY." "iteration $it review pass"
        }
        'VERIFY' {
            if ($unverified.Count -gt 0) { return & $step 'VERIFY' "Adversarially verify $($unverified.Count) unverified finding(s): reproduce or refute each, set verdict." 'unverified findings remain' }
            if ($escalate.Count -gt 0) {
                return & $step 'VERIFY' ("Mark as escalated before continuing: {0}" -f ($escalate -join ', ')) 'confirmed findings that must not be auto-fixed (out of scope, oscillating, or out of attempts)'
            }
            if ($fixable.Count -gt 0) { return & $step 'FIX' "Fix up to $($b.maxFixesPerIteration) of $($fixable.Count) confirmed finding(s), highest severity first, one commit each." 'confirmed in-scope findings' }
            $newThisIteration = @($findings | Where-Object { $_.firstIteration -eq $it -and $_.verdict -eq 'confirmed' })
            $reason = if ($newThisIteration.Count -eq 0) { 'fixed point: review found no new confirmed issues' } else { 'all confirmed findings are fixed, escalated, or below the fix threshold' }
            return & $step 'DONE' 'Write the final report.' $reason $true
        }
        'FIX' {
            $fixedNow = @($findings | Where-Object { $_.status -eq 'fixed' -and $_.fixedIteration -eq $it })
            if ($fixedNow.Count -eq 0 -and $fixable.Count -eq 0) { return & $step 'DONE' 'Write the final report.' 'nothing left that may be fixed' $true }
            return & $step 'GATE' 'Run the scope profile gates; record each result (skipped = not-run, never passed).' "$($fixedNow.Count) fix(es) this iteration"
        }
        'GATE' {
            if ($thisGates.Count -eq 0) { return & $step 'GATE' 'Run the scope profile gates and record each result.' 'no gate results for this iteration' }
            $latest = @{}
            foreach ($g in $thisGates) { $latest[$g.name] = $g.result }
            if ($latest.Values -contains 'failed') { return & $step 'FIX' 'Repair the regression your fix introduced (or revert that fix commit), then re-run gates.' 'a gate failed' }
            return & $step 'REVIEW' 'Recompute the impacted subgraph of files changed by this iteration''s fixes and set it as the new frontier, then review it.' "gates green for iteration $it"
        }
    }
}

function Add-ReviewCost {
<#
.SYNOPSIS
    Records spend and savings.  Enforces the Jev spend cap by switching the
    run to spending mode (policy.jevAvailable = false), never by skipping work.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Ledger,
        [int]$JevCalls = 0,
        [int64]$JevInputTokens = 0,
        [ValidateSet('opus', 'sonnet', 'haiku')][string]$Tier,
        [int]$Dispatches = 0,
        [int64]$Chars = 0,
        [ValidateSet('nodesSkipped', 'lensesPruned', 'findingsSettledByJev', 'fixesClearedByJev')][string]$Avoided,
        [int]$AvoidedCount = 0,
        [int]$AuditSampled = 0,
        [int]$AuditMisses = 0
    )
    $c = $Ledger.cost
    $c.jev.calls = [int]$c.jev.calls + $JevCalls
    $c.jev.inputTokens = [int64]$c.jev.inputTokens + $JevInputTokens
    if ($Tier) {
        $c.llm[$Tier].dispatches = [int]$c.llm[$Tier].dispatches + $Dispatches
        $c.llm[$Tier].chars = [int64]$c.llm[$Tier].chars + $Chars
    }
    if ($Avoided) { $c.avoided[$Avoided] = [int]$c.avoided[$Avoided] + $AvoidedCount }
    $c.audit.sampled = [int]$c.audit.sampled + $AuditSampled
    $c.audit.misses = [int]$c.audit.misses + $AuditMisses
    if ($AuditMisses -gt 0 -and $Ledger.policy.allowSkip) {
        $Ledger.policy.allowSkip = $false
        $Ledger.history = @($Ledger.history) + [ordered]@{ utc = [datetime]::UtcNow.ToString('o'); from = $Ledger.state; to = $Ledger.state; reason = 'audit miss: D1 skipping disabled for the rest of the run' }
    }
    $jevUsd = [double]$c.jev.inputTokens / 1e6 * 0.042
    if ($jevUsd -ge [double]$Ledger.budget.jevSpendCapUsd -and $Ledger.policy.jevAvailable) {
        $Ledger.policy.jevAvailable = $false
        $Ledger.history = @($Ledger.history) + [ordered]@{ utc = [datetime]::UtcNow.ToString('o'); from = $Ledger.state; to = $Ledger.state; reason = ('Jev spend cap reached (${0:N4}); spending mode for the rest of the run' -f $jevUsd) }
    }
    return $c
}

function Set-ReviewPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Ledger,
        [Nullable[bool]]$JevAvailable,
        [Nullable[bool]]$AllowSkip,
        [string]$Reason = 'policy change'
    )
    if ($null -ne $JevAvailable) { $Ledger.policy.jevAvailable = [bool]$JevAvailable }
    if ($null -ne $AllowSkip) { $Ledger.policy.allowSkip = [bool]$AllowSkip }
    $Ledger.history = @($Ledger.history) + [ordered]@{ utc = [datetime]::UtcNow.ToString('o'); from = $Ledger.state; to = $Ledger.state; reason = $Reason }
    return $Ledger.policy
}

function Get-ReviewSummary {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Ledger)
    $f = @($Ledger.findings)
    $count = { param($s) @($f | Where-Object { $_.status -eq $s }).Count }
    [pscustomobject]@{
        runId      = $Ledger.runId
        state      = $Ledger.state
        iteration  = $Ledger.iteration
        stop       = $Ledger.stop
        findings   = [pscustomobject]@{
            total = $f.Count; open = & $count 'open'; fixed = & $count 'fixed'
            escalated = & $count 'escalated'; wontfix = & $count 'wontfix'
        }
        gatesNotRun = @($Ledger.gates | Where-Object result -eq 'not-run' | ForEach-Object name | Select-Object -Unique)
        frontier   = @($Ledger.frontier).Count
        policy     = $Ledger.policy
        cost       = $Ledger.cost
        estLlmTokens = [int64](([int64]$Ledger.cost.llm.opus.chars + [int64]$Ledger.cost.llm.sonnet.chars + [int64]$Ledger.cost.llm.haiku.chars) / 4)
        jevUsd     = [math]::Round([double]$Ledger.cost.jev.inputTokens / 1e6 * 0.042, 6)
    }
}

Export-ModuleMember -Function New-ReviewLedger, Get-ReviewLedger, Save-ReviewLedger, Get-ReviewFingerprint,
    Add-ReviewFinding, Set-ReviewFinding, Add-ReviewGate, Set-ReviewFrontier, Move-ReviewState,
    Get-ReviewNextStep, Get-ReviewSummary, Add-ReviewCost, Set-ReviewPolicy
