# ------------------------------------------------------------------------------
# File:        Invoke-JevReviewGate.ps1
# Description: 💸 Jev decision points D1-D6 for the unattended review loop
# Purpose:     Spends fractions of a cent so frontier-LLM tokens go only where
#              they matter:
#              D1 node-triage    skip / review / audit, which lenses, which tier
#              D2 context-select which neighbor passages the reviewer sees
#              D4 finding-verify evidence check in code, then Jev verdict +
#                                duplicate detection; high/critical -> LLM
#              D5 fix-tier       cheapest model that can write the fix
#              D6 fix-check      fix on target? scope creep? weakened test?
#              Every Jev failure resolves toward MORE LLM review, never less.
#              Thresholds come from the scope profile; code applies them.
# Created:     2026-09-25
# Modified:    2026-09-25
# ------------------------------------------------------------------------------

<#
.SYNOPSIS
    Runs one Jev decision over a batch of items and emits routing JSON.

.EXAMPLE
    ./Invoke-JevReviewGate.ps1 -Decision node-triage -InputPath .review-loop/d1.json `
        -LedgerPath .review-loop/ledger.json -OutputPath .review-loop/d1.out.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('node-triage', 'context-select', 'finding-verify', 'fix-tier', 'fix-check')]
    [string]$Decision,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputPath,

    # Reads policy (shadow / allowSkip / jevAvailable) and records cost.
    [string]$LedgerPath,

    # Scope profile with thresholds and tier rules.  Defaults are built in.
    [string]$ProfilePath,

    [string]$RepoRoot = (Get-Location).Path,

    [string]$OutputPath,

    [ValidateRange(1, 32)]
    [int]$ThrottleLimit = 8,

    # Seed for the audit sample (reproducible runs / tests).
    [int]$Seed = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$jevModule = Join-Path $PSScriptRoot '../../jev/scripts/JevClient.psm1'
$loopModule = Join-Path $PSScriptRoot 'ReviewLoop.psm1'
Import-Module $jevModule -Force -Verbose:$false
Import-Module $loopModule -Force -Verbose:$false

# --- configuration ---------------------------------------------------------------
$defaults = @{
    thresholds = @{
        skipTrivialAtLeast = 0.8; skipRiskBelow = 0.8; skipHighStakesBelow = 0.3
        lensAtLeast = 0.35; tierConfidenceAtLeast = 0.6; highStakesForceOpus = 0.5
        contextNeededAtLeast = 0.4
        autoConfirmSupportedAtLeast = 0.85; autoRejectContradictedAtLeast = 0.85; autoRejectStyleOnlyAtLeast = 0.8
        mechanicalAtLeast = 0.8
        fixAddressesAtLeast = 0.6; fixScopeCreepBelow = 0.5; fixWeakensTestBelow = 0.2
        auditFraction = 0.10; auditMin = 3; auditMax = 10
    }
    tiers = @{ default = 'sonnet'; max = 'opus'; alwaysReview = @(); minTierByPath = @{} }
}
$profileData = if ($ProfilePath) { Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json -AsHashtable -Depth 20 } else { @{} }
$t = $defaults.thresholds.Clone()
if ($profileData.Contains('thresholds')) { foreach ($k in $profileData.thresholds.Keys) { $t[$k] = $profileData.thresholds[$k] } }
$tiers = $defaults.tiers.Clone()
if ($profileData.Contains('tiers')) { foreach ($k in $profileData.tiers.Keys) { $tiers[$k] = $profileData.tiers[$k] } }

$ledger = if ($LedgerPath) { Get-ReviewLedger -Path $LedgerPath } else { $null }
$policy = if ($ledger) { $ledger.policy } else { @{ shadow = $false; allowSkip = $true; jevAvailable = $true } }

$rank = @{ haiku = 0; sonnet = 1; opus = 2 }
$names = 'haiku', 'sonnet', 'opus'
function Limit-Tier { param([string]$Tier, [string]$File)
    $r = $rank[$Tier]
    foreach ($pattern in @($tiers.minTierByPath.Keys)) {
        if ($File -like $pattern) { $r = [math]::Max($r, $rank[[string]$tiers.minTierByPath[$pattern]]) }
    }
    foreach ($pattern in @($tiers.alwaysReview)) { if ($File -like $pattern) { $r = [math]::Max($r, $rank['sonnet']) } }
    return $names[[math]::Min($r, $rank[[string]$tiers.max])]
}
function Test-AlwaysReview { param([string]$File) foreach ($p in @($tiers.alwaysReview)) { if ($File -like $p) { return $true } }; return $false }

function Get-QuestionSet { param([string]$Name)
    $q = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../questions/$Name.json") -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    [void]$q.Remove('_doc'); return $q
}

$items = @(Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -AsHashtable -Depth 30)
if ($items.Count -eq 1 -and $null -eq $items[0]) { $items = @() }

# --- build per-item requests -------------------------------------------------------
$lenses = 'correctness', 'security', 'error_handling', 'concurrency', 'resources', 'contract_drift', 'test_gap'
$requests = [System.Collections.Generic.List[object]]::new()
$preDecided = @{}

foreach ($item in $items) {
    switch ($Decision) {
        'node-triage' {
            $state = [ordered]@{
                change = [ordered]@{ file = $item.file; node = $item.id; kind = $item.kind; diff = [string]$item.diff }
                neighbors = [ordered]@{ callers = @($item.callers); callees = @($item.callees) }
            }
            $requests.Add(@{ key = $item.id; state = $state; questions = (Get-QuestionSet 'node-triage') })
        }
        'context-select' {
            $state = [ordered]@{ change = [ordered]@{ node = $item.nodeId; diff = [string]$item.diff }; passage = [ordered]@{ id = $item.candidateId; relation = $item.relation; text = [string]$item.text } }
            $requests.Add(@{ key = "$($item.nodeId)|$($item.candidateId)"; state = $state; questions = (Get-QuestionSet 'context-select') })
        }
        'finding-verify' {
            # Evidence check in code: a quote that is not in the file is fabricated.  Free, exact.
            $full = Join-Path $RepoRoot $item.file
            $norm = { param($s) ([string]$s -replace '\s+', ' ').Trim() }
            $evidence = & $norm $item.evidence
            if ([string]::IsNullOrWhiteSpace($evidence)) {
                $preDecided[$item.id] = [ordered]@{ id = $item.id; route = 'llm'; tier = (Limit-Tier 'sonnet' $item.file); reason = 'no evidence quoted' }
                continue
            }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or -not (& $norm ([IO.File]::ReadAllText($full))).Contains($evidence)) {
                $preDecided[$item.id] = [ordered]@{ id = $item.id; route = 'reject'; verdict = 'fabricated'; reason = 'quoted evidence not found in file at HEAD' }
                continue
            }
            $q = Get-QuestionSet 'finding-verify'
            $open = @($item.openFindings | Where-Object { $_ -and $_.id -ne $item.id })
            if ($open.Count -gt 0) {
                $criteria = [ordered]@{ new = 'None of the listed findings describes the same underlying problem' }
                foreach ($o in ($open | Select-Object -First 200)) { $criteria[[string]$o.id] = [string]$o.summary }
                $q['duplicate_of'] = @{ type = 'choice'; instructions = 'Does `finding.summary` describe the same underlying problem as one of these existing findings? Pick it, or "new".'; criteria = $criteria }
            }
            $state = [ordered]@{
                finding = [ordered]@{ lens = $item.lens; severity = $item.severity; summary = $item.summary; evidence = $item.evidence }
                code = [ordered]@{ file = $item.file; excerpt = [string]$item.excerpt }
            }
            $requests.Add(@{ key = $item.id; state = $state; questions = $q })
        }
        'fix-tier' {
            $state = [ordered]@{ finding = [ordered]@{ lens = $item.lens; severity = $item.severity; summary = $item.summary }; code = [ordered]@{ file = $item.file; excerpt = [string]$item.excerpt } }
            $requests.Add(@{ key = $item.id; state = $state; questions = (Get-QuestionSet 'fix-tier') })
        }
        'fix-check' {
            $state = [ordered]@{ finding = [ordered]@{ summary = $item.summary }; fix = [ordered]@{ diff = [string]$item.diff } }
            $requests.Add(@{ key = $item.id; state = $state; questions = (Get-QuestionSet 'fix-check') })
        }
    }
}

# --- call Jev in parallel (unless the run is in spending mode) ----------------------
$answers = @{}
$jevTokens = [int64]0; $jevCalls = 0
if ($requests.Count -gt 0 -and $policy.jevAvailable) {
    $apiKeyOk = $true
    try { $apiKey = Get-JevApiKey } catch { $apiKeyOk = $false; Write-Warning "Jev unavailable ($($_.Exception.Message)); failing toward LLM review." }
    if ($apiKeyOk) {
        $results = $requests | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            Import-Module $using:jevModule -Verbose:$false
            try {
                $r = Invoke-JevEvaluation -State $_.state -Questions $_.questions -ApiKey $using:apiKey -TimeoutSec 20 -MaxAttempts 3
                [pscustomobject]@{ key = $_.key; answers = $r.Answers; tokens = [int64]$r.Usage.input_tokens; error = $null }
            }
            catch { [pscustomobject]@{ key = $_.key; answers = $null; tokens = 0; error = $_.Exception.Message } }
        }
        foreach ($r in $results) {
            if ($r.answers) { $answers[$r.key] = $r.answers; $jevCalls++; $jevTokens += $r.tokens }
            else { Write-Warning "Jev failed for '$($r.key)': $($r.error)" }
        }
    }
}

function Get-A { param($Answers, [string]$Name, [string]$Field)
    if ($null -eq $Answers) { return $null }
    $p = $Answers.PSObject.Properties[$Name]; if (-not $p) { return $null }
    $v = $p.Value.PSObject.Properties[$Field]; if ($v) { return $v.Value } else { return $null }
}

# --- apply gates in code -----------------------------------------------------------
$out = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[object]]::new()
$avoided = @{ nodesSkipped = 0; lensesPruned = 0; findingsSettledByJev = 0; fixesClearedByJev = 0 }

foreach ($item in $items) {
    switch ($Decision) {
        'node-triage' {
            $a = $answers[$item.id]
            if (-not $a) {
                $out.Add([ordered]@{ id = $item.id; action = 'review'; lenses = $lenses; tier = (Limit-Tier $tiers.default $item.file); reason = 'jev unavailable: full review' }); continue
            }
            $trivial = [double](Get-A $a 'trivial_change' 'noul'); $risk = [double](Get-A $a 'risk' 'score'); $stakes = [double](Get-A $a 'high_stakes' 'noul')
            $flagged = @($lenses | Where-Object { [double](Get-A $a "lens_$_" 'noul') -ge [double]$t.lensAtLeast })
            if ($flagged.Count -eq 0) {
                $flagged = @($lenses | Sort-Object { - [double](Get-A $a "lens_$_" 'noul') } | Select-Object -First 1)
            }
            $tierChoice = [string](Get-A $a 'tier' 'choice')
            $tierConf = [double](Get-A $a 'tier' 'confidence')
            $tier = if ($tierChoice -in $names -and $tierConf -ge [double]$t.tierConfidenceAtLeast) { $tierChoice } else { [string]$tiers.default }
            if ($stakes -ge [double]$t.highStakesForceOpus) { $tier = 'opus' }
            $tier = Limit-Tier $tier $item.file
            $canSkip = $trivial -ge [double]$t.skipTrivialAtLeast -and $risk -lt [double]$t.skipRiskBelow -and $stakes -lt [double]$t.skipHighStakesBelow -and -not (Test-AlwaysReview $item.file)
            $nodeRoute = [ordered]@{
                id = $item.id; action = 'review'; lenses = $flagged; tier = $tier
                signals = [ordered]@{ trivial = [math]::Round($trivial, 3); risk = [math]::Round($risk, 3); highStakes = [math]::Round($stakes, 3); tierConfidence = [math]::Round($tierConf, 3) }
                reason = ''
            }
            if ($canSkip -and $policy.allowSkip -and -not $policy.shadow) {
                $nodeRoute.action = 'skip'; $nodeRoute.lenses = @(); $nodeRoute.reason = 'trivial, low risk, not high stakes'
                $skipped.Add($nodeRoute)
            }
            elseif ($canSkip) {
                $nodeRoute.reason = if ($policy.shadow) { 'shadow: would have skipped' } else { 'skip disabled by audit miss' }
                $nodeRoute['shadowSkip'] = $true
            }
            else { $avoided.lensesPruned += ($lenses.Count - $flagged.Count) }
            $out.Add($nodeRoute)
        }
        'context-select' {
            $key = "$($item.nodeId)|$($item.candidateId)"
            $a = $answers[$key]
            $needed = if ($a) { [double](Get-A $a 'needed' 'noul') } else { 1.0 }
            $force = [bool]($item.Contains('mustInclude') -and $item.mustInclude)
            $out.Add([ordered]@{ nodeId = $item.nodeId; candidateId = $item.candidateId; include = ($force -or $needed -ge [double]$t.contextNeededAtLeast); needed = [math]::Round($needed, 3); reason = $(if (-not $a) { 'jev unavailable: include' } elseif ($force) { 'must include' } else { '' }) })
        }
        'finding-verify' {
            if ($preDecided.ContainsKey($item.id)) { $out.Add($preDecided[$item.id]); if ($preDecided[$item.id].route -eq 'reject') { $avoided.findingsSettledByJev++ }; continue }
            $a = $answers[$item.id]
            $sevHigh = $item.severity -in 'critical', 'high'
            $llmTier = Limit-Tier $(if ($sevHigh) { 'opus' } else { 'sonnet' }) $item.file
            if (-not $a) { $out.Add([ordered]@{ id = $item.id; route = 'llm'; tier = $llmTier; reason = 'jev unavailable' }); continue }
            $verdict = [string](Get-A $a 'verdict' 'choice')
            $conf = [double](Get-A $a 'verdict' 'confidence')
            $style = [double](Get-A $a 'style_only' 'noul')
            $dup = [string](Get-A $a 'duplicate_of' 'choice')
            $dupConf = [double](Get-A $a 'duplicate_of' 'confidence')
            $r = [ordered]@{ id = $item.id; route = 'llm'; tier = $llmTier; verdict = $verdict; confidence = [math]::Round($conf, 3); styleOnly = [math]::Round($style, 3); duplicateOf = $null; reason = '' }
            if ($dup -and $dup -ne 'new' -and $dupConf -ge 0.6) { $r.duplicateOf = $dup }
            if ($sevHigh) { $r.reason = 'high/critical: always LLM-verified' }
            elseif ($verdict -eq 'supported' -and $conf -ge [double]$t.autoConfirmSupportedAtLeast) { $r.route = 'confirm'; $r.reason = 'jev: supported with high confidence'; $avoided.findingsSettledByJev++ }
            elseif ($verdict -eq 'contradicted' -and $conf -ge [double]$t.autoRejectContradictedAtLeast) { $r.route = 'reject'; $r.reason = 'jev: contradicted with high confidence'; $avoided.findingsSettledByJev++ }
            elseif ($item.severity -eq 'low' -and $style -ge [double]$t.autoRejectStyleOnlyAtLeast) { $r.route = 'reject'; $r.reason = 'jev: style-only, low severity'; $avoided.findingsSettledByJev++ }
            else { $r.reason = 'jev not decisive' }
            $out.Add($r)
        }
        'fix-tier' {
            $a = $answers[$item.id]
            if (-not $a) { $out.Add([ordered]@{ id = $item.id; tier = (Limit-Tier 'sonnet' $item.file); reason = 'jev unavailable' }); continue }
            $choice = [string](Get-A $a 'tier' 'choice'); $conf = [double](Get-A $a 'tier' 'confidence')
            $stakes = [double](Get-A $a 'high_stakes' 'noul'); $mech = [double](Get-A $a 'mechanical' 'noul')
            $tier = if ($choice -in $names -and $conf -ge [double]$t.tierConfidenceAtLeast) { $choice } else { 'sonnet' }
            if ($mech -ge [double]$t.mechanicalAtLeast) { $tier = 'haiku' }
            if ($stakes -ge [double]$t.highStakesForceOpus -or $item.severity -eq 'critical') { $tier = 'opus' }
            $out.Add([ordered]@{ id = $item.id; tier = (Limit-Tier $tier $item.file); signals = [ordered]@{ mechanical = [math]::Round($mech, 3); highStakes = [math]::Round($stakes, 3); tierConfidence = [math]::Round($conf, 3) } })
        }
        'fix-check' {
            $a = $answers[$item.id]
            if (-not $a) { $out.Add([ordered]@{ id = $item.id; route = 'llm-review'; reason = 'jev unavailable' }); continue }
            $addr = [double](Get-A $a 'addresses' 'noul'); $creep = [double](Get-A $a 'scope_creep' 'noul'); $weak = [double](Get-A $a 'weakens_test' 'noul')
            $ok = $addr -ge [double]$t.fixAddressesAtLeast -and $creep -lt [double]$t.fixScopeCreepBelow -and $weak -lt [double]$t.fixWeakensTestBelow
            if ($ok) { $avoided.fixesClearedByJev++ }
            $out.Add([ordered]@{ id = $item.id; route = $(if ($ok) { 'gates' } else { 'llm-review' }); signals = [ordered]@{ addresses = [math]::Round($addr, 3); scopeCreep = [math]::Round($creep, 3); weakensTest = [math]::Round($weak, 3) } })
        }
    }
}

# --- drop audit: sample skipped nodes for a cheap full review ---------------------
if ($Decision -eq 'node-triage' -and $skipped.Count -gt 0) {
    $n = [math]::Min($skipped.Count, [math]::Min([int]$t.auditMax, [math]::Max([int]$t.auditMin, [math]::Ceiling($skipped.Count * [double]$t.auditFraction))))
    $rng = if ($Seed) { [Random]::new($Seed) } else { [Random]::new() }
    $sample = @($skipped | Sort-Object { $rng.Next() } | Select-Object -First $n)
    foreach ($s in $sample) { $s.action = 'audit'; $s.lenses = $lenses; $s.tier = 'haiku'; $s.reason = 'drop audit sample' }
    $avoided.nodesSkipped = $skipped.Count - $sample.Count
}

# --- record cost ---------------------------------------------------------------------
if ($ledger) {
    [void](Add-ReviewCost -Ledger $ledger -JevCalls $jevCalls -JevInputTokens $jevTokens)
    foreach ($k in $avoided.Keys) { if ($avoided[$k] -gt 0) { [void](Add-ReviewCost -Ledger $ledger -Avoided $k -AvoidedCount $avoided[$k]) } }
    if ($requests.Count -gt 0 -and $policy.jevAvailable -and $jevCalls -eq 0) {
        [void](Set-ReviewPolicy -Ledger $ledger -JevAvailable $false -Reason "Jev returned nothing for $($requests.Count) request(s) in $Decision; spending mode")
    }
    Save-ReviewLedger -Ledger $ledger -Path $LedgerPath
}

$json = [ordered]@{
    decision = $Decision
    jev = [ordered]@{ calls = $jevCalls; inputTokens = $jevTokens; usd = [math]::Round($jevTokens / 1e6 * 0.042, 6); available = [bool]$policy.jevAvailable }
    avoided = $avoided
    items = @($out)
} | ConvertTo-Json -Depth 10
if ($OutputPath) { Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8 } else { $json }
