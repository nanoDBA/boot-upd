# ------------------------------------------------------------------------------
# File:        JevClient.psm1
# Description: 🧠 Minimal, defensive PowerShell 7 client for the TypeSafe Jev API
# Purpose:     Shared plumbing for the jev-kit skills:
#              - Resolves the API key without ever echoing it
#              - Validates questions locally before paying for a 422
#              - Retries 429/529/5xx/network faults with Retry-After + jitter
#              - Guards the 32k-token state budget instead of hoping
#              Built for pipelines where one bad record must not sink the run.
# Created:     2026-09-24
# Modified:    2026-09-24
# ------------------------------------------------------------------------------

Set-StrictMode -Version Latest

$script:DefaultBaseUrl = 'https://api.typesafe.ai'
$script:DefaultModel = 'jev-latest'
$script:DefaultSecretName = 'TypeSafeApiKey'
# Jev 1.13 allows 32k tokens for state plus the longest question.  At ~4 chars
# per token, 100k chars leaves headroom for the question text.
$script:DefaultMaxStateChars = 100000

function Get-JevApiKey {
<#
.SYNOPSIS
    Resolves the TypeSafe API key from the environment or SecretManagement.

.DESCRIPTION
    Order: TYPESAFE_API_KEY environment variable, then a SecretManagement
    secret (default name TypeSafeApiKey).  Throws when neither exists.  The key
    is returned as a plain string for the Authorization header only; callers
    must never log it.

.PARAMETER SecretName
    SecretManagement secret name to try when the environment variable is empty.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$SecretName = $script:DefaultSecretName
    )

    if (-not [string]::IsNullOrWhiteSpace($env:TYPESAFE_API_KEY)) {
        return $env:TYPESAFE_API_KEY.Trim()
    }

    if (Get-Command -Name Get-Secret -ErrorAction SilentlyContinue) {
        try {
            $secret = Get-Secret -Name $SecretName -AsPlainText -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($secret)) { return $secret.Trim() }
        }
        catch {
            Write-Verbose "SecretManagement lookup for '$SecretName' failed: $($_.Exception.Message)"
        }
    }

    throw ("No TypeSafe API key.  Set TYPESAFE_API_KEY for this process, or store it with " +
        "Set-Secret -Name $SecretName (Microsoft.PowerShell.SecretManagement).  " +
        'Keys: https://console.typesafe.ai/keys')
}

function Test-JevQuestionSet {
<#
.SYNOPSIS
    Validates a Jev question map against the documented API limits.

.DESCRIPTION
    Returns a list of problems (empty when valid).  Checks type, instructions,
    Choice option count (1-255), and Score level count (2-10).  Catching these
    locally avoids burning a round trip on a 422.

.PARAMETER Questions
    Hashtable or PSCustomObject keyed by question id.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object]$Questions
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $entries = ConvertTo-JevEntryList -InputObject $Questions
    if ($entries.Count -eq 0) {
        $problems.Add('Question set is empty.')
        return , $problems.ToArray()
    }

    foreach ($entry in $entries) {
        $id = $entry.Key
        $q = $entry.Value
        $type = Get-JevField -InputObject $q -Name 'type'
        $instructions = Get-JevField -InputObject $q -Name 'instructions'
        $criteria = Get-JevField -InputObject $q -Name 'criteria'

        if ($type -notin 'noul', 'choice', 'score') {
            $problems.Add("[$id] type must be noul, choice, or score (got '$type').")
            continue
        }
        if ($null -eq $instructions -or ($instructions -is [string] -and [string]::IsNullOrWhiteSpace($instructions))) {
            $problems.Add("[$id] instructions are required.")
        }
        switch ($type) {
            'choice' {
                $options = ConvertTo-JevEntryList -InputObject $criteria
                if ($options.Count -lt 1 -or $options.Count -gt 255) {
                    $problems.Add("[$id] choice needs 1-255 options in criteria (got $($options.Count)).")
                }
            }
            'score' {
                $levels = @($criteria | Where-Object { $null -ne $_ })
                if ($levels.Count -lt 2 -or $levels.Count -gt 10) {
                    $problems.Add("[$id] score needs 2-10 ordered levels in criteria (got $($levels.Count)).")
                }
            }
        }
    }
    return , $problems.ToArray()
}

function Invoke-JevEvaluation {
<#
.SYNOPSIS
    Evaluates one state against a map of typed questions.

.DESCRIPTION
    POSTs to /v1/systemone.  Retries 408/429/5xx (including 529 Overloaded)
    and transport failures with exponential backoff, honoring Retry-After.
    Never retries 401/422: those are caller bugs, and retrying them is just
    paying to be told no again.

    Oversized string state is truncated to MaxStateChars and the result is
    flagged StateTruncated so downstream routing can refuse to trust it.

.PARAMETER State
    String, hashtable, PSCustomObject, or array.  Structured state is sent as
    JSON; reference nested fields in questions with backticked paths.

.PARAMETER Questions
    Hashtable or PSCustomObject keyed by question id.

.OUTPUTS
    PSCustomObject with Model, Answers, Usage, StateTruncated, Attempts.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [object]$State,

        [Parameter(Mandatory)]
        [object]$Questions,

        [string]$Model = $(if ($env:TYPESAFE_DEFAULT_MODEL) { $env:TYPESAFE_DEFAULT_MODEL } else { $script:DefaultModel }),

        [string]$BaseUrl = $(if ($env:TYPESAFE_BASE_URL) { $env:TYPESAFE_BASE_URL } else { $script:DefaultBaseUrl }),

        [string]$ApiKey,

        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 5,

        [ValidateRange(1, 300)]
        [int]$TimeoutSec = 30,

        [ValidateRange(1000, 1000000)]
        [int]$MaxStateChars = $script:DefaultMaxStateChars
    )

    $problems = Test-JevQuestionSet -Questions $Questions
    if ($problems.Count -gt 0) {
        throw ("Invalid Jev questions:`n  " + ($problems -join "`n  "))
    }

    if ([string]::IsNullOrWhiteSpace($ApiKey)) { $ApiKey = Get-JevApiKey }

    $truncated = $false
    if ($State -is [string]) {
        if ([string]::IsNullOrWhiteSpace($State)) { throw 'State is empty; refusing to ask Jev about nothing.' }
        if ($State.Length -gt $MaxStateChars) {
            Write-Warning "State is $($State.Length) chars; truncating to $MaxStateChars (Jev state budget is ~32k tokens)."
            $State = $State.Substring(0, $MaxStateChars)
            $truncated = $true
        }
    }
    else {
        $stateJson = $State | ConvertTo-Json -Depth 20 -Compress
        if ($stateJson.Length -gt $MaxStateChars) {
            # Silently cutting JSON produces garbage; fail loudly instead.
            throw "Structured state is $($stateJson.Length) chars (limit $MaxStateChars).  Trim fields before calling Jev."
        }
    }

    $body = [ordered]@{
        state     = $State
        model     = $Model
        questions = $Questions
    } | ConvertTo-Json -Depth 30 -Compress

    $uri = '{0}/v1/systemone' -f $BaseUrl.TrimEnd('/')
    $headers = @{ Authorization = "Bearer $ApiKey" }
    $retryable = 408, 409, 425, 429, 500, 502, 503, 504, 529

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $statusCode = 0
        $responseHeaders = $null
        $transportError = $null
        $response = $null
        try {
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
                -TimeoutSec $TimeoutSec -SkipHttpErrorCheck -StatusCodeVariable statusCode `
                -ResponseHeadersVariable responseHeaders -ErrorAction Stop
        }
        catch {
            $transportError = $_.Exception.Message
        }

        if (-not $transportError -and $statusCode -ge 200 -and $statusCode -lt 300) {
            return [pscustomobject]@{
                Model          = $response.model
                Answers        = $response.answers
                Usage          = $response.usage
                StateTruncated = $truncated
                Attempts       = $attempt
            }
        }

        $detail = if ($transportError) { "transport: $transportError" }
                  else { "HTTP ${statusCode}: $(ConvertTo-JevErrorText -Response $response)" }

        $canRetry = $transportError -or ($statusCode -in $retryable)
        if (-not $canRetry -or $attempt -eq $MaxAttempts) {
            $hint = switch ($statusCode) {
                401 { '  Check TYPESAFE_API_KEY.' }
                422 { '  The request failed validation; fix the question/state shape.' }
                default { '' }
            }
            throw "Jev evaluation failed after $attempt attempt(s): $detail.$hint"
        }

        $delay = [math]::Min(30, [math]::Pow(2, $attempt - 1)) + (Get-Random -Minimum 0.0 -Maximum 0.5)
        $retryAfter = Get-JevRetryAfterSeconds -Headers $responseHeaders
        if ($retryAfter -gt 0) { $delay = [math]::Min(60, $retryAfter) }
        Write-Verbose ("Jev attempt {0}/{1} failed ({2}); retrying in {3:N1}s" -f $attempt, $MaxAttempts, $detail, $delay)
        Start-Sleep -Milliseconds ([int]($delay * 1000))
    }
}

function ConvertTo-JevAnswerSummary {
<#
.SYNOPSIS
    Flattens Jev answers into one compact object per question for humans/LLMs.

.DESCRIPTION
    choice -> value + confidence; score -> value + nearest level text +
    confidence; noul -> probability.  Probability maps are dropped: use the
    raw Answers when you need them.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Answers
    )

    process {
        $out = [ordered]@{}
        foreach ($entry in (ConvertTo-JevEntryList -InputObject $Answers)) {
            $a = $entry.Value
            $out[$entry.Key] = switch ($a.type) {
                'noul' { [pscustomobject]@{ type = 'noul'; value = [math]::Round([double]$a.noul, 3) } }
                'choice' {
                    [pscustomobject]@{ type = 'choice'; value = $a.choice; confidence = [math]::Round([double]$a.confidence, 3) }
                }
                'score' {
                    $nearest = [string][int][math]::Round([double]$a.score)
                    $label = Get-JevField -InputObject $a.legend -Name $nearest
                    [pscustomobject]@{
                        type = 'score'; value = [math]::Round([double]$a.score, 3)
                        level = $label; confidence = [math]::Round([double]$a.confidence, 3)
                    }
                }
                default { $a }
            }
        }
        [pscustomobject]$out
    }
}

#region private helpers

function ConvertTo-JevEntryList {
    param([object]$InputObject)
    $list = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $InputObject) { return , $list }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($k in $InputObject.Keys) { $list.Add([pscustomobject]@{ Key = [string]$k; Value = $InputObject[$k] }) }
    }
    elseif ($InputObject -is [pscustomobject]) {
        foreach ($p in $InputObject.PSObject.Properties) { $list.Add([pscustomobject]@{ Key = $p.Name; Value = $p.Value }) }
    }
    return , $list
}

function Get-JevField {
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-JevErrorText {
    param([object]$Response)
    if ($null -eq $Response) { return '(empty body)' }
    if ($Response -is [string]) { return $Response.Substring(0, [math]::Min(500, $Response.Length)) }
    $text = $Response | ConvertTo-Json -Depth 8 -Compress
    return $text.Substring(0, [math]::Min(500, $text.Length))
}

function Get-JevRetryAfterSeconds {
    param([object]$Headers)
    if ($null -eq $Headers) { return 0 }
    $raw = $null
    foreach ($k in $Headers.Keys) { if ($k -ieq 'Retry-After') { $raw = @($Headers[$k])[0] } }
    if (-not $raw) { return 0 }
    $seconds = 0.0
    if ([double]::TryParse($raw, [ref]$seconds)) { return $seconds }
    $when = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($raw, [ref]$when)) {
        return [math]::Max(0, ($when - [datetimeoffset]::UtcNow).TotalSeconds)
    }
    return 0
}

#endregion

Export-ModuleMember -Function Get-JevApiKey, Test-JevQuestionSet, Invoke-JevEvaluation, ConvertTo-JevAnswerSummary
