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

Describe 'The guest log is copied to the host as it grows' {
    BeforeEach { $script:live = Join-Path $TestDrive ('live-' + [guid]::NewGuid().ToString('N') + '.log') }
    It 'appends only the new lines and returns the count for the next poll' {
        $known = Add-BootUpdLabLiveLog -Path $live -KnownCount 0 -GuestCount 2 -NewLines @('a','b')
        $known | Should -Be 2
        $known = Add-BootUpdLabLiveLog -Path $live -KnownCount $known -GuestCount 3 -NewLines @('c')
        $known | Should -Be 3
        @(Get-Content $live) | Should -Be @('a','b','c')
    }
    It 'writes nothing for a poll that saw no new lines' {
        $null = Add-BootUpdLabLiveLog -Path $live -KnownCount 0 -GuestCount 1 -NewLines @('a')
        $null = Add-BootUpdLabLiveLog -Path $live -KnownCount 1 -GuestCount 1 -NewLines @()
        @(Get-Content $live) | Should -Be @('a')
    }
    It 'marks a guest log that shrank instead of running two logs together' {
        $null = Add-BootUpdLabLiveLog -Path $live -KnownCount 0 -GuestCount 3 -NewLines @('old1','old2','old3')
        $known = Add-BootUpdLabLiveLog -Path $live -KnownCount 3 -GuestCount 1 -NewLines @('new1')
        $known | Should -Be 1
        $content = @(Get-Content $live)
        $content.Count | Should -Be 5
        $content[3] | Should -Match '^# \d{2}:\d{2}:\d{2} guest log shrank from 3 to 1 lines'
        $content[4] | Should -Be 'new1'
    }
}
