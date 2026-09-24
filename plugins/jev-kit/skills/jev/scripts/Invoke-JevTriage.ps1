# ------------------------------------------------------------------------------
# File:        Invoke-JevTriage.ps1
# Description: 🗂️ Bulk-classify items with Jev, then route them into buckets
# Purpose:     The "cheap model sorts, expensive model thinks" pipeline:
#              - Reads JSONL / JSON / CSV / plain-text logs (or pipeline input)
#              - Asks every item the same rubric questions in parallel
#              - Applies deterministic, ordered routing rules in code
#              - Never drops an item silently: API failures land in 'error',
#                truncated or unmatched-low-confidence items land in 'review'
#              Hand only the buckets that matter to Claude afterward.
# Created:     2026-09-24
# Modified:    2026-09-24
# ------------------------------------------------------------------------------

<#
.SYNOPSIS
    Triage many items through a Jev rubric and route each into a bucket.

.DESCRIPTION
    A rubric is JSON with "questions" (a Jev question map) and "route":

      "route": {
        "rules": [
          { "bucket": "page",  "when": { "question": "corruption", "noulAtLeast": 0.7 } },
          { "bucket": "drop",  "when": [ { "question": "category", "choiceIn": ["info"], "minConfidence": 0.6 },
                                         { "question": "severity", "scoreBelow": 1 } ] }
        ],
        "default": "act",
        "reviewWhen": { "question": "category", "confidenceBelow": 0.5 }
      }

    Rules run in order; the first match wins.  "when" is one condition or an
    array (all must hold).  Condition keys: noulAtLeast, noulBelow, choiceIn,
    choiceNotIn, scoreAtLeast, scoreBelow, confidenceBelow, and an optional
    minConfidence that must also hold for choice/score tests.  When no rule
    matches: reviewWhen (if it holds) or a truncated state sends the item to
    'review'; otherwise it gets "default".

.EXAMPLE
    ./Invoke-JevTriage.ps1 -InputPath ./ERRORLOG -RubricPath ../../jev-triage/rubrics/sql-errorlog.json `
        -Pattern 'Error:|Severity|failed|deadlock|I/O' -OutputPath ./errorlog.triage.jsonl

.EXAMPLE
    ./Invoke-JevTriage.ps1 -InputPath ./mail.jsonl -StateProperty body -IdProperty messageId `
        -RubricPath ../../jev-triage/rubrics/email.json -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Path')]
param(
    [Parameter(ParameterSetName = 'Path', Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputPath,

    [Parameter(ParameterSetName = 'Pipeline', Mandatory, ValueFromPipeline)]
    [object]$InputObject,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RubricPath,

    # For structured records: property to send as state (default: whole record).
    [string]$StateProperty,

    # For structured records: property to use as the item id (default: ordinal).
    [string]$IdProperty,

    # Plain-text input: lines grouped per item (e.g. 3 for multi-line log entries).
    [ValidateRange(1, 500)]
    [int]$LinesPerItem = 1,

    # Plain-text input: regex prefilter.  Lines that do not match are skipped
    # before any tokens are spent.  Regex is free; Jev is merely cheap.
    [string]$Pattern,

    [string]$OutputPath,

    [ValidateRange(1, 64)]
    [int]$ThrottleLimit = 8,

    # Spend guard.  Raise it deliberately; do not remove it.
    [ValidateRange(1, 1000000)]
    [int]$MaxItems = 5000,

    [string]$Model,

    [switch]$SummaryOnly,

    # Emit compact JSON lines (items, then the summary) for machine consumers.
    [switch]$AsJson
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $modulePath = Join-Path $PSScriptRoot 'JevClient.psm1'
    Import-Module $modulePath -Force -Verbose:$false

    $rubric = Get-Content -LiteralPath $RubricPath -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    if (-not $rubric.ContainsKey('questions')) { throw "Rubric '$RubricPath' has no 'questions' map." }
    $problems = Test-JevQuestionSet -Questions $rubric.questions
    if ($problems.Count -gt 0) { throw ("Rubric questions invalid:`n  " + ($problems -join "`n  ")) }
    $route = if ($rubric.ContainsKey('route')) { $rubric.route } else { @{} }

    $items = [System.Collections.Generic.List[object]]::new()
    $ordinal = 0

    function Add-TriageItem {
        param([object]$Record)
        $script:ordinal++
        $state = $Record
        $id = $script:ordinal
        if ($Record -is [System.Collections.IDictionary]) {
            if ($StateProperty) {
                if (-not $Record.Contains($StateProperty)) { throw "Item $($script:ordinal) has no '$StateProperty' property." }
                $state = $Record[$StateProperty]
            }
            if ($IdProperty -and $Record.Contains($IdProperty)) { $id = $Record[$IdProperty] }
        }
        if ($state -is [string] -and [string]::IsNullOrWhiteSpace($state)) { return }
        $items.Add([pscustomobject]@{ Id = $id; State = $state })
    }

    function ConvertTo-Hashtable {
        param([object]$Object)
        if ($Object -is [System.Collections.IDictionary] -or $Object -is [string]) { return $Object }
        $h = [ordered]@{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'Pipeline') { Add-TriageItem -Record (ConvertTo-Hashtable $InputObject) }
}

end {
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $ext = [IO.Path]::GetExtension($InputPath).ToLowerInvariant()
        switch ($ext) {
            { $_ -in '.jsonl', '.ndjson' } {
                foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $InputPath).ProviderPath)) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    Add-TriageItem -Record ($line | ConvertFrom-Json -AsHashtable -Depth 30)
                }
            }
            '.json' {
                $data = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -AsHashtable -Depth 30
                foreach ($record in @($data)) { Add-TriageItem -Record $record }
            }
            '.csv' {
                foreach ($row in (Import-Csv -LiteralPath $InputPath)) { Add-TriageItem -Record (ConvertTo-Hashtable $row) }
            }
            default {
                $buffer = [System.Collections.Generic.List[string]]::new()
                $lineNo = 0; $startLine = 0
                foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $InputPath).ProviderPath)) {
                    $lineNo++
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    if ($Pattern -and $buffer.Count -eq 0 -and $line -notmatch $Pattern) { continue }
                    if ($buffer.Count -eq 0) { $startLine = $lineNo }
                    $buffer.Add($line)
                    if ($buffer.Count -ge $LinesPerItem) {
                        $script:ordinal++
                        $items.Add([pscustomobject]@{ Id = "L$startLine"; State = ($buffer -join "`n") })
                        $buffer.Clear()
                    }
                }
                if ($buffer.Count -gt 0) {
                    $script:ordinal++
                    $items.Add([pscustomobject]@{ Id = "L$startLine"; State = ($buffer -join "`n") })
                }
            }
        }
    }

    if ($items.Count -eq 0) { Write-Warning 'Nothing to triage (empty input or everything filtered out).'; return }
    if ($items.Count -gt $MaxItems) {
        throw "Input has $($items.Count) items; -MaxItems is $MaxItems.  Prefilter with -Pattern or raise -MaxItems on purpose."
    }

    # Rough spend estimate: ~4 chars/token, questions resent per item.
    $questionChars = ($rubric.questions | ConvertTo-Json -Depth 30 -Compress).Length
    $stateChars = 0
    foreach ($i in $items) { $stateChars += if ($i.State -is [string]) { $i.State.Length } else { ($i.State | ConvertTo-Json -Depth 20 -Compress).Length } }
    $estTokens = [math]::Ceiling(($stateChars + $questionChars * $items.Count) / 4)
    $estCost = $estTokens / 1e6 * 0.042
    $plan = '{0} items, ~{1:N0} input tokens, ~${2:N4} at list price' -f $items.Count, $estTokens, $estCost
    if (-not $PSCmdlet.ShouldProcess($plan, 'Triage with Jev')) { return }
    Write-Verbose $plan

    # Fail on a missing key once, up front, not N times in parallel.
    $apiKey = Get-JevApiKey
    $questions = $rubric.questions

    $results = $items | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        Import-Module $using:modulePath -Verbose:$false
        $item = $_
        try {
            $params = @{ State = $item.State; Questions = $using:questions; ApiKey = $using:apiKey }
            if ($using:Model) { $params.Model = $using:Model }
            $r = Invoke-JevEvaluation @params
            [pscustomobject]@{ Id = $item.Id; State = $item.State; Answers = $r.Answers; Truncated = $r.StateTruncated; Error = $null; Tokens = $r.Usage.input_tokens }
        }
        catch {
            [pscustomobject]@{ Id = $item.Id; State = $item.State; Answers = $null; Truncated = $false; Error = $_.Exception.Message; Tokens = 0 }
        }
    }

    function Get-Answer { param($Answers, [string]$Question)
        if ($null -eq $Answers) { return $null }
        $p = $Answers.PSObject.Properties[$Question]
        if (-not $p) { throw "Routing references unknown question '$Question'." }
        return $p.Value
    }

    function Test-Condition { param($Answers, $Condition)
        $a = Get-Answer -Answers $Answers -Question $Condition.question
        if ($Condition.ContainsKey('minConfidence') -and $a.PSObject.Properties['confidence'] -and
            [double]$a.confidence -lt [double]$Condition.minConfidence) { return $false }
        foreach ($key in $Condition.Keys) {
            $v = $Condition[$key]
            $ok = switch ($key) {
                'question' { $true }
                'minConfidence' { $true }
                'noulAtLeast' { [double]$a.noul -ge [double]$v }
                'noulBelow' { [double]$a.noul -lt [double]$v }
                'choiceIn' { $a.choice -in @($v) }
                'choiceNotIn' { $a.choice -notin @($v) }
                'scoreAtLeast' { [double]$a.score -ge [double]$v }
                'scoreBelow' { [double]$a.score -lt [double]$v }
                'confidenceBelow' { [double]$a.confidence -lt [double]$v }
                default { throw "Unknown routing condition '$key'." }
            }
            if (-not $ok) { return $false }
        }
        return $true
    }

    function Test-When { param($Answers, $When)
        foreach ($c in @($When)) { if (-not (Test-Condition -Answers $Answers -Condition $c)) { return $false } }
        return $true
    }

    $default = if ($route.ContainsKey('default')) { $route.default } else { 'act' }
    $routed = foreach ($r in $results) {
        $bucket = $null; $rule = $null
        if ($r.Error) { $bucket = 'error' }
        else {
            $index = 0
            foreach ($candidate in @($route['rules'])) {
                if ($null -eq $candidate) { continue }
                $index++
                if (Test-When -Answers $r.Answers -When $candidate.when) { $bucket = $candidate.bucket; $rule = $index; break }
            }
            if (-not $bucket) {
                $needsReview = $r.Truncated -or ($route.ContainsKey('reviewWhen') -and (Test-When -Answers $r.Answers -When $route.reviewWhen))
                $bucket = if ($needsReview) { 'review' } else { $default }
            }
        }
        $preview = if ($r.State -is [string]) { $r.State } else { $r.State | ConvertTo-Json -Depth 5 -Compress }
        [pscustomobject][ordered]@{
            id        = $r.Id
            bucket    = $bucket
            rule      = $rule
            truncated = $r.Truncated
            answers   = if ($r.Answers) { $r.Answers | ConvertTo-JevAnswerSummary } else { $null }
            error     = $r.Error
            preview   = $preview.Substring(0, [math]::Min(300, $preview.Length))
        }
    }

    # Stable order for humans and diffs.
    $routed = @($routed | Sort-Object { $s = [string]$_.id; if ($s -match '^L?(\d+)$') { [int64]$Matches[1] } else { [int64]::MaxValue } }, { [string]$_.id })

    if ($OutputPath) {
        $routed | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress } | Set-Content -LiteralPath $OutputPath -Encoding utf8
    }

    $summary = [pscustomobject]@{
        items       = $routed.Count
        buckets     = [pscustomobject]($routed | Group-Object bucket | Sort-Object Count -Descending |
                        ForEach-Object -Begin { $h = [ordered]@{} } -Process { $h[$_.Name] = $_.Count } -End { $h })
        errors      = @($routed | Where-Object bucket -eq 'error').Count
        inputTokens = [int64]($results | Measure-Object Tokens -Sum).Sum
        outputPath  = $OutputPath
    }

    $emit = if ($SummaryOnly -or $OutputPath) { @($summary) } else { @($routed) + $summary }
    if ($AsJson) { $emit | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress } } else { $emit }
}
