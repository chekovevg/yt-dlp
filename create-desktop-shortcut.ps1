$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSCommandPath
$launcher = Join-Path $root "youtube-transcript-tool.cmd"

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher was not found: $launcher"
}

$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "YouTube Transcript Tool.lnk"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $launcher
$shortcut.WorkingDirectory = $root
$shortcut.Description = "Save readable text transcripts from YouTube videos"
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,70"
$shortcut.Save()

Write-Host "Created desktop shortcut:"
Write-Host $shortcutPath
