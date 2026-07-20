$ErrorActionPreference = "Stop"

function Get-CanonicalTranscriptDirectoryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -ne $pathRoot) {
        $fullPath = $fullPath.TrimEnd([char[]]@(92, 47))
    }

    return $fullPath
}

function Get-TranscriptProjectNameValidation {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name
    )

    $trimmed = ([string]$Name).Trim()
    $errorCode = $null

    if (-not $trimmed) {
        $errorCode = "Empty"
    }
    elseif ($trimmed.Length -gt 80) {
        $errorCode = "TooLong"
    }
    elseif ($trimmed -in ".", "..") {
        $errorCode = "Relative"
    }
    elseif ($trimmed.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        $errorCode = "InvalidCharacters"
    }
    elseif ($trimmed.EndsWith(".")) {
        $errorCode = "TrailingDotOrSpace"
    }
    elseif ($trimmed -match "(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$") {
        $errorCode = "Reserved"
    }

    return [pscustomobject]@{
        IsValid = ($null -eq $errorCode)
        Name = $trimmed
        ErrorCode = $errorCode
    }
}

function Get-TranscriptProjectNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    if (-not (Test-Path -LiteralPath $RootDir -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $RootDir -Directory -Force |
            Where-Object { -not $_.Name.StartsWith(".youtube-transcript-operation-") } |
            Select-Object -ExpandProperty Name |
            Sort-Object
    )
}

function Resolve-TranscriptProjectOutputDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProjectName,

        [switch]$RequireExisting
    )

    $root = Get-CanonicalTranscriptDirectoryPath -Path $RootDir
    $candidate = $root

    if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
        $validation = Get-TranscriptProjectNameValidation -Name $ProjectName
        if (-not $validation.IsValid) {
            throw [System.ArgumentException]::new($validation.ErrorCode)
        }

        $candidate = Get-CanonicalTranscriptDirectoryPath `
            -Path (Join-Path $root $validation.Name)
        $rootPrefix = if ($root.EndsWith("\")) { $root } else { $root + "\" }

        if (-not $candidate.StartsWith(
                $rootPrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw [System.ArgumentException]::new("OutsideRoot")
        }
    }

    if ($RequireExisting -and -not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("ProjectMissing")
    }

    return $candidate
}

function New-TranscriptProjectDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $RootDir -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("RootMissing")
    }

    $validation = Get-TranscriptProjectNameValidation -Name $Name
    if (-not $validation.IsValid) {
        throw [System.ArgumentException]::new($validation.ErrorCode)
    }

    $projectPath = Resolve-TranscriptProjectOutputDirectory `
        -RootDir $RootDir `
        -ProjectName $validation.Name

    if (Test-Path -LiteralPath $projectPath) {
        throw [System.IO.IOException]::new("ProjectExists")
    }

    New-Item -ItemType Directory -Path $projectPath | Out-Null
    return (Get-CanonicalTranscriptDirectoryPath -Path $projectPath)
}

function Assert-TranscriptOutputDirectoriesWritable {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$OutputDirs
    )

    $directories = @(
        $OutputDirs |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { Get-CanonicalTranscriptDirectoryPath -Path $_ } |
            Sort-Object -Unique
    )

    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]::new("OutputDirectoryMissing")
        }

        $probePath = Join-Path $directory (
            ".transcript-write-test-" + [Guid]::NewGuid().ToString("N")
        )
        $stream = $null

        try {
            $stream = [System.IO.File]::Open(
                $probePath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
        }
        catch {
            throw [System.UnauthorizedAccessException]::new(
                "OutputDirectoryNotWritable",
                $_.Exception
            )
        }
        finally {
            if ($stream) {
                $stream.Dispose()
            }

            if (Test-Path -LiteralPath $probePath -PathType Leaf) {
                Remove-Item -LiteralPath $probePath -Force
            }
        }
    }
}

Export-ModuleMember -Function @(
    "Get-TranscriptProjectNameValidation",
    "Get-TranscriptProjectNames",
    "Resolve-TranscriptProjectOutputDirectory",
    "New-TranscriptProjectDirectory",
    "Assert-TranscriptOutputDirectoriesWritable"
)
