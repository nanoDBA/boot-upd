BeforeAll {
    $wrapper = Join-Path $PSScriptRoot '../tools/Invoke-Beads.ps1'
    $engine = (Get-Process -Id $PID).Path
}
Describe 'Beads client connection guard' {
    BeforeEach {
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $repo 'tools') -Force | Out-Null
        Copy-Item -LiteralPath $wrapper -Destination (Join-Path $repo 'tools/Invoke-Beads.ps1')
        git -C $repo init --quiet
    }
    It 'rejects a missing client setting before requesting credentials' {
        $result = & $engine -NoProfile -File (Join-Path $repo 'tools/Invoke-Beads.ps1') status 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $result | Should -Match 'beads.clientPath'
        $result | Should -Not -Match 'Missing repository-local beads.credentialTarget'
    }
    It 'rejects an unapproved executable before running it or requesting credentials' {
        git -C $repo config --local beads.clientPath $engine
        $result = & $engine -NoProfile -File (Join-Path $repo 'tools/Invoke-Beads.ps1') status 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $result | Should -Match 'Unapproved Beads client'
        $result | Should -Not -Match 'Missing repository-local beads.credentialTarget'
    }
}
