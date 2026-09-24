# ------------------------------------------------------------------------------
# File:        Select-JevSkill.ps1
# Description: 🧭 Picks at most one installed Claude skill for a prompt via Jev
# Purpose:     Port of TypeSafe's two-request skill-suggestion recipe:
#              1. Rank every installed skill + three "does this need a skill"
#                 gate nouls in one call.
#              2. Re-read the top 3 with full descriptions and body excerpts;
#                 each gets an absolute "does it fit" noul.  Nothing fits =
#                 nothing suggested.
#              As a UserPromptSubmit hook it FAILS OPEN: any error, timeout,
#              or missing key yields no output and exit 0.  A broken router
#              must never block a prompt.
# Created:     2026-09-24
# Modified:    2026-09-24
# ------------------------------------------------------------------------------

<#
.SYNOPSIS
    Suggests the single most relevant installed skill for a request, or none.

.EXAMPLE
    ./Select-JevSkill.ps1 -Prompt 'triage last night''s SQL errorlog' -Explain

.EXAMPLE
    # settings.json hook (opt-in; see the jev-skill-router skill):
    # pwsh -NoProfile -File <dir>/Select-JevSkill.ps1 -Hook
#>
[CmdletBinding(DefaultParameterSetName = 'Prompt')]
param(
    [Parameter(ParameterSetName = 'Prompt', Mandatory, Position = 0)]
    [string]$Prompt,

    # Read Claude Code UserPromptSubmit JSON from stdin; emit additionalContext.
    [Parameter(ParameterSetName = 'Hook', Mandatory)]
    [switch]$Hook,

    # Directories scanned recursively for */SKILL.md.  Defaults cover user,
    # project, and installed-plugin skills.
    [string[]]$SkillRoot,

    [ValidateRange(0.0, 1.0)]
    [double]$GateThreshold = 0.30,

    [ValidateRange(0.0, 1.0)]
    [double]$FitsThreshold = 0.30,

    [ValidateRange(2, 10)]
    [int]$Shortlist = 3,

    [ValidateRange(100, 4000)]
    [int]$ExcerptChars = 600,

    # By default user-invocable-only skills (disable-model-invocation: true)
    # ARE ranked: that is the point.  They stay out of Claude's context until
    # this router surfaces one.  Set this to rank model-invocable skills only.
    [switch]$ExcludeUserInvocableOnly,

    # Emit the full decision (gate, shortlist, fits, path) as JSON.
    [switch]$Explain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SkillCatalog {
    param([string[]]$Roots)
    $seen = @{}
    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter SKILL.md -File -Recurse -Depth 6 -ErrorAction SilentlyContinue) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $text -or $text -notmatch '(?s)\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z') { continue }
            $front = $Matches[1]; $body = $Matches[2]
            $userOnly = $front -match '(?m)^disable-model-invocation:\s*true\s*$'
            if ($userOnly -and $ExcludeUserInvocableOnly) { continue }
            $name = if ($front -match '(?m)^name:\s*["'']?([^"''\r\n]+)') { $Matches[1].Trim() } else { $file.Directory.Name }
            $desc = if ($front -match '(?ms)^description:\s*[>|]?-?\s*\r?\n((?:[ \t]+[^\r\n]*\r?\n?)+)') {
                ($Matches[1] -split '\r?\n' | ForEach-Object Trim) -join ' '
            } elseif ($front -match '(?m)^description:\s*["'']?(.+?)["'']?\s*$') { $Matches[1] } else { '' }
            if (-not $desc -or $seen.ContainsKey($name)) { continue }
            $seen[$name] = [pscustomobject]@{ Name = $name; Description = $desc.Trim(); Body = $body.Trim(); Path = $file.FullName }
        }
    }
    return @($seen.Values | Sort-Object Name)
}

function Select-Skill {
    param([string]$Request, [object[]]$Catalog)

    $gateQuestions = [ordered]@{
        acts_on_user_system = "Is the assistant being asked to act on the user's files, accounts, devices, or online services, rather than only to explain or advise?"
        would_follow_documented_procedure = 'Would a careful expert answering this consult a specific documented procedure or set of commands, rather than answering from general understanding?'
        prose_suffices = "Could a knowledgeable generalist fully satisfy this request in prose, with no tools, no documentation, and no access to the user's files or accounts?"
    }
    $state = [ordered]@{ request = $Request; recent_context = '' }

    # Choice is capped at 255 options; keep a reserve for safety.
    $roster = @($Catalog | Select-Object -First 250)
    if ($Catalog.Count -gt $roster.Count) { Write-Verbose "Only the first $($roster.Count) of $($Catalog.Count) skills are ranked." }

    $criteria = [ordered]@{}
    foreach ($s in $roster) { $criteria[$s.Name] = $s.Description.Substring(0, [math]::Min(400, $s.Description.Length)) }
    $questions = [ordered]@{
        which = @{ type = 'choice'; instructions = "Which of these skills, if any, is the right one to load to help with the user's latest request?"; criteria = $criteria }
    }
    foreach ($k in $gateQuestions.Keys) { $questions["gate::$k"] = @{ type = 'noul'; instructions = $gateQuestions[$k] } }

    $wide = Invoke-JevEvaluation -State $state -Questions $questions -TimeoutSec 8 -MaxAttempts 2
    $gateValues = foreach ($k in $gateQuestions.Keys) {
        $v = [double]$wide.Answers."gate::$k".noul
        if ($k -eq 'prose_suffices') { 1.0 - $v } else { $v }
    }
    $gate = ($gateValues | Measure-Object -Average).Average
    $ranked = @($wide.Answers.which.probabilities.PSObject.Properties | Sort-Object { [double]$_.Value } -Descending)
    $result = [ordered]@{ skill = $null; gate = [math]::Round($gate, 3); ranked = @($ranked | Select-Object -First $Shortlist | ForEach-Object { '{0}={1:N3}' -f $_.Name, [double]$_.Value }); fits = $null }
    if ($gate -lt $GateThreshold) { return [pscustomobject]$result }

    $byName = @{}; foreach ($s in $roster) { $byName[$s.Name] = $s }
    $names = @($ranked | Select-Object -First $Shortlist | ForEach-Object Name)
    $rerankCriteria = [ordered]@{}
    $rerank = [ordered]@{}
    foreach ($n in $names) {
        $s = $byName[$n]
        $rerankCriteria[$n] = '{0} - {1}' -f $s.Description, $s.Body.Substring(0, [math]::Min($ExcerptChars, $s.Body.Length))
        $rerank["fits::$n"] = @{ type = 'noul'; instructions = "Does the skill '$n' do the specific thing the user's request asks for? It is described as: $($s.Description)" }
    }
    $rerank['which'] = @{ type = 'choice'; instructions = "Exactly one of these skills is the right one to load for the user's latest request. Which one? Read what each actually does, not just its name."; criteria = $rerankCriteria }

    $second = Invoke-JevEvaluation -State $state -Questions $rerank -TimeoutSec 8 -MaxAttempts 2
    $fits = [ordered]@{}; foreach ($n in $names) { $fits[$n] = [math]::Round([double]$second.Answers."fits::$n".noul, 3) }
    $result.fits = [pscustomobject]$fits
    $best = ($fits.Values | Measure-Object -Maximum).Maximum
    if ($best -ge $FitsThreshold) { $result.skill = $second.Answers.which.choice }
    return [pscustomobject]$result
}

$home_ = [Environment]::GetFolderPath('UserProfile')
# pwsh -File passes "a,b" as one string; accept both forms.
$SkillRoot = @($SkillRoot | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($SkillRoot.Count -eq 0) {
    $SkillRoot = @(
        (Join-Path $home_ '.claude/skills'),
        (Join-Path $home_ '.claude/plugins'),
        $(if ($env:CLAUDE_PROJECT_DIR) { Join-Path $env:CLAUDE_PROJECT_DIR '.claude/skills' } else { Join-Path (Get-Location) '.claude/skills' })
    )
}

if ($Hook) {
    # Fail open, always.  Everything below is best-effort.
    try {
        $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
        $request = [string]$payload.prompt
        # Explicit slash commands and trivial prompts already know what they want.
        if ([string]::IsNullOrWhiteSpace($request) -or $request.TrimStart().StartsWith('/') -or $request.Length -lt 12) { exit 0 }
        if ([string]::IsNullOrWhiteSpace($env:TYPESAFE_API_KEY)) { exit 0 }
        if ($payload.PSObject.Properties['cwd'] -and $payload.cwd) {
            $SkillRoot += (Join-Path $payload.cwd '.claude/skills')
        }
        Import-Module (Join-Path $PSScriptRoot 'JevClient.psm1') -Force -Verbose:$false
        $catalog = @(Get-SkillCatalog -Roots $SkillRoot)
        if ($catalog.Count -lt 2) { exit 0 }
        $pick = Select-Skill -Request $request -Catalog $catalog
        if ($pick.skill) {
            $path = ($catalog | Where-Object Name -eq $pick.skill | Select-Object -First 1).Path
            $context = "<skill_relevance>`nRelevant to the current request: $($pick.skill) ($path). If it fits, read that SKILL.md and follow it; ignore this if it does not fit what the user actually asked for.`n</skill_relevance>"
            @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $context } } | ConvertTo-Json -Compress
        }
    }
    catch { }
    exit 0
}

Import-Module (Join-Path $PSScriptRoot 'JevClient.psm1') -Force -Verbose:$false
$catalog = @(Get-SkillCatalog -Roots $SkillRoot)
if ($catalog.Count -eq 0) { throw "No model-invocable skills found under: $($SkillRoot -join ', ')" }
Write-Verbose "Catalog: $($catalog.Count) skills"
$pick = Select-Skill -Request $Prompt -Catalog $catalog
if ($Explain) {
    $pick | Add-Member -NotePropertyName path -NotePropertyValue ($catalog | Where-Object Name -eq $pick.skill | Select-Object -First 1 -ExpandProperty Path)
    $pick | ConvertTo-Json -Depth 5
} else { $pick.skill }
