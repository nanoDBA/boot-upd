# ------------------------------------------------------------------------------
# File:        Invoke-Jev.ps1
# Description: 🎯 Ask Jev typed questions about one piece of state
# Purpose:     Command-line front door for a single Jev evaluation so Claude (or
#              a human) can get a calibrated choice/score/yes-no without writing
#              HTTP code.  Questions come from a JSON file or string; state from
#              a file, a string, or the pipeline.
# Created:     2026-09-24
# Modified:    2026-09-24
# ------------------------------------------------------------------------------

<#
.SYNOPSIS
    Evaluates one state against Jev questions and prints the answers.

.EXAMPLE
    ./Invoke-Jev.ps1 -StatePath ./ticket.txt -QuestionsPath ./q.json -AsJson

.EXAMPLE
    Get-Content ./errorlog.txt -Raw | ./Invoke-Jev.ps1 -Questions '{"bad":{"type":"noul","instructions":"Does this log show database corruption?"}}'

.EXAMPLE
    ./Invoke-Jev.ps1 -State 'Payouts failing for 3 days!' -QuestionsPath ../../jev-triage/rubrics/email.json
    # A rubric file is accepted too: its "questions" property is used.
#>
[CmdletBinding(DefaultParameterSetName = 'Text')]
param(
    [Parameter(ParameterSetName = 'Text', ValueFromPipeline)]
    [AllowEmptyString()]
    [string]$State,

    [Parameter(ParameterSetName = 'File', Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$StatePath,

    # Treat the state file as JSON and send it structured, not as text.
    [Parameter(ParameterSetName = 'File')]
    [switch]$StateIsJson,

    [string]$Questions,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$QuestionsPath,

    [string]$Model,

    # Emit the raw API answers (with probability maps) instead of the summary.
    [switch]$Raw,

    [switch]$AsJson
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path $PSScriptRoot 'JevClient.psm1') -Force -Verbose:$false
    $pipelineText = [System.Text.StringBuilder]::new()
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'Text' -and $null -ne $State) {
        [void]$pipelineText.AppendLine($State)
    }
}

end {
    if ([string]::IsNullOrWhiteSpace($Questions) -eq [string]::IsNullOrWhiteSpace($QuestionsPath)) {
        throw 'Provide exactly one of -Questions (JSON text) or -QuestionsPath.'
    }
    $questionSource = if ($QuestionsPath) { Get-Content -LiteralPath $QuestionsPath -Raw } else { $Questions }
    $parsed = $questionSource | ConvertFrom-Json -AsHashtable -Depth 30
    # Accept a jev-triage rubric file directly.
    $questionMap = if ($parsed.ContainsKey('questions') -and $parsed['questions'] -is [System.Collections.IDictionary]) {
        $parsed['questions']
    } else { $parsed }

    $stateValue = if ($PSCmdlet.ParameterSetName -eq 'File') {
        $text = Get-Content -LiteralPath $StatePath -Raw
        if ($StateIsJson) { $text | ConvertFrom-Json -AsHashtable -Depth 30 } else { $text }
    } else { $pipelineText.ToString().TrimEnd() }

    $params = @{ State = $stateValue; Questions = $questionMap }
    if ($Model) { $params.Model = $Model }
    $result = Invoke-JevEvaluation @params

    $answers = if ($Raw) { $result.Answers } else { $result.Answers | ConvertTo-JevAnswerSummary }
    $output = [pscustomobject]@{
        model          = $result.Model
        stateTruncated = $result.StateTruncated
        answers        = $answers
        usage          = $result.Usage
    }
    if ($AsJson) { $output | ConvertTo-Json -Depth 10 } else { $output }
}
