#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CommandLine,
    [Parameter(Mandatory)][string]$InputLine,
    [Parameter(Mandatory)][string]$TranscriptPath,
    [string]$WorkingDirectory = (Get-Location).Path,
    [ValidateRange(5,1800)][int]$TimeoutSeconds = 900,
    [ValidateRange(100,10000)][int]$InputDelayMilliseconds = 1500
)

$ErrorActionPreference = 'Stop'

if (-not ('BootUpdateCycle.ConsolePromptDriver' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace BootUpdateCycle {
    public static class ConsolePromptDriver {
        const uint CREATE_NEW_CONSOLE = 0x00000010;
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint OPEN_EXISTING = 3;
        const short KEY_EVENT = 0x0001;
        const uint WAIT_OBJECT_0 = 0;
        const uint WAIT_TIMEOUT = 258;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
        struct INPUT_RECORD {
            [FieldOffset(0)] public short EventType;
            [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct KEY_EVENT_RECORD {
            [MarshalAs(UnmanagedType.Bool)] public bool KeyDown;
            public ushort RepeatCount;
            public ushort VirtualKeyCode;
            public ushort VirtualScanCode;
            public char UnicodeChar;
            public uint ControlKeyState;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcessW(string applicationName, StringBuilder commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
            uint creationFlags, IntPtr environment, string currentDirectory,
            ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AttachConsole(uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool FreeConsole();

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFileW(string fileName, uint desiredAccess, uint shareMode,
            IntPtr securityAttributes, uint creationDisposition, uint flags, IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool WriteConsoleInputW(IntPtr consoleInput, INPUT_RECORD[] buffer,
            uint length, out uint written);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);

        public sealed class Child : IDisposable {
            public IntPtr ProcessHandle { get; private set; }
            public uint ProcessId { get; private set; }

            internal Child(IntPtr processHandle, uint processId) {
                ProcessHandle = processHandle;
                ProcessId = processId;
            }

            public int Wait(int timeoutMilliseconds) {
                uint wait = WaitForSingleObject(ProcessHandle, (uint)timeoutMilliseconds);
                if (wait == WAIT_TIMEOUT) throw new TimeoutException("Console child timed out.");
                if (wait != WAIT_OBJECT_0) throw new Win32Exception(Marshal.GetLastWin32Error());
                uint exitCode;
                if (!GetExitCodeProcess(ProcessHandle, out exitCode))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return unchecked((int)exitCode);
            }

            public void Dispose() {
                if (ProcessHandle != IntPtr.Zero) {
                    CloseHandle(ProcessHandle);
                    ProcessHandle = IntPtr.Zero;
                }
            }
        }

        public static Child Start(string commandLine, string currentDirectory) {
            var startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            PROCESS_INFORMATION process;
            if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero,
                false, CREATE_NEW_CONSOLE, IntPtr.Zero, currentDirectory, ref startup, out process))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            CloseHandle(process.hThread);
            return new Child(process.hProcess, process.dwProcessId);
        }

        static INPUT_RECORD Key(char value, bool down) {
            var record = new INPUT_RECORD();
            record.EventType = KEY_EVENT;
            record.KeyEvent.KeyDown = down;
            record.KeyEvent.RepeatCount = 1;
            record.KeyEvent.UnicodeChar = value;
            record.KeyEvent.VirtualKeyCode = value == '\r' ? (ushort)0x0D : (ushort)0;
            return record;
        }

        public static void SendLine(uint processId, string line) {
            FreeConsole();
            if (!AttachConsole(processId)) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr input = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (input == new IntPtr(-1)) {
                FreeConsole();
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try {
                var records = new List<INPUT_RECORD>();
                foreach (char value in line + "\r") {
                    records.Add(Key(value, true));
                    records.Add(Key(value, false));
                }
                uint written;
                if (!WriteConsoleInputW(input, records.ToArray(), (uint)records.Count, out written) ||
                    written != records.Count)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally {
                CloseHandle(input);
                FreeConsole();
            }
        }
    }
}
'@
}

$transcriptFullPath = [IO.Path]::GetFullPath($TranscriptPath)
$transcriptParent = Split-Path -Parent $transcriptFullPath
$null = New-Item -ItemType Directory -Path $transcriptParent -Force
Remove-Item -LiteralPath $transcriptFullPath -Force -ErrorAction SilentlyContinue

# cmd owns the new console. Its PowerShell child inherits console input while
# stdout/stderr go to the transcript artifact for deterministic CI assertions.
# A temporary batch avoids cmd.exe's fragile nested /c quoting while preserving
# the exact user-facing command as its own executable line.
$runnerPath = "$transcriptFullPath.runner.cmd"
$runnerLines = @(
    '@echo off'
    "$CommandLine 1> `"$transcriptFullPath`" 2>&1"
    'exit /b %ERRORLEVEL%'
)
[IO.File]::WriteAllLines($runnerPath,$runnerLines,[Text.Encoding]::ASCII)
$childCommand = 'cmd.exe /d /s /c ""{0}""' -f $runnerPath
$workingDirectoryFullPath = [IO.Path]::GetFullPath($WorkingDirectory)
$child = [BootUpdateCycle.ConsolePromptDriver]::Start($childCommand,$workingDirectoryFullPath)
try {
    Start-Sleep -Milliseconds $InputDelayMilliseconds
    [BootUpdateCycle.ConsolePromptDriver]::SendLine($child.ProcessId,$InputLine)
    $exitCode = $child.Wait($TimeoutSeconds * 1000)
} finally {
    $child.Dispose()
    Remove-Item -LiteralPath $runnerPath -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    ExitCode = $exitCode
    TranscriptPath = $transcriptFullPath
}
