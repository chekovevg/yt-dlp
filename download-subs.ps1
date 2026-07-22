param(
    [Parameter(Position = 0)]
    [string]$Url,

    [switch]$List,
    [switch]$CleanOnly,
    [switch]$NoClean,
    [switch]$KeepSubs,
    [switch]$Srt,
    [switch]$CleanTranscript,

    [string]$Prefer,

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

if ($PSBoundParameters.ContainsKey("Prefer") -or $PSBoundParameters.ContainsKey("Langs")) {
    throw "-Prefer and -Langs are no longer supported. Online downloads always use the video's original language."
}

function Get-OutputDirectory {
    if ([System.IO.Path]::IsPathRooted($OutputDir)) {
        return $OutputDir
    }

    return (Join-Path $PSScriptRoot $OutputDir)
}

function Select-CleanOnlySubtitleFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$Subtitles
    )

    return $Subtitles |
        Sort-Object `
            @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true },
            @{ Expression = { $_.FullName }; Ascending = $true } |
        Select-Object -First 1
}

if ($List) {
    if (-not $Url) {
        throw "Usage: .\download-subs.ps1 -List VIDEO_URL"
    }

    $managedTool = Get-YtDlpPath -PreferredPath $tool
    $info = Invoke-YtDlpJson -YtDlpPath $managedTool -Url $Url
    foreach ($track in @(Get-TranscriptSubtitleInventory -Info $info)) {
        [Console]::Out.WriteLine(("{0}`t{1}" -f @($track.RawTrackTag, $track.SourceKind)))
    }
    exit 0
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
    -NoClean ([bool]$NoClean) `
    -KeepSubtitles ([bool]$KeepSubs) `
    -Srt ([bool]$Srt) `
    -CleanTranscript ([bool]$CleanTranscript) `
    -YtDlpPath $tool

$diagnostic = if ($saved.Output) { [string]$saved.Output } else { [string]$saved.StdErr }

if (-not $saved.FoundSubtitles -and $diagnostic) {
    Write-Warning "yt-dlp diagnostic: $diagnostic"
}

if ($saved.FoundSubtitles -and $saved.YtDlpExitCode -ne 0) {
    $warning = if ($NoClean) {
        "yt-dlp reported an error, but a subtitle file was downloaded. Saving the downloaded subtitle anyway."
    }
    else {
        "yt-dlp reported an error, but a subtitle file was downloaded. Cleaning the downloaded subtitle anyway."
    }
    if ($diagnostic) {
        $warning = "$warning yt-dlp diagnostic: $diagnostic"
    }

    Write-Warning $warning
}

if ($saved.FoundSubtitles) {
    switch ([string]$saved.WarningCode) {
        "AutomaticOriginalAccuracy" {
            Write-Warning "Автоматически распознанные субтитры. Имена, числа, адреса и другие детали могут содержать ошибки распознавания."
        }
        "ManualLanguageUnconfirmed" {
            Write-Warning "Язык не удалось независимо подтвердить. Сохранён единственный доступный авторский трек."
        }
    }
}

if ($NoClean) {
    exit $saved.ExitCode
}

if (-not $saved.FoundSubtitles) {
    Write-Host "No verified original subtitle track was downloaded for this video."
    Write-Host "Check all available subtitle languages with:"
    Write-Host ".\download-subs.cmd -List `"$Url`""
    exit 1
}

if ($saved.TextPath) {
    Write-Host "Created clean text: $($saved.TextPath)"
    & notepad $saved.TextPath
}

exit $saved.ExitCode
