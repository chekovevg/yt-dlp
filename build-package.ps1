param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "dist\youtube-transcript-tool-windows.zip")
)

$ErrorActionPreference = "Stop"

function Get-CanonicalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "The package output path was empty."
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-PackageFiles {
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

$sourceRoot = Get-CanonicalPath -Path $PSScriptRoot
$canonicalOutputPath = Get-CanonicalPath -Path $OutputPath
if ([System.IO.Path]::GetExtension($canonicalOutputPath) -ne ".zip") {
    throw "Package output must use the .zip extension: $canonicalOutputPath"
}
if (Test-Path -LiteralPath $canonicalOutputPath -PathType Container) {
    throw "Package output path points to a directory: $canonicalOutputPath"
}

$packageFiles = Get-PackageFiles -SourceRoot $sourceRoot
$outputParent = Split-Path -Parent $canonicalOutputPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$temporaryRoot = Get-CanonicalPath -Path ([System.IO.Path]::GetTempPath())
$stagingRoot = Join-Path $temporaryRoot (
    "youtube-transcript-package-" + [Guid]::NewGuid().ToString("N")
)
$applicationRoot = Join-Path $stagingRoot "YouTubeTranscriptTool"

try {
    New-Item -ItemType Directory -Path $applicationRoot -Force | Out-Null
    foreach ($relativePath in $packageFiles) {
        $sourcePath = Join-Path $sourceRoot $relativePath
        $stagedPath = Join-Path $applicationRoot $relativePath
        $stagedParent = Split-Path -Parent $stagedPath
        if (-not (Test-Path -LiteralPath $stagedParent -PathType Container)) {
            New-Item -ItemType Directory -Path $stagedParent -Force | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $stagedPath -Force
    }

    if (Test-Path -LiteralPath $canonicalOutputPath -PathType Leaf) {
        Remove-Item -LiteralPath $canonicalOutputPath -Force
    }

    Compress-Archive `
        -LiteralPath $applicationRoot `
        -DestinationPath $canonicalOutputPath `
        -CompressionLevel Optimal
}
finally {
    if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
        $resolvedStagingRoot = Get-CanonicalPath -Path (Resolve-Path -LiteralPath $stagingRoot).Path
        $expectedPrefix = Join-Path $temporaryRoot "youtube-transcript-package-"
        if (-not $resolvedStagingRoot.StartsWith(
                $expectedPrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Refusing to clean an unexpected package staging path: $resolvedStagingRoot"
        }

        Remove-Item -LiteralPath $resolvedStagingRoot -Recurse -Force
    }
}

Write-Host "Created Windows package:"
Write-Host $canonicalOutputPath
