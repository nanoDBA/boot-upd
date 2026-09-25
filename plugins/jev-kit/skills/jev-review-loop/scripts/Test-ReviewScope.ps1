# ------------------------------------------------------------------------------
# File:        Test-ReviewScope.ps1
# Description: 🛡️ PreToolUse guard: keeps an unattended review run in its lane
# Purpose:     Unattended means nobody is there to say no, so the envelope is
#              enforced by the harness, not by the model's good intentions:
#              - Only active while <project>/.review-loop/ACTIVE exists;
#                otherwise it exits 0 silently and costs one pwsh start
#              - Bash: denies profile patterns (live-system effects, history
#                rewrites, --no-verify) and any push that is not a plain push
#                of the review branch
#              - Edit/Write: denies paths outside the project, protected paths
#                (settings, hooks, CI, the profile itself), and - with
#                writeScope 'impacted' - files outside the impact graph
#              FAILS CLOSED while active: a broken profile denies the call.
# Created:     2026-09-25
# Modified:    2026-09-25
# ------------------------------------------------------------------------------

<#
.SYNOPSIS
    Claude Code PreToolUse hook enforcing the review-loop autonomy envelope.

.EXAMPLE
    # settings.json (the jev-review-loop skill's installer adds this):
    # "PreToolUse": [{ "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
    #   "hooks": [{ "type": "command", "command": "pwsh -NoProfile -File \"<dir>/Test-ReviewScope.ps1\"", "timeout": 10 }] }]

.EXAMPLE
    '{"tool_name":"Bash","tool_input":{"command":"git push -f origin main"},"cwd":"."}' | ./Test-ReviewScope.ps1
#>
[CmdletBinding()]
param(
    # For tests: evaluate this JSON instead of reading stdin.
    [string]$InputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Deny { param([string]$Reason)
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = "review-loop scope guard: $Reason" } } |
        ConvertTo-Json -Compress
    exit 0
}

try { $raw = if ($InputJson) { $InputJson } else { [Console]::In.ReadToEnd() } } catch { exit 0 }
try { $payload = $raw | ConvertFrom-Json -Depth 20 } catch { exit 0 }  # not our business to parse junk when inactive

$project = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
           elseif ($payload.PSObject.Properties['cwd'] -and $payload.cwd) { [string]$payload.cwd }
           else { (Get-Location).Path }
$marker = Join-Path $project '.review-loop/ACTIVE'
if (-not (Test-Path -LiteralPath $marker)) { exit 0 }

# ---- active: from here on, any failure denies -----------------------------------------
try {
    $projectFull = [IO.Path]::GetFullPath($project).TrimEnd('/', '\')
    $profilePath = Join-Path $projectFull '.claude/review-scope.json'
    if (-not (Test-Path -LiteralPath $profilePath)) { $profilePath = Join-Path $PSScriptRoot '../scope.default.json' }
    $scope = (Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json -AsHashtable -Depth 20).scope
    if (-not $scope) { throw "profile '$profilePath' has no 'scope' section" }

    $tool = [string]$payload.tool_name
    $toolInput = $payload.tool_input

    if ($tool -eq 'Bash') {
        $cmd = [string]$toolInput.command
        foreach ($rule in @($scope.denyCommands)) {
            if ($cmd -match $rule.pattern) { Write-Deny "$($rule.reason) (matched /$($rule.pattern)/)" }
        }
        # Every git push segment must be a plain push of an allowed branch.
        foreach ($segment in ($cmd -split '&&|\|\||;|\|')) {
            if ($segment -notmatch '(?i)\bgit\b(\s+-\S+(\s+\S+)?)*\s+push\b') { continue }
            if ($segment -match '(?i)(\s--force\b|\s--force-with-lease\b|\s-[a-z]*f[a-z]*\b|\s\+\S|--mirror|--all\b|--tags\b|--delete\b|\s-d\b|:\S)') {
                Write-Deny 'force, delete, mirror, tag, or refspec pushes are out of scope'
            }
            $args_ = @(($segment -replace '(?i)^.*?\bpush\b', '').Trim() -split '\s+' | Where-Object { $_ -and -not $_.StartsWith('-') })
            if ($args_.Count -lt 2) { Write-Deny 'push must name the remote and the review branch explicitly' }
            $branch = $args_[1]
            if ($branch -notmatch [string]$scope.allowPushBranch) { Write-Deny "push target '$branch' is not a review branch (allowed: /$($scope.allowPushBranch)/)" }
        }
        exit 0
    }

    if ($tool -in 'Edit', 'Write', 'MultiEdit', 'NotebookEdit') {
        $path = if ($toolInput.PSObject.Properties['file_path']) { [string]$toolInput.file_path } else { [string]$toolInput.notebook_path }
        if (-not $path) { Write-Deny 'edit without a path' }
        $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $projectFull $path }))
        $sep = [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($projectFull + $sep, [StringComparison]::OrdinalIgnoreCase)) { Write-Deny "'$path' is outside the project" }
        $rel = $full.Substring($projectFull.Length + 1) -replace '\\', '/'
        if ($rel -like '.review-loop/*') { exit 0 }   # the loop's own ledger and artifacts
        foreach ($p in @($scope.denyWritePaths)) { if ($rel -like $p) { Write-Deny "'$rel' is a protected path ($p)" } }
        if ($scope.writeScope -eq 'impacted') {
            $graphPath = Join-Path $projectFull '.review-loop/graph.json'
            if (-not (Test-Path -LiteralPath $graphPath)) { Write-Deny 'writeScope is impacted but no .review-loop/graph.json exists yet' }
            $graph = Get-Content -LiteralPath $graphPath -Raw | ConvertFrom-Json -Depth 20
            $allowed = @($graph.impacted | ForEach-Object { $_.file } | Select-Object -Unique)
            $isTest = @($scope.testPaths | Where-Object { $rel -like $_ }).Count -gt 0
            if ($rel -notin $allowed -and -not $isTest) { Write-Deny "'$rel' is not in the impacted subgraph; record an escalation instead" }
        }
        exit 0
    }
    exit 0
}
catch {
    Write-Deny "guard error while a run is active (failing closed): $($_.Exception.Message)"
}
