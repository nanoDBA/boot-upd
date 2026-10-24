BeforeAll { . (Join-Path $PSScriptRoot 'integration/lab/LabEvidence.ps1') }
Describe 'Scheduler evidence uses Windows XML fields' {
    It 'reads the single-quoted format returned by Windows' {
        $xml="<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><EventID>100</EventID><TimeCreated SystemTime='2026-10-24T18:34:41Z'/></System><EventData><Data Name='TaskName'>\BootUpdateCycle</Data><Data Name='UserContext'>LAB\test</Data></EventData></Event>"
        $event=ConvertFrom-BootUpdLabTaskEvent $xml
        $event.Id | Should -Be 100
        $event.TaskName | Should -Be '\BootUpdateCycle'
        $event.UserContext | Should -Be 'LAB\test'
        $event.TimeCreatedUtc.ToUniversalTime().ToString('o') | Should -Be '2026-10-24T18:34:41.0000000Z'
    }
    It 'also reads double quotes and keeps the unrelated task name available for filtering' {
        $xml='<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><EventID>140</EventID><TimeCreated SystemTime="2026-10-24T18:34:41Z"/></System><EventData><Data Name="TaskName">\Unrelated</Data></EventData></Event>'
        $event=ConvertFrom-BootUpdLabTaskEvent $xml
        $event.TaskName | Should -Be '\Unrelated'
        $event.UserContext | Should -Be ''
    }
    It 'fails on malformed XML rather than returning no task events' {
        { ConvertFrom-BootUpdLabTaskEvent '<Event>' } | Should -Throw
    }
}

Describe 'A verified sign-in does not hide outstanding provider work' {
    It 'reports a fully verified and cleaned cycle as PASS' {
        Get-BootUpdLabContinuationResult -Verified $true -CleanupVerified $true -CompletionLine 'BOOT UPDATE CYCLE COMPLETE | 1 reboot(s)' | Should -Be 'PASS'
    }
    It 'keeps machine inventory PARTIAL even when the user continuation worked' {
        Get-BootUpdLabContinuationResult -Verified $true -CleanupVerified $true -CompletionLine 'BOOT UPDATE CYCLE COMPLETE WITH CLEANUP ADVISORY AND DEFERRED INVENTORY | 1 reboot(s)' | Should -Be 'PARTIAL'
    }
    It 'keeps skipped and quarantined packages PARTIAL' {
        Get-BootUpdLabContinuationResult -Verified $true -CleanupVerified $true -CompletionLine 'BOOT UPDATE CYCLE COMPLETE WITH WINGET QUARANTINE | 1 reboot(s)' | Should -Be 'PARTIAL'
    }
    It 'fails when temporary autologon cleanup was not verified' {
        Get-BootUpdLabContinuationResult -Verified $true -CleanupVerified $false -CompletionLine 'BOOT UPDATE CYCLE COMPLETE' | Should -Be 'FAIL'
    }
    It 'fails without a completion record even if the caller claims verification' {
        Get-BootUpdLabContinuationResult -Verified $true -CleanupVerified $true -CompletionLine '' | Should -Be 'FAIL'
    }
}
