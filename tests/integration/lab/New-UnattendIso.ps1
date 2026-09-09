#requires -Version 7.0
<#
.SYNOPSIS
    Rebuild the answer-file ISO that Windows Setup reads from removable media.

.DESCRIPTION
    Windows Setup only looks for autounattend.xml on removable media, so the answer file
    has to be a real ISO. Built with the in-box IMAPI2 COM API rather than oscdimg, which
    would drag in the whole Windows ADK.

    Encodes one trap: the IStream returned by CreateResultImage cannot be copied with a
    naive buffer copy. It can be a few bytes LONGER than width*height*2 equivalents and
    overruns kill the CLR outright, so the copy is clamped.
#>
[CmdletBinding()]
param(
    [string]$SourceDirectory = (Join-Path $PSScriptRoot 'unattend'),
    [string]$Path            = 'C:\HyperV\ISO\unattend.iso',
    [string]$VolumeName      = 'UNATTEND'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class UnattendIsoWriter {
    public static void Write(object comStream, string path) {
        IStream stream = (IStream)comStream;
        using (FileStream fs = File.Create(path)) {
            byte[] buffer = new byte[1048576];
            IntPtr pcbRead = Marshal.AllocHGlobal(4);
            try {
                while (true) {
                    stream.Read(buffer, buffer.Length, pcbRead);
                    int read = Marshal.ReadInt32(pcbRead);
                    if (read <= 0) break;
                    fs.Write(buffer, 0, read);
                }
            } finally { Marshal.FreeHGlobal(pcbRead); }
        }
    }
}
"@ -ErrorAction SilentlyContinue

$xml = Join-Path $SourceDirectory 'autounattend.xml'
if (-not (Test-Path -LiteralPath $xml)) { throw "No autounattend.xml in $SourceDirectory." }

<# The tracked answer file is a template. The guest password is supplied at build time from
   BOOTUPD_LAB_PASSWORD and never committed: this repository is public, and a disposable
   credential in tracked content is still a credential in tracked content. #>
. (Join-Path $PSScriptRoot 'LabCredential.ps1')
$labPassword = Get-BootUpdLabPassword
if (-not $labPassword) {
    throw 'No lab guest password available. Store one with: . ./LabCredential.ps1; Set-BootUpdLabPassword -Generate'
}
$rendered = Join-Path ([IO.Path]::GetTempPath()) ('unattend-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $rendered -Force | Out-Null
try {
    <# The source must be the TEMPLATE, never a previous render. This guard exists because its
       absence cost a guest: the source directory had accumulated a rendered answer file, so the
       substitution below found nothing to replace and silently shipped an ISO carrying an OLDER
       password than the one just resolved. The ISO was internally consistent, matched the copy
       on disk, and matched nothing in the VM that had been installed from an earlier render. The
       only way back into that guest was to rebuild it. A missing placeholder is a build error,
       not a no-op. #>
    $template = Get-Content -LiteralPath $xml -Raw
    if ($template -notmatch '__LAB_PASSWORD__') {
        throw "$xml contains no __LAB_PASSWORD__ placeholder, so it is a rendered answer file rather than the template. Point -SourceDirectory at the tracked template."
    }
    $body = $template.Replace('__LAB_PASSWORD__', $labPassword)
    if ($body -match '__LAB_PASSWORD__') { throw 'Password placeholder was not substituted.' }
    Set-Content -LiteralPath (Join-Path $rendered 'autounattend.xml') -Value $body -Encoding UTF8
    $SourceDirectory = $rendered
    $xml = Join-Path $rendered 'autounattend.xml'


# Fail here rather than 20 minutes into an install that silently ignored a malformed file.
$parsed = [xml](Get-Content -LiteralPath $xml -Raw)
$passes = @($parsed.unattend.settings | ForEach-Object { $_.pass })
foreach ($required in 'windowsPE', 'specialize', 'oobeSystem') {
    if ($passes -notcontains $required) { throw "autounattend.xml is missing the '$required' pass." }
}
$oobe = $parsed.unattend.settings | Where-Object { $_.pass -eq 'oobeSystem' }
if (@($oobe.component | Where-Object { $_.name -eq 'Microsoft-Windows-International-Core' }).Count -eq 0) {
    throw 'oobeSystem has no International-Core component; OOBE will stall on the region screen.'
}

$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 3      # ISO9660 + Joliet
$fsi.VolumeName = $VolumeName
$fsi.Root.AddTree($SourceDirectory, $false)
[UnattendIsoWriter]::Write($fsi.CreateResultImage().ImageStream, $Path)

    [pscustomobject]@{
        Path   = $Path
        KB     = [math]::Round((Get-Item $Path).Length / 1KB, 1)
        Passes = $passes -join ', '
    }
} finally {
    # The rendered copy holds the real password; it must not outlive the build.
    Remove-Item -LiteralPath $rendered -Recurse -Force -ErrorAction SilentlyContinue
}
