$script:SupportedTranscriptLanguages = @("auto", "ru", "en", "de")

function Get-TranscriptToolRoot {
    Split-Path -Parent $PSCommandPath
}

function Get-TranscriptSettingsPath {
    $dir = Join-Path $env:APPDATA "YouTubeTranscriptTool"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Join-Path $dir "settings.json"
}

function Get-DefaultTranscriptSettings {
    [pscustomobject]@{
        OutputDir = Join-Path (Get-TranscriptToolRoot) "texts"
        Language = "auto"
        KeepSubtitles = $false
    }
}

function Read-TranscriptSettings {
    $defaults = Get-DefaultTranscriptSettings
    $path = Get-TranscriptSettingsPath

    if (-not (Test-Path -LiteralPath $path)) {
        return $defaults
    }

    try {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json

        if ($saved.OutputDir) {
            $defaults.OutputDir = [string]$saved.OutputDir
        }

        if ($saved.Language -and $script:SupportedTranscriptLanguages -contains [string]$saved.Language) {
            $defaults.Language = [string]$saved.Language
        }

        $defaults.KeepSubtitles = [bool]$saved.KeepSubtitles
    }
    catch {
        return $defaults
    }

    return $defaults
}

function Write-TranscriptSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [Parameter(Mandatory = $true)]
        [ValidateSet("auto", "ru", "en", "de")]
        [string]$Language,

        [bool]$KeepSubtitles
    )

    $settings = [pscustomobject]@{
        OutputDir = $OutputDir
        Language = $Language
        KeepSubtitles = $KeepSubtitles
    }

    $settings | ConvertTo-Json | Set-Content -LiteralPath (Get-TranscriptSettingsPath) -Encoding utf8
}

function Get-YtDlpPath {
    param(
        [string]$PreferredPath
    )

    if ($PreferredPath -and (Test-Path -LiteralPath $PreferredPath)) {
        return $PreferredPath
    }

    $local = Join-Path (Get-TranscriptToolRoot) "yt-dlp.exe"
    if (Test-Path -LiteralPath $local) {
        return $local
    }

    $command = Get-Command yt-dlp.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "yt-dlp.exe was not found. Put yt-dlp.exe next to this tool or install yt-dlp and add it to PATH."
}

function Test-YoutubeUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    return ($Url -match '^https?://(www\.)?(youtube\.com|youtu\.be)/')
}

function ConvertTo-NativeArgument {
    param(
        [AllowNull()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        $Argument = ""
    }

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = New-Object System.Text.StringBuilder
    [void]$escaped.Append('"')
    $backslashCount = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashCount++
            continue
        }

        if ($character -eq [char]'"') {
            if ($backslashCount -gt 0) {
                [void]$escaped.Append((New-Object string ([char]'\'), ($backslashCount * 2)))
            }

            [void]$escaped.Append('\"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$escaped.Append((New-Object string ([char]'\'), $backslashCount))
            $backslashCount = 0
        }

        [void]$escaped.Append($character)
    }

    if ($backslashCount -gt 0) {
        [void]$escaped.Append((New-Object string ([char]'\'), ($backslashCount * 2)))
    }

    [void]$escaped.Append('"')
    return $escaped.ToString()
}

function Invoke-TranscriptProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [string]$WorkingDirectory
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-NativeArgument -Argument $_ }) -join " ")
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw "Could not start process: $FilePath"
        }

        $stdOutTask = $process.StandardOutput.ReadToEndAsync()
        $stdErrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        $stdOut = $stdOutTask.GetAwaiter().GetResult()
        $stdErr = $stdErrTask.GetAwaiter().GetResult()
        $output = @($stdOut, $stdErr) |
            Where-Object { -not [string]::IsNullOrEmpty($_) }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdOut
            StdErr = $stdErr
            Output = ($output -join [System.Environment]::NewLine)
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-YtDlpJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$YtDlpPath,

        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $result = Invoke-TranscriptProcess -FilePath $YtDlpPath -ArgumentList @(
        '--skip-download', '--dump-single-json', '--no-warnings', '--no-playlist', $Url
    )

    if ($result.ExitCode -ne 0) {
        $message = $result.Output.Trim()

        if ($message -match "Unsupported URL|Invalid URL") {
            throw "The YouTube link looks invalid. Please paste a normal youtube.com or youtu.be video link."
        }

        if ($message -match "Private video|Video unavailable|This video is unavailable|Sign in") {
            throw "This video is unavailable without login or cannot be accessed by yt-dlp."
        }

        if ($message -match "HTTP Error|Unable to download|Temporary failure|timed out|network") {
            throw "Network problem while checking the video. Try again in a few minutes."
        }

        throw "Could not read video information. yt-dlp said: $message"
    }

    try {
        return ($result.StdOut | ConvertFrom-Json)
    }
    catch {
        throw "yt-dlp returned metadata that this tool could not read."
    }
}

function Get-SubtitleMapLanguages {
    param(
        [object]$Map
    )

    if (-not $Map) {
        return @()
    }

    $languages = foreach ($property in $Map.PSObject.Properties) {
        if ($property.Name -eq "live_chat") {
            continue
        }

        $formats = @($property.Value)
        if ($formats.Count -gt 0) {
            $hasTranscriptFormat = @($formats | Where-Object { $_.ext -in @("vtt", "srt") }).Count -gt 0
            if (-not $hasTranscriptFormat) {
                continue
            }
        }

        $property.Name
    }

    return @($languages | Sort-Object)
}

function Get-AvailableTranscriptLanguages {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Info
    )

    $manual = @(Get-SubtitleMapLanguages -Map $Info.subtitles)
    $auto = @(Get-SubtitleMapLanguages -Map $Info.automatic_captions)

    $all = @($manual + $auto) | Sort-Object -Unique

    [pscustomobject]@{
        Manual = $manual
        Auto = $auto
        All = $all
    }
}

function Get-LanguageCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("ru", "en", "de")]
        [string]$Language
    )

    if ($Language -eq "ru") {
        return @("ru-orig", "ru", "ru-RU")
    }

    if ($Language -eq "en") {
        return @("en-orig", "en", "en-GB", "en-US")
    }

    return @("de-orig", "de", "de-DE")
}

function Find-LanguageTag {
    param(
        [AllowEmptyCollection()]
        [string[]]$AvailableTags = @(),

        [Parameter(Mandatory = $true)]
        [string]$Language
    )

    foreach ($candidate in (Get-LanguageCandidates -Language $Language)) {
        if ($AvailableTags -contains $candidate) {
            return $candidate
        }
    }

    $languagePattern = "^{0}(-|$)" -f [regex]::Escape($Language)
    foreach ($tag in $AvailableTags) {
        if ($tag -match $languagePattern) {
            return $tag
        }
    }

    return $null
}

function Resolve-TranscriptSubtitleChoice {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Info,

        [Parameter(Mandatory = $true)]
        [string]$Preference
    )

    $available = Get-AvailableTranscriptLanguages -Info $Info

    if ($available.All.Count -eq 0) {
        throw "No subtitles or auto-generated captions were found for this video."
    }

    $preferenceOrder = if ($Preference -eq "auto") {
        @("ru", "en", "de")
    }
    else {
        @($Preference)
    }

    foreach ($language in $preferenceOrder) {
        $manualTag = Find-LanguageTag -AvailableTags $available.Manual -Language $language
        if ($manualTag) {
            return [pscustomobject]@{
                Language = $language
                Tag = $manualTag
                Source = "manual"
                Available = $available
            }
        }

        $autoTag = Find-LanguageTag -AvailableTags $available.Auto -Language $language
        if ($autoTag) {
            return [pscustomobject]@{
                Language = $language
                Tag = $autoTag
                Source = "auto"
                Available = $available
            }
        }
    }

    if ($Preference -eq "auto") {
        $tag = @($available.Manual + $available.Auto | Select-Object -First 1)[0]
        $source = if ($available.Manual -contains $tag) { "manual" } else { "auto" }
        $language = ($tag -split "-")[0]

        return [pscustomobject]@{
            Language = $language
            Tag = $tag
            Source = $source
            Available = $available
        }
    }

    $list = if ($available.All.Count -gt 0) { $available.All -join ", " } else { "none" }
    throw "Selected subtitle language '$Preference' is not available. Available subtitle languages: $list"
}

function New-SafeFilePart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $safe = $Value
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$char, "-")
    }

    $safe = $safe -replace '[\s_]+', '-'
    $safe = $safe -replace '-{2,}', '-'
    $safe = $safe.Trim(" ", "-", ".")

    if ($safe.Length -gt 80) {
        $safe = $safe.Substring(0, 80).Trim(" ", "-", ".")
    }

    if (-not $safe) {
        return "video"
    }

    return $safe
}

function New-TranscriptFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$VideoId,

        [Parameter(Mandatory = $true)]
        [string]$Language,

        [datetime]$Date = (Get-Date)
    )

    $datePart = $Date.ToString("yyyy-MM-dd")
    $titlePart = New-SafeFilePart -Value $Title
    $idPart = New-SafeFilePart -Value $VideoId
    $languagePart = New-SafeFilePart -Value $Language
    return "${datePart}_${titlePart}_${idPart}_${languagePart}.txt"
}

function Test-SubtitleTimestamp {
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    return [bool]($Line -match '^\s*(?:\d{2,}:)?\d{2}:\d{2}[\.,]\d{3}\s+-->\s+(?:\d{2,}:)?\d{2}:\d{2}[\.,]\d{3}(?:\s+.*)?$')
}

function Format-TranscriptParagraphs {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Sentences
    )

    if ($Sentences.Count -eq 0) {
        return ""
    }

    $paragraphs = New-Object System.Collections.Generic.List[string]
    $current = ""
    $count = 0

    foreach ($sentence in $Sentences) {
        $sentence = $sentence.Trim()

        if (-not $current) {
            $current = $sentence
            $count = 1
            continue
        }

        if (($current.Length + $sentence.Length) -gt 520 -or $count -ge 4) {
            $paragraphs.Add($current)
            $current = $sentence
            $count = 1
        }
        else {
            $current = "$current $sentence"
            $count++
        }
    }

    if ($current) {
        $paragraphs.Add($current)
    }

    return ($paragraphs -join "`r`n`r`n")
}

function Convert-SubtitleFileToTranscriptText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$TranscriptMode
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Subtitle file was not found: $Path"
    }

    $sourceLines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    $lines = New-Object System.Collections.Generic.List[string]
    $prev = $null
    $block = $null
    $atCueBoundary = $true

    for ($i = 0; $i -lt $sourceLines.Count; $i++) {
        $rawLine = [string]$sourceLines[$i]

        if ($block) {
            if ([string]::IsNullOrWhiteSpace($rawLine)) {
                $block = $null
                $atCueBoundary = $true
            }

            continue
        }

        if ([string]::IsNullOrWhiteSpace($rawLine)) {
            $atCueBoundary = $true
            continue
        }

        if ($rawLine -match '^\s*(NOTE|STYLE|REGION)(?:\s|$)') {
            $block = $Matches[1]
            continue
        }

        if ($rawLine -match '^\s*(?:WEBVTT(?:\s.*)?|Kind:.*|Language:.*)\s*$') {
            continue
        }

        if ($atCueBoundary) {
            $nextIndex = $i + 1
            while ($nextIndex -lt $sourceLines.Count -and [string]::IsNullOrWhiteSpace([string]$sourceLines[$nextIndex])) {
                $nextIndex++
            }

            if ($nextIndex -lt $sourceLines.Count -and (Test-SubtitleTimestamp -Line ([string]$sourceLines[$nextIndex]))) {
                continue
            }
        }

        if (Test-SubtitleTimestamp -Line $rawLine) {
            $atCueBoundary = $false
            continue
        }

        $line = $rawLine -replace '<[^>]+>', ''
        $line = [System.Net.WebUtility]::HtmlDecode($line)
        $line = $line -replace ([char]0x00A0), ' '
        $line = $line -replace '\[.*?\]', ''
        $line = $line.Trim()

        if ($line -and $line -ne $prev) {
            $prev = $line
            $lines.Add($line)
        }

        $atCueBoundary = $false
    }

    $text = ($lines -join ' ')
    $text = $text -replace '\s{2,}', ' '
    $text = $text -replace '\s+([.,!?;:])', '$1'
    $text = $text.Trim()

    if (-not $text) {
        throw "Subtitle file did not contain readable transcript text."
    }

    $sentences = @([regex]::Split($text, '(?<=[.!?])\s+') | Where-Object { $_.Trim() })
    return Format-TranscriptParagraphs -Sentences $sentences
}

function Save-TranscriptFromYoutube {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [Parameter(Mandatory = $true)]
        [ValidateSet("auto", "ru", "en", "de")]
        [string]$Language,

        [bool]$KeepSubtitles,

        [string]$YtDlpPath,

        [scriptblock]$OnStatus
    )

    if (-not (Test-YoutubeUrl -Url $Url)) {
        throw "The link does not look like a YouTube video URL."
    }

    $tool = Get-YtDlpPath -PreferredPath $YtDlpPath

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        try {
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        }
        catch {
            throw "Cannot create or access the selected output folder: $OutputDir"
        }
    }

    try {
        $probe = Join-Path $OutputDir (".write-test-" + [System.Guid]::NewGuid().ToString("N"))
        Set-Content -LiteralPath $probe -Value "test" -Encoding ascii
        Remove-Item -LiteralPath $probe -Force
    }
    catch {
        throw "Cannot write files to the selected output folder: $OutputDir"
    }

    if ($OnStatus) { & $OnStatus "Checking link" }
    $info = Invoke-YtDlpJson -YtDlpPath $tool -Url $Url

    if ($OnStatus) { & $OnStatus "Looking for subtitles" }
    $choice = Resolve-TranscriptSubtitleChoice -Info $info -Preference $Language

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("youtube-transcript-tool-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $args = @(
            "--skip-download",
            "--no-playlist",
            "--sub-langs", $choice.Tag,
            "--sub-format", "vtt/best",
            "-o", (Join-Path $tempDir "%(id)s.%(ext)s")
        )

        if ($choice.Source -eq "manual") {
            $args += "--write-subs"
        }
        else {
            $args += "--write-auto-subs"
        }

        $args += $Url

        if ($OnStatus) { & $OnStatus "Saving file" }
        $downloadResult = Invoke-TranscriptProcess -FilePath $tool -ArgumentList $args
        $downloadOutput = $downloadResult.Output
        $exitCode = $downloadResult.ExitCode
        $subtitleFile = Get-ChildItem -LiteralPath $tempDir -File |
            Where-Object { $_.Extension -in ".vtt", ".srt" } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($exitCode -ne 0 -and -not $subtitleFile) {
            $message = ($downloadOutput -join "`n").Trim()

            if ($message -match "HTTP Error 429|Too Many Requests") {
                throw "YouTube temporarily rate-limited subtitle downloads. Wait a little and try again."
            }

            throw "Could not download subtitles. yt-dlp said: $message"
        }

        if (-not $subtitleFile) {
            throw "yt-dlp did not produce a subtitle file for the selected language."
        }

        $videoTitle = if ($info.title) { [string]$info.title } else { "video" }
        $videoId = if ($info.id) { [string]$info.id } else { [System.Guid]::NewGuid().ToString("N") }
        $fileName = New-TranscriptFileName -Title $videoTitle -VideoId $videoId -Language $choice.Language
        $txtPath = Join-Path $OutputDir $fileName
        $text = Convert-SubtitleFileToTranscriptText -Path $subtitleFile.FullName
        Set-Content -LiteralPath $txtPath -Value $text -Encoding utf8

        $subtitlePath = $null
        if ($KeepSubtitles) {
            $subtitleName = [System.IO.Path]::ChangeExtension($fileName, $subtitleFile.Extension)
            $subtitlePath = Join-Path $OutputDir $subtitleName
            Copy-Item -LiteralPath $subtitleFile.FullName -Destination $subtitlePath -Force
        }

        if ($OnStatus) { & $OnStatus "Done" }

        return [pscustomobject]@{
            TextPath = $txtPath
            SubtitlePath = $subtitlePath
            OutputDir = $OutputDir
            Language = $choice.Language
            SubtitleTag = $choice.Tag
            Source = $choice.Source
            Title = $videoTitle
            VideoId = $videoId
            AvailableLanguages = $choice.Available.All
        }
    }
    catch {
        throw $_
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @(
    "Read-TranscriptSettings",
    "Write-TranscriptSettings",
    "Get-YtDlpPath",
    "Test-YoutubeUrl",
    "Invoke-TranscriptProcess",
    "Invoke-YtDlpJson",
    "Get-AvailableTranscriptLanguages",
    "Resolve-TranscriptSubtitleChoice",
    "New-TranscriptFileName",
    "Convert-SubtitleFileToTranscriptText",
    "Save-TranscriptFromYoutube"
)
