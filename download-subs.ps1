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

if (-not (Test-Path -LiteralPath $tool)) {
    throw "yt-dlp.exe was not found in $PSScriptRoot"
}

$script:PreferredLanguage = $null

function Get-OutputDirectory {
    if ([System.IO.Path]::IsPathRooted($OutputDir)) {
        return $OutputDir
    }

    return (Join-Path $PSScriptRoot $OutputDir)
}

function ConvertFrom-Utf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Get-VideoLanguage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoUrl
    )

    try {
        $language = & $tool --skip-download --print "%(language)s" $VideoUrl 2>$null |
            Select-Object -First 1

        if ($LASTEXITCODE -eq 0 -and $language -and $language -ne "NA") {
            return $language.Trim().ToLowerInvariant()
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-TranscriptTerms {
    $terms = @{
        KiraMuratova = ConvertFrom-Utf8Bytes @(208,154,208,184,209,128,208,176,32,208,156,209,131,209,128,208,176,209,130,208,190,208,178,208,176)
        KireMuratovoy = ConvertFrom-Utf8Bytes @(208,154,208,184,209,128,208,181,32,208,156,209,131,209,128,208,176,209,130,208,190,208,178,208,190,208,185)
        KirMuratovoyBad = ConvertFrom-Utf8Bytes @(208,186,208,184,209,128,208,188,209,131,209,128,208,176,209,130,208,190,208,178,208,190,208,185)
        Kir = ConvertFrom-Utf8Bytes @(208,186,208,184,209,128)
        Murat = ConvertFrom-Utf8Bytes @(208,188,209,131,209,128,208,176,209,130)
        Redimag = ConvertFrom-Utf8Bytes @(209,128,208,181,208,180,208,184,208,188,208,176,208,179)
        FigmaStem = ConvertFrom-Utf8Bytes @(209,132,208,184,208,179,208,188)
        EdWood = ConvertFrom-Utf8Bytes @(208,173,208,180,32,208,146,209,131,208,180)
        EdwoodBad = ConvertFrom-Utf8Bytes @(209,141,208,180,208,178,209,131,208,180)
        Karvaya = ConvertFrom-Utf8Bytes @(208,186,208,176,209,128,208,178,208,176,209,143)
        WongKarWai = ConvertFrom-Utf8Bytes @(208,146,208,190,208,189,208,179,32,208,154,208,176,209,128,45,208,178,208,176,208,185)
        FillerE = ConvertFrom-Utf8Bytes @(209,141)
        FillerA = ConvertFrom-Utf8Bytes @(208,176)
        FillerM = ConvertFrom-Utf8Bytes @(208,188)
    }

    return $terms
}

function Resolve-PreferredLanguage {
    if ($script:PreferredLanguage -match '^en') {
        return "en"
    }

    if ($script:PreferredLanguage -match '^ru') {
        return "ru"
    }

    if ($script:PreferredLanguage -match '^de') {
        return "de"
    }

    return $null
}

function Get-SubtitleLanguageTags {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("ru", "en", "de")]
        [string]$Language
    )

    if ($Language -eq "ru") {
        return @("ru-orig", "ru")
    }

    if ($Language -eq "en") {
        return @("en-orig", "en", "en-GB", "en-US")
    }

    return @("de-orig", "de")
}

function Get-SubtitleLanguageAttempts {
    param(
        [string]$RequestedLangs
    )

    if ($RequestedLangs) {
        return @($RequestedLangs)
    }

    if ($Prefer -eq "en") {
        return @(Get-SubtitleLanguageTags -Language "en")
    }

    if ($Prefer -eq "ru") {
        return @(Get-SubtitleLanguageTags -Language "ru")
    }

    if ($Prefer -eq "de") {
        return @(Get-SubtitleLanguageTags -Language "de")
    }

    $preferred = Resolve-PreferredLanguage

    if ($preferred -eq "en") {
        return @(
            Get-SubtitleLanguageTags -Language "en"
            Get-SubtitleLanguageTags -Language "ru"
            Get-SubtitleLanguageTags -Language "de"
        )
    }

    if ($preferred -eq "ru") {
        return @(
            Get-SubtitleLanguageTags -Language "ru"
            Get-SubtitleLanguageTags -Language "en"
            Get-SubtitleLanguageTags -Language "de"
        )
    }

    if ($preferred -eq "de") {
        return @(
            Get-SubtitleLanguageTags -Language "de"
            Get-SubtitleLanguageTags -Language "en"
            Get-SubtitleLanguageTags -Language "ru"
        )
    }

    return @(
        Get-SubtitleLanguageTags -Language "ru"
        Get-SubtitleLanguageTags -Language "en"
        Get-SubtitleLanguageTags -Language "de"
    )
}

function Convert-SubtitleToText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$TranscriptMode
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Subtitle file was not found: $Path"
    }

    $outputDirectory = Get-OutputDirectory
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    if ($TranscriptMode) {
        $outName = [System.IO.Path]::ChangeExtension((Split-Path -Leaf $Path), ".clean.txt")
    }
    else {
        $outName = [System.IO.Path]::ChangeExtension((Split-Path -Leaf $Path), ".txt")
    }

    $out = Join-Path $outputDirectory $outName
    $prev = $null

    $text = Get-Content -LiteralPath $Path -Encoding utf8 |
        Where-Object {
            $_ -notmatch '^(WEBVTT|Kind:.*|Language:.*|NOTE.*|STYLE.*|\s*|\d+|\d{2}:\d{2}:\d{2}[\.,]\d{3}\s+-->\s+\d{2}:\d{2}:\d{2}[\.,]\d{3}(\s+.*)?)$'
        } |
        ForEach-Object {
            $line = $_
            $line = $line -replace '<[^>]+>', ''
            $line = [System.Net.WebUtility]::HtmlDecode($line)
            $line = $line -replace '>>', ''
            $line = $line -replace ([char]0x00A0), ' '
            $line = $line -replace '\[.*?\]', ''
            $line = $line.Trim()

            if ($TranscriptMode) {
                $line = Normalize-TranscriptLine -Line $line
            }

            if ($line -and $line -ne $prev) {
                $prev = $line
                $line
            }
        }

    $joined = ($text -join ' ')
    $joined = $joined -replace '\s{2,}', ' '
    $joined = $joined -replace '\s+([.,!?;:])', '$1'
    $joined = $joined -replace '([(\[{])\s+', '$1'
    $joined = $joined -replace '\s+([)\]}])', '$1'

    if ($TranscriptMode) {
        $joined = Format-TranscriptText -Text $joined
    }

    Set-Content -LiteralPath $out -Value $joined -Encoding utf8

    if ($TranscriptMode) {
        $reviewName = [System.IO.Path]::ChangeExtension((Split-Path -Leaf $Path), ".review.txt")
        $reviewPath = Join-Path $outputDirectory $reviewName
        Write-TranscriptReviewFile -Path $reviewPath -CleanPath $out
    }

    return $out
}

function Normalize-TranscriptLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $terms = Get-TranscriptTerms
    $line = $Line

    $fillers = @(
        [regex]::Escape($terms.FillerE),
        [regex]::Escape($terms.FillerA),
        [regex]::Escape($terms.FillerM),
        "uh",
        "um"
    ) -join "|"

    $line = $line -replace "(?i)^\s*($fillers)+\s+", ""

    $kir = [regex]::Escape($terms.Kir)
    $murat = [regex]::Escape($terms.Murat)
    $kirMuratovoyBad = [regex]::Escape($terms.KirMuratovoyBad)
    $line = $line -replace "(?i)\b$kirMuratovoyBad\b", $terms.KireMuratovoy
    $line = $line -replace "(?i)\b($kir\s*$murat\w*|$kir$murat\w*)овой\b", $terms.KireMuratovoy
    $line = $line -replace "(?i)\b($kir\s*$murat\w*|$kir$murat\w*)\b", $terms.KiraMuratova

    $redimag = [regex]::Escape($terms.Redimag)
    $line = $line -replace "(?i)\b(readymag|ready\s*mag|redimag\w*|$redimag\w*)\b", "Readymag"

    $figmaStem = [regex]::Escape($terms.FigmaStem)
    $line = $line -replace "(?i)\b(figma|figm\w*|$figmaStem\w*)\b", "Figma"

    $line = $line -replace "(?i)\b(webp|web\s*p|webpay|vp)\b", "WebP"
    $line = $line -replace "(?i)\b(gif|gi|gv)\b", "GIF"

    $edwoodBad = [regex]::Escape($terms.EdwoodBad)
    $line = $line -replace "(?i)\b(ed\s*wood|edwood|$edwoodBad)\b", $terms.EdWood

    $karvaya = [regex]::Escape($terms.Karvaya)
    $line = $line -replace "(?i)\b(wong\s*kar\s*wai|karvaya|$karvaya)\b", $terms.WongKarWai

    $line = $line -replace '\s{2,}', ' '
    return $line.Trim()
}

function Format-TranscriptText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $sentences = [regex]::Split($Text.Trim(), '(?<=[.!?])\s+') |
        Where-Object { $_.Trim() }

    $paragraphs = New-Object System.Collections.Generic.List[string]
    $current = ""
    $sentenceCount = 0

    foreach ($sentence in $sentences) {
        $sentence = $sentence.Trim()

        if (-not $current) {
            $current = $sentence
            $sentenceCount = 1
            continue
        }

        if (($current.Length + $sentence.Length) -gt 520 -or $sentenceCount -ge 3) {
            $paragraphs.Add($current)
            $current = $sentence
            $sentenceCount = 1
        }
        else {
            $current = "$current $sentence"
            $sentenceCount++
        }
    }

    if ($current) {
        $paragraphs.Add($current)
    }

    return ($paragraphs -join "`r`n`r`n")
}

function Write-TranscriptReviewFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$CleanPath
    )

    $terms = Get-TranscriptTerms
    $lines = @(
        "Review checklist",
        "",
        "Clean transcript: $CleanPath",
        "",
        "Check names and terms manually:",
        "- $($terms.KiraMuratova)",
        "- Readymag",
        "- Figma",
        "- WebP",
        "- GIF",
        "- $($terms.EdWood)",
        "- $($terms.WongKarWai)",
        "",
        "This file is a deterministic cleanup aid, not a verified transcript."
    )

    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}

function Get-SubtitleFiles {
    Get-ChildItem -LiteralPath $PSScriptRoot -File |
        Where-Object { $_.Extension -in ".vtt", ".srt" }
}

function Test-SubtitleLanguageMatch {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$SubtitleLangs
    )

    $name = $File.Name.ToLowerInvariant()
    $subtitleTag = $null

    if ($name -match '\.([a-z]{2,3}(?:-[a-z0-9]+)*)\.(vtt|srt)$') {
        $subtitleTag = $Matches[1]
    }

    $patterns = $SubtitleLangs.Split(",") |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ }

    foreach ($pattern in $patterns) {
        if ($pattern -eq "all") {
            return $true
        }

        if ($subtitleTag -and $subtitleTag -eq $pattern) {
            return $true
        }

        if ($subtitleTag -and $pattern -match '[\^\$\.\*\+\?\[\]\(\)\|]' -and $subtitleTag -match $pattern) {
            return $true
        }

        if ($pattern -match '^([a-z]{2,3})') {
            $language = $Matches[1]

            if ($name -match "\.$language(-orig)?\.(vtt|srt)$") {
                return $true
            }
        }
    }

    return $false
}

function Get-SubtitlePriority {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $name = $File.Name.ToLowerInvariant()
    $preferred = Resolve-PreferredLanguage

    if ($preferred -eq "en") {
        if ($name -match '\.en-orig\.(vtt|srt)$') {
            return 0
        }

        if ($name -match '\.en\.(vtt|srt)$') {
            return 1
        }

        if ($name -match '\.ru\.(vtt|srt)$') {
            return 2
        }

        if ($name -match '\.ru-orig\.(vtt|srt)$') {
            return 3
        }

        return 9
    }

    if ($preferred -eq "ru") {
        if ($name -match '\.ru-orig\.(vtt|srt)$') {
            return 0
        }

        if ($name -match '\.ru\.(vtt|srt)$') {
            return 1
        }

        if ($name -match '\.en\.(vtt|srt)$') {
            return 2
        }

        if ($name -match '\.en-orig\.(vtt|srt)$') {
            return 3
        }

        return 9
    }

    if ($preferred -eq "de") {
        if ($name -match '\.de-orig\.(vtt|srt)$') {
            return 0
        }

        if ($name -match '\.de\.(vtt|srt)$') {
            return 1
        }

        if ($name -match '\.en\.(vtt|srt)$') {
            return 2
        }

        if ($name -match '\.en-orig\.(vtt|srt)$') {
            return 3
        }

        if ($name -match '\.ru\.(vtt|srt)$') {
            return 4
        }

        if ($name -match '\.ru-orig\.(vtt|srt)$') {
            return 5
        }

        return 9
    }

    if ($name -match '\.ru-orig\.(vtt|srt)$') {
        return 0
    }

    if ($name -match '\.ru\.(vtt|srt)$') {
        return 1
    }

    if ($name -match '\.en-orig\.(vtt|srt)$') {
        return 2
    }

    if ($name -match '\.en\.(vtt|srt)$') {
        return 3
    }

    if ($name -match '\.de-orig\.(vtt|srt)$') {
        return 4
    }

    if ($name -match '\.de\.(vtt|srt)$') {
        return 5
    }

    return 9
}

function Select-PreferredSubtitleFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$Subtitles
    )

    $Subtitles |
        Sort-Object `
            @{ Expression = { Get-SubtitlePriority -File $_ }; Ascending = $true },
            @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true } |
        Select-Object -First 1
}

function Remove-IntermediateSubtitleFiles {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$Subtitles
    )

    if ($KeepSubs) {
        return
    }

    foreach ($subtitle in $Subtitles) {
        if (-not $subtitle) {
            continue
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($subtitle.Name)
        $extension = $subtitle.Extension
        $origName = "$baseName-orig$extension"
        $origPath = Join-Path $subtitle.DirectoryName $origName

        Remove-Item -LiteralPath $subtitle.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $origPath -Force -ErrorAction SilentlyContinue
    }
}

if ($List) {
    if (-not $Url) {
        throw "Usage: .\download-subs.ps1 -List VIDEO_URL"
    }

    & $tool --skip-download --list-subs $Url
    exit $LASTEXITCODE
}

if ($Prefer -ne "auto") {
    $script:PreferredLanguage = $Prefer
}

if ($CleanOnly) {
    $subtitles = @(Get-SubtitleFiles)

    if ($subtitles.Count -eq 0) {
        throw "No .vtt or .srt files were found in $PSScriptRoot"
    }

    $latest = Select-PreferredSubtitleFile -Subtitles $subtitles

    if (-not $latest) {
        throw "No .vtt or .srt files were found in $PSScriptRoot"
    }

    $txt = Convert-SubtitleToText -Path $latest.FullName -TranscriptMode:$CleanTranscript
    Remove-IntermediateSubtitleFiles -Subtitles @($latest)
    Write-Host "Created clean text: $txt"
    notepad $txt
    exit 0
}

if (-not $Url) {
    throw "Usage: .\download-subs.ps1 VIDEO_URL"
}

if ($Prefer -eq "auto") {
    $script:PreferredLanguage = Get-VideoLanguage -VideoUrl $Url
}

$before = @{}
Get-SubtitleFiles | ForEach-Object {
    $before[$_.FullName] = $_.LastWriteTimeUtc.Ticks
}

$languageAttempts = @(Get-SubtitleLanguageAttempts -RequestedLangs $Langs)
$downloadedSubtitles = @()
$ytDlpExitCode = 0

foreach ($subtitleLangs in $languageAttempts) {
    Write-Host "Trying subtitles: $subtitleLangs"

    $args = @(
        "--skip-download",
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs", $subtitleLangs
    )

    if ($Srt) {
        $args += @("--sub-format", "srt/best", "--convert-subs", "srt")
    }
    else {
        $args += @("--sub-format", "vtt/best")
    }

    $args += $Url

    & $tool @args
    $ytDlpExitCode = $LASTEXITCODE

    $downloadedSubtitles = @(Get-SubtitleFiles |
        Where-Object {
            -not $before.ContainsKey($_.FullName) -or
            $before[$_.FullName] -ne $_.LastWriteTimeUtc.Ticks
        })

    if ($downloadedSubtitles.Count -gt 0) {
        break
    }

    $downloadedSubtitles = @(Get-SubtitleFiles |
        Where-Object { Test-SubtitleLanguageMatch -File $_ -SubtitleLangs $subtitleLangs })

    if ($downloadedSubtitles.Count -gt 0) {
        break
    }
}

if ($NoClean) {
    if ($downloadedSubtitles.Count -gt 0) {
        exit 0
    }

    exit $ytDlpExitCode
}

if ($downloadedSubtitles.Count -eq 0) {
    Write-Host "No Russian, English, or German subtitles were found for this video."
    Write-Host "Check all available subtitle languages with:"
    Write-Host ".\download-subs.cmd -List `"$Url`""
    exit 1
}

$downloaded = Select-PreferredSubtitleFile -Subtitles $downloadedSubtitles

if ($ytDlpExitCode -ne 0) {
    Write-Warning "yt-dlp reported an error, but a subtitle file was downloaded. Cleaning the downloaded subtitle anyway."
}

$txt = Convert-SubtitleToText -Path $downloaded.FullName -TranscriptMode:$CleanTranscript
Remove-IntermediateSubtitleFiles -Subtitles $downloadedSubtitles
Write-Host "Created clean text: $txt"
notepad $txt
exit 0
