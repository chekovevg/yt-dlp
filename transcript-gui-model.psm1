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

function New-TranscriptBatchPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [Parameter(Mandatory = $true)]
        [string]$RootDir,

        [Parameter(Mandatory = $true)]
        [ValidateSet("auto", "ru", "en", "de")]
        [string]$Language
    )

    if (@($Rows).Count -gt 6) {
        throw [System.ArgumentException]::new("TooManyRows")
    }

    $items = @()
    foreach ($row in @($Rows)) {
        $url = ([string]$row.Url).Trim()
        if (-not $url) {
            continue
        }

        $projectName = ([string]$row.ProjectName).Trim()
        $outputDir = Resolve-TranscriptProjectOutputDirectory `
            -RootDir $RootDir `
            -ProjectName $projectName `
            -RequireExisting

        $items += [pscustomobject]@{
            CardId = [string]$row.CardId
            Url = $url
            ProjectName = $projectName
            OutputDir = $outputDir
            Language = $Language
        }
    }

    if ($items.Count -eq 0) {
        throw [System.ArgumentException]::new("NoVideos")
    }

    return @($items)
}

function New-TranscriptQueueState {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items
    )

    $queueItems = @($Items)
    return [pscustomobject]@{
        Items = $queueItems
        NextIndex = 0
        Completed = 0
        Failed = 0
        IsRunning = ($queueItems.Count -gt 0)
    }
}

function Get-TranscriptQueueCurrentItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    if (-not $State.IsRunning -or $State.NextIndex -ge $State.Items.Count) {
        return $null
    }

    return $State.Items[$State.NextIndex]
}

function Move-TranscriptQueueNext {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [bool]$Succeeded
    )

    if (-not $State.IsRunning -or $State.NextIndex -ge $State.Items.Count) {
        throw [System.InvalidOperationException]::new("QueueNotRunning")
    }

    if ($Succeeded) {
        $State.Completed++
    }
    else {
        $State.Failed++
    }

    $State.NextIndex++
    if ($State.NextIndex -ge $State.Items.Count) {
        $State.IsRunning = $false
    }
}

function Get-TranscriptQueueSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    return [pscustomobject]@{
        Total = $State.Items.Count
        Completed = $State.Completed
        Failed = $State.Failed
        IsRunning = [bool]$State.IsRunning
    }
}

function Resolve-TranscriptResultFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw [System.IO.FileNotFoundException]::new("ResultFileMissing")
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("ResultFileMissing")
    }

    return $fullPath
}

function Read-TranscriptResultFileText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = Resolve-TranscriptResultFilePath -Path $Path
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    return [System.IO.File]::ReadAllText($fullPath, $utf8)
}

function Get-TranscriptExplorerSelectArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = Resolve-TranscriptResultFilePath -Path $Path
    return '/select,"{0}"' -f $fullPath
}

Export-ModuleMember -Function @(
    "Get-TranscriptProjectNameValidation",
    "Get-TranscriptProjectNames",
    "Resolve-TranscriptProjectOutputDirectory",
    "New-TranscriptProjectDirectory",
    "Assert-TranscriptOutputDirectoriesWritable",
    "New-TranscriptBatchPlan",
    "New-TranscriptQueueState",
    "Get-TranscriptQueueCurrentItem",
    "Move-TranscriptQueueNext",
    "Get-TranscriptQueueSummary",
    "Resolve-TranscriptResultFilePath",
    "Read-TranscriptResultFileText",
    "Get-TranscriptExplorerSelectArgument"
)
