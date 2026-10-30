#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$TestRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tests'),
    [ValidateRange(1, 3)][int]$MaxParallel = 3,
    [string]$ResultPath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$resolvedTestRoot = (Resolve-Path -LiteralPath $TestRoot).Path
$integrationRoot = Join-Path $resolvedTestRoot 'integration'
$testFiles = @(Get-ChildItem -LiteralPath $resolvedTestRoot -Filter '*.Tests.ps1' -File -Recurse |
    Where-Object { -not $_.FullName.StartsWith($integrationRoot, [StringComparison]::OrdinalIgnoreCase) } |
    Sort-Object FullName)
if (-not $testFiles.Count) { throw "No Pester test files found under '$resolvedTestRoot'." }

# Keep the known slow files separate, then place the remaining files by estimated cost.
# Estimates only balance work; every test file still runs on every invocation.
$knownSeconds = @{
    'RebootResilience.Tests.ps1' = 51.0
    'LauncherExperience.Tests.ps1' = 33.0
    'TuiExperience.Tests.ps1' = 31.0
}
$groups = [Collections.Generic.List[object]]::new()
$groupCount = [math]::Min($MaxParallel, 3)
foreach ($index in 1..$groupCount) {
    $groups.Add([pscustomobject]@{
        Name="unit-$index"
        Files=[Collections.Generic.List[string]]::new()
        EstimatedSeconds=0.0
    })
}
$weightedFiles = foreach ($file in $testFiles) {
    $estimate = if ($knownSeconds.ContainsKey($file.Name)) { $knownSeconds[$file.Name] } else { 2.0 }
    [pscustomobject]@{ Path=$file.FullName; Estimate=[double]$estimate }
}
foreach ($file in @($weightedFiles | Sort-Object -Property @{Expression='Estimate';Descending=$true}, @{Expression='Path';Descending=$false})) {
    $target = $groups | Sort-Object EstimatedSeconds | Select-Object -First 1
    $target.Files.Add($file.Path)
    $target.EstimatedSeconds += $file.Estimate
}
$groups = @($groups | Where-Object { $_.Files.Count -gt 0 })

$started = [Diagnostics.Stopwatch]::StartNew()
$jobs = foreach ($group in $groups) {
    Start-Job -Name $group.Name -ArgumentList $repoRoot, $group.Name, $group.Files.ToArray() -ScriptBlock {
        param([string]$Root, [string]$GroupName, [string[]]$Paths)
        $ErrorActionPreference = 'Stop'
        Set-Location -LiteralPath $Root
        Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = $Paths
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'None'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-Pester -Configuration $configuration
        $watch.Stop()
        if ($null -eq $result) {
            [pscustomobject]@{
                Group=$GroupName
                Seconds=[math]::Round($watch.Elapsed.TotalSeconds, 2)
                Result='Missing'
                Total=0
                Passed=0
                Failed=0
                Skipped=0
                FailedContainers=0
                FailedBlocks=0
                Failures=@()
                ContainerFailures=@()
                BlockFailures=@()
                WorkerErrors=@("Pester returned no result for worker '$GroupName'.")
            }
            return
        }

        function Get-FailureDetails {
            param([object[]]$Items,[string]$Kind)
            foreach ($item in $Items) {
                $message = $null
                foreach ($candidate in @(
                    $item.ErrorRecord.Exception.Message,
                    $item.Error.Exception.Message,
                    $item.Exception.Message,
                    $item.ErrorRecord.Message,
                    $item.Error.Message,
                    $item.Message
                )) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                        $message = (([string]$candidate -split "`n" | Select-Object -First 1).Trim())
                        break
                    }
                }
                if (-not $message) { $message = $item.ToString() }
                $path = if ($item.ExpandedPath) { $item.ExpandedPath } elseif ($item.Path) { $item.Path } else { $Kind }
                "${Kind}: ${path}: ${message}"
            }
        }

        $failures = @($result.Failed | ForEach-Object {
            $message = ($_.ErrorRecord.Exception.Message -split "`n" | Select-Object -First 1).Trim()
            "$($_.ExpandedPath): $message"
        })
        $containerFailures = @(Get-FailureDetails -Items @($result.FailedContainers) -Kind 'container failure')
        $blockFailures = @(Get-FailureDetails -Items @($result.FailedBlocks) -Kind 'block failure')
        $failedContainers = [int]$result.FailedContainersCount
        $failedBlocks = [int]$result.FailedBlocksCount
        $workerErrors = [Collections.Generic.List[string]]::new()
        if ([string]$result.Result -ine 'Passed') {
            $workerErrors.Add("Pester worker '$GroupName' result was '$($result.Result)', expected 'Passed'.")
        }
        if ($failedContainers -gt 0) {
            $workerErrors.Add("Pester worker '$GroupName' reported $failedContainers failed container(s).")
        }
        if ($failedBlocks -gt 0) {
            $workerErrors.Add("Pester worker '$GroupName' reported $failedBlocks failed block(s).")
        }
        [pscustomobject]@{
            Group=$GroupName
            Seconds=[math]::Round($watch.Elapsed.TotalSeconds, 2)
            Result=[string]$result.Result
            Total=$result.TotalCount
            Passed=$result.PassedCount
            Failed=$result.FailedCount
            Skipped=$result.SkippedCount
            FailedContainers=$failedContainers
            FailedBlocks=$failedBlocks
            Failures=$failures
            ContainerFailures=$containerFailures
            BlockFailures=$blockFailures
            WorkerErrors=$workerErrors.ToArray()
        }
    }
}

try {
    $null = $jobs | Wait-Job
    $results = @($jobs | Receive-Job -ErrorAction Continue | Where-Object { $_ -is [pscustomobject] })
    $groupErrors = @($jobs | Where-Object State -ne 'Completed' | ForEach-Object { "Job '$($_.Name)' ended $($_.State)." })
    foreach ($group in $groups) {
        if (@($results | Where-Object Group -eq $group.Name).Count -ne 1) {
            $groupErrors += "Worker '$($group.Name)' did not return exactly one Pester result."
        }
    }
} finally {
    foreach ($job in $jobs) {
        if ($job.State -notin 'Completed','Failed','Stopped') { Stop-Job -Job $job -ErrorAction SilentlyContinue }
    }
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
}
$started.Stop()

$results = @($results | Select-Object Group,Seconds,Result,Total,Passed,Failed,Skipped,FailedContainers,FailedBlocks,Failures,ContainerFailures,BlockFailures,WorkerErrors)
$total = [int](($results | Measure-Object Total -Sum).Sum)
$failed = [int](($results | Measure-Object Failed -Sum).Sum)
$passed = [int](($results | Measure-Object Passed -Sum).Sum)
$skipped = [int](($results | Measure-Object Skipped -Sum).Sum)
$expectedFiles = $testFiles.Count
$assignedFiles = ($groups | ForEach-Object Files | Measure-Object).Count
$report = [pscustomobject]@{
    GeneratedAtUtc=[datetime]::UtcNow.ToString('o')
    Commit=(git -C $repoRoot rev-parse HEAD)
    TotalSeconds=[math]::Round($started.Elapsed.TotalSeconds, 2)
    TestFiles=$expectedFiles
    Groups=@($results | Sort-Object Group)
    Total=$total
    Passed=$passed
    Failed=$failed
    Skipped=$skipped
    Errors=$groupErrors
}
$json = $report | ConvertTo-Json -Depth 5
if ($ResultPath) {
    $parent = Split-Path $ResultPath -Parent
    if ($parent) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $json | Set-Content -LiteralPath $ResultPath -Encoding utf8
}
Write-Output $json
if ($assignedFiles -ne $expectedFiles) { throw "Pester work split lost files: assigned $assignedFiles of $expectedFiles." }
if ($groupErrors.Count -or $total -eq 0 -or $failed -gt 0 -or @($results | Where-Object { $_.Result -ine 'Passed' -or $_.FailedContainers -gt 0 -or $_.FailedBlocks -gt 0 -or $_.WorkerErrors.Count -gt 0 }).Count -gt 0) {
    $details = @(
        $groupErrors
        $results | ForEach-Object { $_.Failures; $_.ContainerFailures; $_.BlockFailures; $_.WorkerErrors }
    ) | Where-Object { $_ } | Select-Object -Unique
    $details = $details -join "`n"
    throw "Parallel Pester gate failed: $failed of $total tests failed.$(if ($details) { "`n$details" })"
}
