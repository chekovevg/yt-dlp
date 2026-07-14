param(
    [Parameter(Position = 0)]
    [string]$Url,

    [switch]$List,
    [switch]$CleanOnly,
    [switch]$NoClean,
    [switch]$KeepSubs,
    [switch]$Srt,
    [switch]$CleanTranscript,

    [ValidateSet("auto", "ru", "en", "de")]
    [string]$Prefer = "auto",

    [string]$OutputDir = "texts",

    [string]$Langs = ""
)

$ErrorActionPreference = "Stop"

$tool = Join-Path $PSScriptRoot "yt-dlp.exe"
$modulePath = Join-Path $PSScriptRoot "transcript-tool.psm1"

if (-not (Test-Path -LiteralPath $tool)) {
    throw "yt-dlp.exe was not found in $PSScriptRoot"
}

Import-Module $modulePath -Force

function Get-OutputDirectory {
    if ([System.IO.Path]::IsPathRooted($OutputDir)) {
        return $OutputDir
    }

    return (Join-Path $PSScriptRoot $OutputDir)
}

function Get-CleanOnlySubtitlePriority {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $name = $File.Name.ToLowerInvariant()
    $priority = if ($Prefer -eq "en") {
        @("en-orig", "en", "ru", "ru-orig", "de-orig", "de")
    }
    elseif ($Prefer -eq "ru") {
        @("ru-orig", "ru", "en", "en-orig", "de-orig", "de")
    }
    elseif ($Prefer -eq "de") {
        @("de-orig", "de", "en", "en-orig", "ru", "ru-orig")
    }
    else {
        @("ru-orig", "ru", "en-orig", "en", "de-orig", "de")
    }

    for ($i = 0; $i -lt $priority.Count; $i++) {
        $tag = [regex]::Escape($priority[$i])
        if ($name -match "\.$tag\.(vtt|srt)$") {
            return $i
        }
    }

    return 9
}

function Select-CleanOnlySubtitleFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$Subtitles
    )

    return $Subtitles |
        Sort-Object `
            @{ Expression = { Get-CleanOnlySubtitlePriority -File $_ }; Ascending = $true },
            @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true } |
        Select-Object -First 1
}

if ($List) {
    if (-not $Url) {
        throw "Usage: .\download-subs.ps1 -List VIDEO_URL"
    }

    $listResult = Invoke-TranscriptProcess -FilePath $tool -ArgumentList @("--skip-download", "--list-subs", $Url)
    if ($listResult.StdOut) {
        [Console]::Out.Write($listResult.StdOut)
    }

    if ($listResult.StdErr) {
        [Console]::Error.Write($listResult.StdErr)
    }

    exit $listResult.ExitCode
}

if ($CleanOnly) {
    $subtitles = @(Get-ChildItem -LiteralPath $PSScriptRoot -File |
        Where-Object { $_.Extension -in ".vtt", ".srt" })

    if ($subtitles.Count -eq 0) {
        throw "No .vtt or .srt files were found in $PSScriptRoot"
    }

    $latest = Select-CleanOnlySubtitleFile -Subtitles $subtitles
    if (-not $latest) {
        throw "No .vtt or .srt files were found in $PSScriptRoot"
    }

    $saved = Save-TranscriptFromSubtitleFile `
        -Path $latest.FullName `
        -OutputDir (Get-OutputDirectory) `
        -CleanTranscript ([bool]$CleanTranscript)
    Write-Host "Created clean text: $($saved.TextPath)"

    if ($saved.TextPath) {
        & notepad $saved.TextPath
    }

    exit 0
}

if (-not $Url) {
    throw "Usage: .\download-subs.ps1 VIDEO_URL"
}

$saved = Save-TranscriptFromYoutubeCli `
    -Url $Url `
    -OutputDir (Get-OutputDirectory) `
    -Preference $Prefer `
    -SubtitleLanguages $Langs `
    -NoClean ([bool]$NoClean) `
    -KeepSubtitles ([bool]$KeepSubs) `
    -Srt ([bool]$Srt) `
    -CleanTranscript ([bool]$CleanTranscript) `
    -YtDlpPath $tool `
    -OnAttempt {
        param($subtitleLanguages)
        Write-Host "Trying subtitles: $subtitleLanguages"
    }

if ($NoClean) {
    exit $saved.ExitCode
}

if (-not $saved.FoundSubtitles) {
    Write-Host "No Russian, English, or German subtitles were found for this video."
    Write-Host "Check all available subtitle languages with:"
    Write-Host ".\download-subs.cmd -List `"$Url`""
    exit 1
}

if ($saved.YtDlpExitCode -ne 0) {
    Write-Warning "yt-dlp reported an error, but a subtitle file was downloaded. Cleaning the downloaded subtitle anyway."
}

if ($saved.TextPath) {
    Write-Host "Created clean text: $($saved.TextPath)"
    & notepad $saved.TextPath
}

exit $saved.ExitCode
