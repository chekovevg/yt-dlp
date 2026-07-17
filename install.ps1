param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Programs\YouTubeTranscriptTool"),
    [string]$DesktopDirectory = [Environment]::GetFolderPath("Desktop"),
    [string]$StartMenuDirectory = (Join-Path ([Environment]::GetFolderPath("Programs")) "YouTube Transcript Tool")
)

$ErrorActionPreference = "Stop"

function Get-CanonicalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "A required installation path was empty."
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

function Assert-SafeInstallDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$SourceRoot
    )

    $canonical = Get-CanonicalPath -Path $Path
    $root = [System.IO.Path]::GetPathRoot($canonical)
    $userProfile = [Environment]::GetFolderPath("UserProfile")
    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")

    if ((Test-SamePath -First $canonical -Second $root) -or
        (Test-SamePath -First $canonical -Second $userProfile) -or
        (Test-SamePath -First $canonical -Second $localAppData) -or
        (Test-SamePath -First $canonical -Second $SourceRoot)) {
        throw "Refusing to install into a broad or source directory: $canonical"
    }

    if (Test-Path -LiteralPath $canonical -PathType Leaf) {
        throw "The installation path points to a file: $canonical"
    }

    return $canonical
}

function Get-ApplicationFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot
    )

    $manifestPath = Join-Path $SourceRoot "app-files.txt"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Application file manifest was not found: $manifestPath"
    }

    $sourcePrefix = (Get-CanonicalPath -Path $SourceRoot).TrimEnd("\") + "\"
    $files = @(
        Get-Content -LiteralPath $manifestPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
    )

    if ($files.Count -eq 0) {
        throw "Application file manifest was empty: $manifestPath"
    }

    foreach ($relativePath in $files) {
        $segments = @($relativePath -split "[\\/]")
        if ([System.IO.Path]::IsPathRooted($relativePath) -or $segments -contains "..") {
            throw "Application file manifest contains an unsafe path: $relativePath"
        }

        $sourcePath = Get-CanonicalPath -Path (Join-Path $SourceRoot $relativePath)
        if (-not $sourcePath.StartsWith(
                $sourcePrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Application file escaped the source directory: $relativePath"
        }

        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required application file was not found: $sourcePath"
        }
    }

    return @($files)
}

function New-ApplicationShortcut {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Shell,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $shortcut = $Shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = $Description
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,70"
    $shortcut.Save()
}

$sourceRoot = Get-CanonicalPath -Path (Split-Path -Parent $PSCommandPath)
$canonicalInstallDir = Assert-SafeInstallDirectory -Path $InstallDir -SourceRoot $sourceRoot
$canonicalDesktopDir = Get-CanonicalPath -Path $DesktopDirectory
$canonicalStartMenuDir = Get-CanonicalPath -Path $StartMenuDirectory
$runtimeFiles = Get-ApplicationFiles -SourceRoot $sourceRoot

$installParent = Split-Path -Parent $canonicalInstallDir
$installLeaf = Split-Path -Leaf $canonicalInstallDir
if (-not (Test-Path -LiteralPath $installParent -PathType Container)) {
    New-Item -ItemType Directory -Path $installParent -Force | Out-Null
}

$stagingDir = Join-Path $installParent (
    ".{0}.install-{1}" -f $installLeaf, [Guid]::NewGuid().ToString("N")
)

try {
    New-Item -ItemType Directory -Path $stagingDir | Out-Null

    foreach ($relativePath in $runtimeFiles) {
        $sourcePath = Join-Path $sourceRoot $relativePath
        $stagedPath = Join-Path $stagingDir $relativePath
        $stagedParent = Split-Path -Parent $stagedPath
        if (-not (Test-Path -LiteralPath $stagedParent -PathType Container)) {
            New-Item -ItemType Directory -Path $stagedParent -Force | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $stagedPath -Force
    }

    if (-not (Test-Path -LiteralPath $canonicalInstallDir -PathType Container)) {
        New-Item -ItemType Directory -Path $canonicalInstallDir | Out-Null
    }

    foreach ($relativePath in $runtimeFiles) {
        $stagedPath = Join-Path $stagingDir $relativePath
        $installedPath = Join-Path $canonicalInstallDir $relativePath
        $installedParent = Split-Path -Parent $installedPath
        if (-not (Test-Path -LiteralPath $installedParent -PathType Container)) {
            New-Item -ItemType Directory -Path $installedParent -Force | Out-Null
        }

        Copy-Item -LiteralPath $stagedPath -Destination $installedPath -Force
    }

    foreach ($shortcutDirectory in @($canonicalDesktopDir, $canonicalStartMenuDir)) {
        if (-not (Test-Path -LiteralPath $shortcutDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $shortcutDirectory -Force | Out-Null
        }
    }

    $launcherPath = Join-Path $canonicalInstallDir "youtube-transcript-tool.cmd"
    $desktopShortcut = Join-Path $canonicalDesktopDir "YouTube Transcript Tool.lnk"
    $startMenuShortcut = Join-Path $canonicalStartMenuDir "YouTube Transcript Tool.lnk"
    $uninstallCommand = Join-Path $canonicalInstallDir "uninstall.cmd"
    $uninstallShortcut = Join-Path $canonicalStartMenuDir "Uninstall YouTube Transcript Tool.lnk"
    $shell = New-Object -ComObject WScript.Shell

    foreach ($shortcutPath in @($desktopShortcut, $startMenuShortcut)) {
        New-ApplicationShortcut `
            -Shell $shell `
            -Path $shortcutPath `
            -TargetPath $launcherPath `
            -WorkingDirectory $canonicalInstallDir `
            -Description "Save readable text transcripts from YouTube videos"
    }

    New-ApplicationShortcut `
        -Shell $shell `
        -Path $uninstallShortcut `
        -TargetPath $uninstallCommand `
        -WorkingDirectory $canonicalInstallDir `
        -Description "Remove YouTube Transcript Tool"

    $marker = [pscustomobject]@{
        SchemaVersion = 1
        InstallDir = $canonicalInstallDir
        Files = @($runtimeFiles)
        Shortcuts = @($desktopShortcut, $startMenuShortcut, $uninstallShortcut)
    }
    $markerPath = Join-Path $canonicalInstallDir ".install-manifest.json"
    $marker | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $markerPath -Encoding UTF8
}
finally {
    if (Test-Path -LiteralPath $stagingDir -PathType Container) {
        $resolvedStagingDir = Get-CanonicalPath -Path (Resolve-Path -LiteralPath $stagingDir).Path
        $stagingPrefix = (Get-CanonicalPath -Path $installParent).TrimEnd("\") + "\."
        if (-not $resolvedStagingDir.StartsWith(
                $stagingPrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Refusing to clean an unexpected installation staging path: $resolvedStagingDir"
        }

        Remove-Item -LiteralPath $resolvedStagingDir -Recurse -Force
    }
}

Write-Host "YouTube Transcript Tool was installed for the current user:"
Write-Host $canonicalInstallDir
Write-Host "Launch it from the desktop or Start Menu shortcut."
