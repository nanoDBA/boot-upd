# ------------------------------------------------------------------------------
# File:        Get-ReviewGraph.ps1
# Description: 🕸️ Deterministic code impact graph for a change set (no models)
# Purpose:     Decides WHAT the review loop looks at, for free:
#              - Nodes: tracked files, plus PowerShell functions (AST)
#              - Edges: contains / calls / references (dependent -> dependency)
#              - Changed: diff base...HEAD + working tree; functions whose
#                span overlaps a hunk
#              - Impacted: reverse BFS from changed nodes to -Depth
#              - Order: dependencies first, so callee findings land before
#                callers are reviewed
#              Every token Jev or an LLM never sees is a token not paid for.
# Created:     2026-09-25
# Modified:    2026-09-25
# ------------------------------------------------------------------------------

<#
.SYNOPSIS
    Builds the impact graph of a change set and emits it as JSON.

.EXAMPLE
    ./Get-ReviewGraph.ps1 -Base origin/master -Depth 2 -OutputPath .review-loop/graph.json

.EXAMPLE
    # Impact of specific files only (e.g. the files a fix just touched):
    ./Get-ReviewGraph.ps1 -ChangedPath tools/Invoke-UpdLauncher.ps1 -Depth 1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,

    # Merge base is taken against this ref.  Ignored when -ChangedPath is used.
    [string]$Base,

    # Explicit changed files (repo-relative).  Skips git diff.
    [string[]]$ChangedPath,

    [ValidateRange(0, 6)]
    [int]$Depth = 2,

    [string]$OutputPath,

    # Files larger than this are graphed as opaque nodes (no reference scan).
    [ValidateRange(1024, 50MB)]
    [int]$MaxFileBytes = 2MB
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
function Invoke-Git { param([string[]]$GitArgs)
    $out = & git -C $RepoRoot @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $out" }
    return @($out | ForEach-Object { [string]$_ })
}

# --- inventory -----------------------------------------------------------------
$textExt = '.ps1', '.psm1', '.psd1', '.cmd', '.bat', '.md', '.json', '.jsonl', '.yml', '.yaml', '.txt', '.xml', '.ini', '.config', '.sh', '.py', '.js', '.ts', '.cs', '.sql'
$files = @(Invoke-Git @('ls-files', '-z') | ForEach-Object { $_ -split "`0" } | Where-Object { $_ })
$untracked = @(Invoke-Git @('ls-files', '--others', '--exclude-standard', '-z') | ForEach-Object { $_ -split "`0" } | Where-Object { $_ })
$files = @($files + $untracked | Select-Object -Unique | Sort-Object)

$nodes = [ordered]@{}
$edges = [System.Collections.Generic.HashSet[string]]::new()
function Add-Node { param([string]$Id, [string]$Kind, [string]$File, [int]$Start = 0, [int]$End = 0)
    if (-not $nodes.Contains($Id)) { $nodes[$Id] = [ordered]@{ id = $Id; kind = $Kind; file = $File; start = $Start; end = $End } }
}
function Add-Edge { param([string]$From, [string]$To, [string]$Kind)
    if ($From -ne $To) { [void]$edges.Add("$From`t$To`t$Kind") }
}

$byLeaf = @{}
foreach ($f in $files) {
    Add-Node -Id "file:$f" -Kind 'file' -File $f
    $leaf = [IO.Path]::GetFileName($f).ToLowerInvariant()
    if (-not $byLeaf.ContainsKey($leaf)) { $byLeaf[$leaf] = [System.Collections.Generic.List[string]]::new() }
    $byLeaf[$leaf].Add($f)
}

# --- PowerShell AST: functions and calls -------------------------------------
$functionIndex = @{}   # name -> list of fn node ids
$psFiles = @($files | Where-Object { $_ -match '\.(ps1|psm1)$' })
$asts = @{}
foreach ($f in $psFiles) {
    $full = Join-Path $RepoRoot $f
    if (-not (Test-Path -LiteralPath $full) -or (Get-Item -LiteralPath $full).Length -gt $MaxFileBytes) { continue }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
    $asts[$f] = $ast
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $id = "fn:$f#$($fn.Name)"
        Add-Node -Id $id -Kind 'function' -File $f -Start $fn.Extent.StartLineNumber -End $fn.Extent.EndLineNumber
        Add-Edge -From "file:$f" -To $id -Kind 'contains'
        $key = $fn.Name.ToLowerInvariant()
        if (-not $functionIndex.ContainsKey($key)) { $functionIndex[$key] = [System.Collections.Generic.List[string]]::new() }
        $functionIndex[$key].Add($id)
    }
}
foreach ($f in $asts.Keys) {
    foreach ($cmd in $asts[$f].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        if (-not $name -or -not $functionIndex.ContainsKey($name.ToLowerInvariant())) { continue }
        # Caller = innermost enclosing function, else the file itself.
        $caller = "file:$f"
        $p = $cmd.Parent
        while ($p) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $caller = "fn:$f#$($p.Name)"; break }
            $p = $p.Parent
        }
        $targets = $functionIndex[$name.ToLowerInvariant()]
        # Prefer a same-file definition; otherwise link every definition (ambiguity is safer than a missed edge).
        $local = @($targets | Where-Object { $_.StartsWith("fn:$f#") })
        foreach ($t in $(if ($local.Count) { $local } else { $targets })) { Add-Edge -From $caller -To $t -Kind 'calls' }
    }
}

# --- file references (any text file mentioning another tracked file) ---------
$refPattern = [regex]'(?i)[\w.\-]+\.(?:ps1|psm1|psd1|cmd|bat|json|jsonl|md|yml|yaml|sh|py|js|ts|cs|sql|xml|config)\b'
foreach ($f in $files) {
    if ([IO.Path]::GetExtension($f).ToLowerInvariant() -notin $textExt) { continue }
    $full = Join-Path $RepoRoot $f
    if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Get-Item -LiteralPath $full).Length -gt $MaxFileBytes) { continue }
    $text = [IO.File]::ReadAllText($full)
    foreach ($m in $refPattern.Matches($text)) {
        $leaf = $m.Value.ToLowerInvariant()
        if (-not $byLeaf.ContainsKey($leaf)) { continue }
        foreach ($target in $byLeaf[$leaf]) { Add-Edge -From "file:$f" -To "file:$target" -Kind 'references' }
    }
}

# --- changed set --------------------------------------------------------------
$changedFiles = [System.Collections.Generic.HashSet[string]]::new()
$hunks = @{}   # file -> list of @(start,end) on the new side
if ($ChangedPath) {
    foreach ($c in $ChangedPath) { [void]$changedFiles.Add((($c -replace '\\', '/') -replace '^\./', '')) }
}
else {
    if (-not $Base) {
        $Base = (Invoke-Git @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD') | Select-Object -First 1)
        if (-not $Base) { throw 'No -Base given and origin/HEAD is not set.  Pass -Base <ref>.' }
    }
    $mergeBase = (Invoke-Git @('merge-base', $Base, 'HEAD') | Select-Object -First 1).Trim()
    $diffText = @(Invoke-Git @('diff', '-U0', '--no-color', '--no-ext-diff', $mergeBase)) # base..worktree (committed + uncommitted)
    $current = $null
    foreach ($line in $diffText) {
        if ($line -match '^\+\+\+ b/(.+)$') { $current = $Matches[1]; [void]$changedFiles.Add($current); continue }
        if ($line -match '^\+\+\+ /dev/null') { $current = $null; continue }
        if ($line -match '^--- a/(.+)$') { [void]$changedFiles.Add($Matches[1]); continue }
        if ($current -and $line -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@') {
            $start = [int]$Matches[1]; $len = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
            if (-not $hunks.ContainsKey($current)) { $hunks[$current] = [System.Collections.Generic.List[object]]::new() }
            # Pure deletions (len 0) still touch the function around that line.
            $hunks[$current].Add(@($start, [math]::Max($start, $start + $len - 1)))
        }
    }
    foreach ($u in $untracked) { [void]$changedFiles.Add($u) }
}

$changed = [System.Collections.Generic.List[string]]::new()
foreach ($cf in $changedFiles) {
    $fileId = "file:$cf"
    if (-not $nodes.Contains($fileId)) { Add-Node -Id $fileId -Kind 'file' -File $cf }  # deleted file
    $changed.Add($fileId)
    $fnNodes = @($nodes.Values | Where-Object { $_.kind -eq 'function' -and $_.file -eq $cf })
    if ($hunks.ContainsKey($cf)) {
        foreach ($fn in $fnNodes) {
            foreach ($h in $hunks[$cf]) {
                if ($h[0] -le $fn.end -and $h[1] -ge $fn.start) { $changed.Add($fn.id); break }
            }
        }
    }
    elseif ($ChangedPath -or $cf -in $untracked) { foreach ($fn in $fnNodes) { $changed.Add($fn.id) } }
}

# --- impacted set: reverse BFS ------------------------------------------------
$reverse = @{}
foreach ($e in $edges) {
    $from, $to, $kind = $e -split "`t"
    if (-not $reverse.ContainsKey($to)) { $reverse[$to] = [System.Collections.Generic.List[string]]::new() }
    $reverse[$to].Add($from)
}
$depthOf = [ordered]@{}
$queue = [System.Collections.Generic.Queue[string]]::new()
foreach ($c in $changed) { if (-not $depthOf.Contains($c)) { $depthOf[$c] = 0; $queue.Enqueue($c) } }
while ($queue.Count -gt 0) {
    $n = $queue.Dequeue()
    if ($depthOf[$n] -ge $Depth -or -not $reverse.ContainsKey($n)) { continue }
    foreach ($dep in $reverse[$n]) {
        if (-not $depthOf.Contains($dep)) { $depthOf[$dep] = $depthOf[$n] + 1; $queue.Enqueue($dep) }
    }
}

# --- order: dependencies first (Kahn over the impacted subgraph) ---------------
$inSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($depthOf.Keys))
$pending = @{}; $dependents = @{}
foreach ($id in $inSet) { $pending[$id] = 0; $dependents[$id] = [System.Collections.Generic.List[string]]::new() }
foreach ($e in $edges) {
    $from, $to, $kind = $e -split "`t"
    if ($inSet.Contains($from) -and $inSet.Contains($to)) { $pending[$from]++; $dependents[$to].Add($from) }
}
$ready = [System.Collections.Generic.SortedSet[string]]::new([string[]]@($pending.Keys | Where-Object { $pending[$_] -eq 0 }))
$order = [System.Collections.Generic.List[string]]::new()
$cycleBreaks = [System.Collections.Generic.List[string]]::new()
while ($order.Count -lt $inSet.Count) {
    if ($ready.Count -eq 0) {
        # Cycle: release the lexically first remaining node and record it.
        $next = @($pending.Keys | Where-Object { $pending[$_] -ge 0 -and -not $order.Contains($_) } | Sort-Object | Select-Object -First 1)[0]
        $cycleBreaks.Add($next); [void]$ready.Add($next)
    }
    $n = $ready.Min; [void]$ready.Remove($n)
    if ($order.Contains($n)) { continue }
    $order.Add($n); $pending[$n] = -1
    foreach ($d in $dependents[$n]) {
        if ($pending[$d] -gt 0) { $pending[$d]-- }
        if ($pending[$d] -eq 0) { [void]$ready.Add($d) }
    }
}

$edgeList = foreach ($e in $edges) { $from, $to, $kind = $e -split "`t"; [ordered]@{ from = $from; to = $to; kind = $kind } }
$result = [ordered]@{
    repoRoot    = $RepoRoot
    base        = $Base
    depth       = $Depth
    counts      = [ordered]@{ nodes = $nodes.Count; edges = $edges.Count; changed = $changed.Count; impacted = $depthOf.Count }
    changed     = @($changed | Select-Object -Unique)
    impacted    = @($order | ForEach-Object { [ordered]@{ id = $_; depth = $depthOf[$_]; kind = $nodes[$_].kind; file = $nodes[$_].file; start = $nodes[$_].start; end = $nodes[$_].end } })
    cycleBreaks = @($cycleBreaks)
    edges       = @($edgeList | Where-Object { $inSet.Contains($_.from) -and $inSet.Contains($_.to) })
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8
    [pscustomobject]$result.counts | ConvertTo-Json -Compress
}
else { $json }
