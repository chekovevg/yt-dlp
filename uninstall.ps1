param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Programs\YouTubeTranscriptTool"),
    [switch]$RemoveSettings,
    [string]$SettingsDir = (Join-Path $env:APPDATA "YouTubeTranscriptTool")
)

$ErrorActionPreference = "Stop"

function Get-CanonicalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "A required uninstall path was empty."
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$First,

        [Parameter(Mandatory = $true)]
        [string]$Second
    )

    return [string]::Equals(
        (Get-CanonicalPath -Path $First).TrimEnd("\"),
        (Get-CanonicalPath -Path $Second).TrimEnd("\"),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-InstalledFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CanonicalInstallDir,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $segments = @($RelativePath -split "[\\/]")
    if ([System.IO.Path]::IsPathRooted($RelativePath) -or $segments -contains "..") {
        throw "Installation marker contains an unsafe file path: $RelativePath"
    }

    $installPrefix = $CanonicalInstallDir.TrimEnd("\") + "\"
    $filePath = Get-CanonicalPath -Path (Join-Path $CanonicalInstallDir $RelativePath)
    if (-not $filePath.StartsWith(
            $installPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Installation marker file escaped the installation directory: $RelativePath"
    }

    return $filePath
}

function Start-DeferredSelfCleanup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CanonicalInstallDir,

        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    $parentProcessId = $PID
    $encodedInstallDir = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($CanonicalInstallDir)
    )
    $encodedPaths = @(
        $Paths | ForEach-Object {
            "'" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) + "'"
        }
    ) -join ","

    $helperScript = @"
`$ErrorActionPreference = "SilentlyContinue"
Wait-Process -Id $parentProcessId -ErrorAction SilentlyContinue
`$installDir = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedInstallDir'))
`$paths = @($encodedPaths) | ForEach-Object {
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$_))
}
`$deadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    foreach (`$path in `$paths) {
        if ([IO.File]::Exists(`$path)) {
            try { [IO.File]::Delete(`$path) } catch { }
        }
    }
    if (-not (`$paths | Where-Object { [IO.File]::Exists(`$_) })) { break }
    Start-Sleep -Milliseconds 100
} while ([DateTime]::UtcNow -lt `$deadline)
if ([IO.Directory]::Exists(`$installDir) -and
    [IO.Directory]::GetFileSystemEntries(`$installDir).Length -eq 0) {
    try { [IO.Directory]::Delete(`$installDir, `$false) } catch { }
}
"@

    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($helperScript)
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = "-NoProfile -WindowStyle Hidden -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $process) {
        throw "Could not start deferred uninstall cleanup."
    }
    $process.Dispose()
}

$canonicalInstallDir = Get-CanonicalPath -Path $InstallDir
$installRoot = [System.IO.Path]::GetPathRoot($canonicalInstallDir)
$userProfile = [Environment]::GetFolderPath("UserProfile")
$localAppData = [Environment]::GetFolderPath("LocalApplicationData")
if ((Test-SamePath -First $canonicalInstallDir -Second $installRoot) -or
    (Test-SamePath -First $canonicalInstallDir -Second $userProfile) -or
    (Test-SamePath -First $canonicalInstallDir -Second $localAppData)) {
    throw "Refusing to uninstall from a broad directory: $canonicalInstallDir"
}

$markerPath = Join-Path $canonicalInstallDir ".install-manifest.json"
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw "Installation marker was not found: $markerPath"
}

$marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
if ($marker.SchemaVersion -ne 1) {
    throw "Unsupported installation marker schema."
}
if (-not (Test-SamePath -First ([string]$marker.InstallDir) -Second $canonicalInstallDir)) {
    throw "Installation marker does not match the requested directory."
}

$selfFiles = @("uninstall.cmd", "uninstall.ps1")
foreach ($relativePath in @($marker.Files)) {
    $relativePath = [string]$relativePath
    $installedPath = Get-InstalledFilePath `
        -CanonicalInstallDir $canonicalInstallDir `
        -RelativePath $relativePath

    if ($selfFiles -contains $relativePath) {
        continue
    }

    if (Test-Path -LiteralPath $installedPath -PathType Leaf) {
        Remove-Item -LiteralPath $installedPath -Force
    }
}

$shell = New-Object -ComObject WScript.Shell
$installPrefix = $canonicalInstallDir.TrimEnd("\") + "\"
foreach ($shortcutPathValue in @($marker.Shortcuts)) {
    $shortcutPath = Get-CanonicalPath -Path ([string]$shortcutPathValue)
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        continue
    }

    $shortcut = $shell.CreateShortcut($shortcutPath)
    $targetPath = Get-CanonicalPath -Path $shortcut.TargetPath
    if ($targetPath.StartsWith(
            $installPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
    else {
        Write-Warning "Preserved a shortcut whose target changed: $shortcutPath"
    }
}

Remove-Item -LiteralPath $markerPath -Force

$shortcutDirectories = @($marker.Shortcuts) |
    ForEach-Object { Split-Path -Parent ([string]$_) } |
    Sort-Object -Unique
foreach ($shortcutDirectory in $shortcutDirectories) {
    if ((Test-Path -LiteralPath $shortcutDirectory -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $shortcutDirectory -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $shortcutDirectory -Force
    }
}

if ($RemoveSettings) {
    $canonicalSettingsDir = Get-CanonicalPath -Path $SettingsDir
    $settingsParent = Split-Path -Parent $canonicalSettingsDir
    $settingsRoot = [System.IO.Path]::GetPathRoot($canonicalSettingsDir)
    if ((Split-Path -Leaf $canonicalSettingsDir) -ne "YouTubeTranscriptTool" -or
        (Test-SamePath -First $settingsParent -Second $settingsRoot)) {
        throw "Refusing to remove an unexpected settings directory: $canonicalSettingsDir"
    }

    if (Test-Path -LiteralPath $canonicalSettingsDir -PathType Container) {
        Remove-Item -LiteralPath $canonicalSettingsDir -Recurse -Force
    }
}

$selfCleanupPaths = @(
    (Join-Path $canonicalInstallDir "uninstall.cmd"),
    (Join-Path $canonicalInstallDir "uninstall.ps1")
)
Start-DeferredSelfCleanup `
    -CanonicalInstallDir $canonicalInstallDir `
    -Paths $selfCleanupPaths

Write-Host "YouTube Transcript Tool was removed for the current user."
if (-not $RemoveSettings) {
    Write-Host "User settings were preserved."
}
