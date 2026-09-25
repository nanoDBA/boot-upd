# ------------------------------------------------------------------------------
# File:        Install-JevKit.ps1
# Description: 📦 Installs/updates the jev-kit skills for every project on a box
# Purpose:     For machines that don't use the Claude Code plugin marketplace:
#              - Copies jev, jev-triage, jev-skill-router, jev-review-loop to a user-level
#                skills directory (default ~/.claude/skills) - replacing only
#                those four folders, never touching anything else
#              - Optionally mirrors them to other agents' skill dirs
#              - Optionally adds/removes the skill-router UserPromptSubmit hook
#                and the review-loop PreToolUse scope guard in
#                ~/.claude/settings.json, with a timestamped backup first
#              Re-run after `git pull` to update.  Idempotent.
# Created:     2026-09-24
# Modified:    2026-09-25
# ------------------------------------------------------------------------------

<#
.SYNOPSIS
    Installs or updates jev-kit skills at user level, optionally wiring the hook.

.EXAMPLE
    ./Install-JevKit.ps1 -WhatIf

.EXAMPLE
    ./Install-JevKit.ps1 -Destination ~/.claude/skills, ~/.agents/skills -EnableSkillRouterHook

.EXAMPLE
    ./Install-JevKit.ps1 -DisableSkillRouterHook
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Destination = @(Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude/skills'),

    [string]$SettingsPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude/settings.json'),

    [switch]$EnableSkillRouterHook,

    [switch]$DisableSkillRouterHook,

    # PreToolUse guard for jev-review-loop runs.  Inert unless a run is active.
    [switch]$EnableReviewScopeGuard,

    [switch]$DisableReviewScopeGuard,

    [ValidateRange(5, 60)]
    [int]$HookTimeoutSec = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($EnableSkillRouterHook -and $DisableSkillRouterHook) { throw 'Pick one of -EnableSkillRouterHook / -DisableSkillRouterHook.' }
if ($EnableReviewScopeGuard -and $DisableReviewScopeGuard) { throw 'Pick one of -EnableReviewScopeGuard / -DisableReviewScopeGuard.' }
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7+ required (the skills use pwsh-only features).' }

$sourceRoot = Join-Path $PSScriptRoot 'skills'
$skillNames = 'jev', 'jev-triage', 'jev-skill-router', 'jev-review-loop'
foreach ($name in $skillNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot "$name/SKILL.md"))) { throw "Source skill '$name' missing under $sourceRoot." }
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($dest in $Destination) {
    $destFull = [IO.Path]::GetFullPath($dest)
    foreach ($name in $skillNames) {
        $src = Join-Path $sourceRoot $name
        $dst = Join-Path $destFull $name
        $srcFull = [IO.Path]::GetFullPath($src).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ($srcFull -eq [IO.Path]::GetFullPath($dst).TrimEnd([IO.Path]::DirectorySeparatorChar)) {
            $results.Add([pscustomobject]@{ Action = 'skip'; Target = $dst; Detail = 'source and destination are the same' }); continue
        }
        $action = if (Test-Path -LiteralPath $dst) { 'update' } else { 'install' }
        if ($PSCmdlet.ShouldProcess($dst, "$action skill '$name'")) {
            New-Item -ItemType Directory -Path $destFull -Force | Out-Null
            # Stage then swap, so a failed copy never leaves a half-skill behind.
            $staging = Join-Path $destFull ".$name.staging-$PID"
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
            Copy-Item -LiteralPath $src -Destination $staging -Recurse -Force
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            Move-Item -LiteralPath $staging -Destination $dst -Force
        }
        $results.Add([pscustomobject]@{ Action = $action; Target = $dst; Detail = '' })
    }
}

$hookChanges = @(
    if ($EnableSkillRouterHook -or $DisableSkillRouterHook) {
        [pscustomobject]@{ Event = 'UserPromptSubmit'; Matcher = $null; Marker = 'Select-JevSkill.ps1'; Enable = [bool]$EnableSkillRouterHook
            Command = "pwsh -NoProfile -File `"$(Join-Path ([IO.Path]::GetFullPath($Destination[0])) 'jev/scripts/Select-JevSkill.ps1')`" -Hook"; Timeout = $HookTimeoutSec }
    }
    if ($EnableReviewScopeGuard -or $DisableReviewScopeGuard) {
        [pscustomobject]@{ Event = 'PreToolUse'; Matcher = 'Bash|Edit|Write|MultiEdit|NotebookEdit'; Marker = 'Test-ReviewScope.ps1'; Enable = [bool]$EnableReviewScopeGuard
            Command = "pwsh -NoProfile -File `"$(Join-Path ([IO.Path]::GetFullPath($Destination[0])) 'jev-review-loop/scripts/Test-ReviewScope.ps1')`""; Timeout = 10 }
    }
)

if ($hookChanges.Count -gt 0) {
    $settings = if (Test-Path -LiteralPath $SettingsPath) {
        $raw = Get-Content -LiteralPath $SettingsPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { [ordered]@{} } else { $raw | ConvertFrom-Json -AsHashtable -Depth 50 }
    } else { [ordered]@{} }
    if (-not $settings.Contains('hooks')) { $settings['hooks'] = [ordered]@{} }
    $hooks = $settings['hooks']
    $details = [System.Collections.Generic.List[string]]::new()

    foreach ($change in $hookChanges) {
        $groups = [System.Collections.Generic.List[object]]::new()
        if ($hooks.Contains($change.Event)) { foreach ($g in @($hooks[$change.Event])) { if ($null -ne $g) { $groups.Add($g) } } }
        # Drop existing entries for this marker (enable re-adds a fresh one; disable stops there).
        $removed = 0
        foreach ($g in @($groups)) {
            $kept = @(@($g['hooks']) | Where-Object { $null -ne $_ -and ([string]$_['command']) -notlike "*$($change.Marker)*" })
            $removed += @($g['hooks']).Count - $kept.Count
            if ($kept.Count -eq 0) { [void]$groups.Remove($g) } else { $g['hooks'] = $kept }
        }
        $details.Add("$($change.Event): removed $removed $($change.Marker) hook(s)")
        if ($change.Enable) {
            $group = [ordered]@{}
            if ($change.Matcher) { $group['matcher'] = $change.Matcher }
            $group['hooks'] = @([ordered]@{ type = 'command'; command = $change.Command; timeout = $change.Timeout })
            $groups.Add($group)
            $details.Add("$($change.Event): added $($change.Marker)")
        }
        if ($groups.Count -gt 0) { $hooks[$change.Event] = $groups.ToArray() } else { [void]$hooks.Remove($change.Event) }
    }
    if ($hooks.Count -eq 0) { [void]$settings.Remove('hooks') }

    $detail = $details -join '; '
    if ($PSCmdlet.ShouldProcess($SettingsPath, $detail)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $SettingsPath) -Force | Out-Null
        if (Test-Path -LiteralPath $SettingsPath) {
            $backup = '{0}.bak-{1:yyyyMMddHHmmss}' -f $SettingsPath, (Get-Date)
            Copy-Item -LiteralPath $SettingsPath -Destination $backup -Force
            $detail += "; backup $backup"
        }
        $tmp = "$SettingsPath.tmp-$PID"
        $settings | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $tmp -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $SettingsPath -Force
    }
    $results.Add([pscustomobject]@{ Action = 'settings'; Target = $SettingsPath; Detail = $detail })
    if ($EnableSkillRouterHook -and -not $env:TYPESAFE_API_KEY) {
        Write-Warning 'TYPESAFE_API_KEY is not set in this session.  The router hook stays silent (fails open) until it is set in the environment Claude Code starts from.'
    }
}

$results
