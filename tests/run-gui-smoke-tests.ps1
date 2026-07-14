$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$guiPath = Join-Path $root "transcript-tool-gui.ps1"
$process = $null

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class GuiSmokeWindowSearch
{
    private delegate bool EnumWindowsCallback(IntPtr windowHandle, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr windowHandle, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr windowHandle, StringBuilder text, int count);

    public static bool HasTopLevelWindow(uint processId, string title)
    {
        bool found = false;

        EnumWindows(delegate(IntPtr windowHandle, IntPtr parameter)
        {
            uint windowProcessId;
            GetWindowThreadProcessId(windowHandle, out windowProcessId);

            if (windowProcessId == processId)
            {
                StringBuilder windowTitle = new StringBuilder(512);
                GetWindowText(windowHandle, windowTitle, windowTitle.Capacity);

                if (windowTitle.ToString() == title)
                {
                    found = true;
                    return false;
                }
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }
}
'@

try {
    $process = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            ('"{0}"' -f $guiPath)
        ) `
        -WorkingDirectory $root `
        -WindowStyle Hidden `
        -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $windowFound = $false

    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()

        if ($process.HasExited) {
            throw "GUI process exited before the main window appeared (exit code $($process.ExitCode))."
        }

        if ([GuiSmokeWindowSearch]::HasTopLevelWindow(
                [uint32]$process.Id,
                "YouTube Transcript Tool")) {
            $windowFound = $true
            break
        }

        Start-Sleep -Milliseconds 100
    }

    if (-not $windowFound) {
        throw "GUI main window did not appear within five seconds."
    }

    $process.Refresh()
    if (-not $process.Responding) {
        throw "GUI main window is not responding."
    }

    Write-Host "PASS: GUI launches and responds."
}
finally {
    if ($process) {
        $exactProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($exactProcess) {
            Stop-Process -Id $process.Id -Force
        }
    }
}
