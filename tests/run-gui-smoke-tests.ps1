$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$guiPath = Join-Path $root "transcript-tool-gui.ps1"
$uiTextPath = Join-Path $root "ui-text.ru.json"
$process = $null

if (-not (Test-Path -LiteralPath $uiTextPath -PathType Leaf)) {
    throw "Russian UI text resource is missing: $uiTextPath"
}

$uiText = Get-Content -LiteralPath $uiTextPath -Raw -Encoding UTF8 | ConvertFrom-Json

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

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

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr windowHandle);

    public static IntPtr FindTopLevelWindow(uint processId, string title)
    {
        IntPtr found = IntPtr.Zero;

        EnumWindows(delegate(IntPtr windowHandle, IntPtr parameter)
        {
            uint windowProcessId;
            GetWindowThreadProcessId(windowHandle, out windowProcessId);

            if (windowProcessId == processId && IsWindowVisible(windowHandle))
            {
                StringBuilder windowTitle = new StringBuilder(512);
                GetWindowText(windowHandle, windowTitle, windowTitle.Capacity);
                if (windowTitle.ToString() == title)
                {
                    found = windowHandle;
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
            "-WindowStyle",
            "Hidden",
            "-File",
            ('"{0}"' -f $guiPath)
        ) `
        -WorkingDirectory $root `
        -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $windowHandle = [IntPtr]::Zero

    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()

        if ($process.HasExited) {
            throw "GUI process exited before the main window appeared (exit code $($process.ExitCode))."
        }

        $windowHandle = [GuiSmokeWindowSearch]::FindTopLevelWindow(
            [uint32]$process.Id,
            [string]$uiText.WindowTitle
        )
        if ($windowHandle -ne [IntPtr]::Zero) {
            break
        }

        Start-Sleep -Milliseconds 100
    }

    if ($windowHandle -eq [IntPtr]::Zero) {
        throw "Visible GUI main window did not appear within ten seconds."
    }

    $process.Refresh()
    if (-not $process.Responding) {
        throw "GUI main window is not responding."
    }

    $window = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    if (-not $window) {
        throw "GUI main window was not exposed through UI Automation."
    }

    if ($window.Current.Name -ne $uiText.WindowTitle) {
        throw "GUI window title was not localized. Observed '$($window.Current.Name)'."
    }

    function Assert-UiElement {
        param(
            [Parameter(Mandatory = $true)]
            [System.Windows.Automation.AutomationElement]$RootElement,

            [Parameter(Mandatory = $true)]
            [string]$Name
        )

        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            $Name
        )
        $element = $RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            $condition
        )
        if (-not $element) {
            $available = @(
                $RootElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition
                ) | ForEach-Object {
                    "$($_.Current.ControlType.ProgrammaticName):$($_.Current.Name)"
                }
            ) -join "; "
            throw "GUI is missing visible automation element '$Name'. Available: $available"
        }
    }

    function Assert-UiElementMissing {
        param(
            [Parameter(Mandatory = $true)]
            [System.Windows.Automation.AutomationElement]$RootElement,

            [Parameter(Mandatory = $true)]
            [string]$Name
        )

        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            $Name
        )
        $element = $RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            $condition
        )
        if ($element) {
            throw "GUI still exposes removed automation element '$Name'."
        }
    }

    Assert-UiElement -RootElement $window -Name $uiText.AddVideo
    Assert-UiElement -RootElement $window -Name $uiText.SaveVideos
    Assert-UiElementMissing -RootElement $window -Name $uiText.OpenRoot
    Assert-UiElementMissing -RootElement $window -Name $uiText.CopyRootPath
    Assert-UiElement -RootElement $window -Name $uiText.ClearGlyph
    Assert-UiElement -RootElement $window -Name $uiText.NoProject

    Write-Host "PASS: GUI launches, responds, and exposes queue controls."
}
finally {
    if ($process) {
        $exactProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($exactProcess) {
            Stop-Process -Id $process.Id -Force
        }
    }
}
