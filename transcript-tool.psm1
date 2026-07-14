$script:SupportedTranscriptLanguages = @("auto", "ru", "en", "de")

if (-not ("TranscriptFileCleanupTools" -as [type])) {
    Add-Type @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

public static class TranscriptFileCleanupTools
{
    private const uint DELETE = 0x00010000;
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    public static FileStream OpenDeleteOnCloseLock(string path)
    {
        return new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.Read,
            1,
            FileOptions.DeleteOnClose);
    }

    public static string GetIdentity(string path)
    {
        IntPtr handle = OpenIdentityHandle(path, FILE_READ_ATTRIBUTES);
        try { return ReadIdentity(handle); }
        finally { CloseHandle(handle); }
    }

    public static bool DeleteIfIdentityMatches(string path, string expectedIdentity)
    {
        IntPtr handle = CreateFile(
            path,
            DELETE | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            IntPtr.Zero);
        if (handle == INVALID_HANDLE_VALUE)
        {
            int error = Marshal.GetLastWin32Error();
            if (error == 2 || error == 3) { return false; }
            throw new Win32Exception(error, "Could not open transcript output for identity-safe cleanup.");
        }

        try
        {
            if (!String.Equals(ReadIdentity(handle), expectedIdentity, StringComparison.Ordinal))
            {
                return false;
            }

            FILE_DISPOSITION_INFO disposition = new FILE_DISPOSITION_INFO();
            disposition.DeleteFile = true;
            if (!SetFileInformationByHandle(
                handle,
                4,
                ref disposition,
                (uint)Marshal.SizeOf(typeof(FILE_DISPOSITION_INFO))))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not remove matching transcript output.");
            }
            return true;
        }
        finally { CloseHandle(handle); }
    }

    private static IntPtr OpenIdentityHandle(string path, uint access)
    {
        IntPtr handle = CreateFile(
            path,
            access,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            IntPtr.Zero);
        if (handle == INVALID_HANDLE_VALUE)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read transcript staging identity.");
        }
        return handle;
    }

    private static string ReadIdentity(IntPtr handle)
    {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(handle, out information))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read transcript file identity.");
        }
        ulong index = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
        return information.VolumeSerialNumber.ToString("X8") + ":" + index.ToString("X16");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_DISPOSITION_INFO
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool DeleteFile;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        IntPtr file,
        out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(
        IntPtr file,
        int informationClass,
        ref FILE_DISPOSITION_INFO information,
        uint size);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}
'@
}

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
        $fullMessage = ([string]$result.Output).Trim()
        $message = Get-BoundedTranscriptDiagnostic -Text $fullMessage

        if ($fullMessage -match "Unsupported URL|Invalid URL") {
            throw "The YouTube link looks invalid. Please paste a normal youtube.com or youtu.be video link."
        }

        if ($fullMessage -match "Private video|Video unavailable|This video is unavailable|Sign in") {
            throw "This video is unavailable without login or cannot be accessed by yt-dlp."
        }

        if ($fullMessage -match "HTTP Error 429|Too Many Requests|rate.?limit") {
            throw "YouTube temporarily rate-limited requests. Wait a little and try again."
        }

        if ($fullMessage -match "HTTP Error|Unable to download|Temporary failure|timed out|network") {
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
        $hasTranscriptFormat = @($formats | Where-Object {
                $_ -and ([string]$_.ext).ToLowerInvariant() -in @("vtt", "srt")
            }).Count -gt 0
        if (-not $hasTranscriptFormat) {
            continue
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

function ConvertFrom-TranscriptUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Get-TranscriptNormalizationTerms {
    return @{
        KiraMuratova = ConvertFrom-TranscriptUtf8Bytes @(208,154,208,184,209,128,208,176,32,208,156,209,131,209,128,208,176,209,130,208,190,208,178,208,176)
        KireMuratovoy = ConvertFrom-TranscriptUtf8Bytes @(208,154,208,184,209,128,208,181,32,208,156,209,131,209,128,208,176,209,130,208,190,208,178,208,190,208,185)
        KirMuratovoyBad = ConvertFrom-TranscriptUtf8Bytes @(208,186,208,184,209,128,208,188,209,131,209,128,208,176,209,130,208,190,208,178,208,190,208,185)
        Kir = ConvertFrom-TranscriptUtf8Bytes @(208,186,208,184,209,128)
        Murat = ConvertFrom-TranscriptUtf8Bytes @(208,188,209,131,209,128,208,176,209,130)
        MuratovoySuffix = ConvertFrom-TranscriptUtf8Bytes @(208,190,208,178,208,190,208,185)
        Redimag = ConvertFrom-TranscriptUtf8Bytes @(209,128,208,181,208,180,208,184,208,188,208,176,208,179)
        FigmaStem = ConvertFrom-TranscriptUtf8Bytes @(209,132,208,184,208,179,208,188)
        EdWood = ConvertFrom-TranscriptUtf8Bytes @(208,173,208,180,32,208,146,209,131,208,180)
        EdwoodBad = ConvertFrom-TranscriptUtf8Bytes @(209,141,208,180,208,178,209,131,208,180)
        Karvaya = ConvertFrom-TranscriptUtf8Bytes @(208,186,208,176,209,128,208,178,208,176,209,143)
        WongKarWai = ConvertFrom-TranscriptUtf8Bytes @(208,146,208,190,208,189,208,179,32,208,154,208,176,209,128,45,208,178,208,176,208,185)
        FillerE = ConvertFrom-TranscriptUtf8Bytes @(209,141)
        FillerA = ConvertFrom-TranscriptUtf8Bytes @(208,176)
        FillerM = ConvertFrom-TranscriptUtf8Bytes @(208,188)
    }
}

function Normalize-TranscriptLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $terms = Get-TranscriptNormalizationTerms
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
    $muratovoySuffix = [regex]::Escape($terms.MuratovoySuffix)
    $kirMuratovoyBad = [regex]::Escape($terms.KirMuratovoyBad)
    $line = $line -replace "(?i)\b$kirMuratovoyBad\b", $terms.KireMuratovoy
    $line = $line -replace "(?i)\b($kir\s*$murat\w*|$kir$murat\w*)$muratovoySuffix\b", $terms.KireMuratovoy
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

function Format-CleanTranscriptText {
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

function Get-TranscriptReviewText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CleanPath
    )

    $terms = Get-TranscriptNormalizationTerms
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

    return (($lines -join [System.Environment]::NewLine) + [System.Environment]::NewLine)
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
    $inDocumentHeader = $true

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

        if ($inDocumentHeader -and $rawLine -match '^\s*(?:WEBVTT(?:\s.*)?|Kind:.*|Language:.*)\s*$') {
            continue
        }

        $inDocumentHeader = $false

        if ($atCueBoundary -and $rawLine -match '^\s*(NOTE|STYLE|REGION)(?:\s|$)') {
            $block = $Matches[1]
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
        $line = $line -replace '>>', ''
        $line = $line -replace ([char]0x00A0), ' '
        $line = $line -replace '\[.*?\]', ''
        $line = $line.Trim()

        if ($TranscriptMode) {
            $line = Normalize-TranscriptLine -Line $line
        }

        if ($line -and $line -ne $prev) {
            $prev = $line
            $lines.Add($line)
        }

        $atCueBoundary = $false
    }

    $text = ($lines -join ' ')
    $text = $text -replace '\s{2,}', ' '
    $text = $text -replace '\s+([.,!?;:])', '$1'
    $text = $text -replace '([(\[{])\s+', '$1'
    $text = $text -replace '\s+([)\]}])', '$1'
    $text = $text.Trim()

    if (-not $text) {
        throw "Subtitle file did not contain readable transcript text."
    }

    if ($TranscriptMode) {
        return Format-CleanTranscriptText -Text $text
    }

    $sentences = @([regex]::Split($text, '(?<=[.!?])\s+') | Where-Object { $_.Trim() })
    return Format-TranscriptParagraphs -Sentences $sentences
}

function New-TranscriptOperationId {
    param([string]$OperationId)

    if (-not $OperationId) {
        return [Guid]::NewGuid().ToString("N")
    }

    if ($OperationId -notmatch '^[0-9a-fA-F]{32}$') {
        throw "Transcript operation id must be a 32-character GUID."
    }

    return $OperationId.ToLowerInvariant()
}

function Get-TranscriptOperationStagingRoot {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    Join-Path $OutputDir (".youtube-transcript-operation-" + $OperationId)
}

function Remove-TranscriptPublicationArtifacts {
    param([Parameter(Mandatory = $true)][string]$PublicationDirectory)

    if (-not (Test-Path -LiteralPath $PublicationDirectory)) {
        return
    }

    $commitPath = Join-Path $PublicationDirectory "commit.marker"
    $manifestPath = Join-Path $PublicationDirectory "manifest.json"
    if (-not (Test-Path -LiteralPath $commitPath) -and (Test-Path -LiteralPath $manifestPath)) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($entry in @($manifest.Entries)) {
            if ($entry.TargetPath -and $entry.Identity) {
                [void][TranscriptFileCleanupTools]::DeleteIfIdentityMatches(
                    [string]$entry.TargetPath,
                    [string]$entry.Identity
                )
            }
        }
    }

    Remove-Item -LiteralPath $PublicationDirectory -Recurse -Force -ErrorAction Stop
}

function Remove-TranscriptOperationStagingRoot {
    param([Parameter(Mandatory = $true)][string]$StagingRoot)

    if (-not (Test-Path -LiteralPath $StagingRoot)) {
        return
    }

    foreach ($publication in @(Get-ChildItem -LiteralPath $StagingRoot -Directory -Filter "publication-*" -ErrorAction Stop)) {
        Remove-TranscriptPublicationArtifacts -PublicationDirectory $publication.FullName
    }
    Remove-Item -LiteralPath $StagingRoot -Recurse -Force -ErrorAction Stop
}

function Close-TranscriptOutputReservation {
    param(
        [Parameter(Mandatory = $true)][object]$Reservation,
        [bool]$DeleteFiles
    )

    $cleanupError = $null
    try {
        if ($Reservation.StageDirectory -and (Test-Path -LiteralPath $Reservation.StageDirectory)) {
            Remove-TranscriptPublicationArtifacts -PublicationDirectory $Reservation.StageDirectory
        }
    }
    catch {
        $cleanupError = $_
    }
    finally {
        if ($Reservation.LockStream) {
            try { $Reservation.LockStream.Dispose() }
            catch { if (-not $cleanupError) { $cleanupError = $_ } }
        }
    }

    if ($cleanupError) { throw $cleanupError }
}

function New-TranscriptOutputReservation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [Parameter(Mandatory = $true)]
        [string]$Stem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ArtifactSuffixes,

        [Parameter(Mandatory = $true)]
        [string]$OperationId
    )

    $suffixes = @($ArtifactSuffixes | Select-Object -Unique)
    $stagingRoot = Get-TranscriptOperationStagingRoot -OutputDir $OutputDir -OperationId $OperationId
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    for ($index = 1; $true; $index++) {
        $candidateName = if ($index -eq 1) { $Stem } else { "$Stem-$index" }
        $candidateStem = Join-Path $OutputDir $candidateName
        $lockName = ".youtube-transcript-lock-{0}.tmp" -f (New-SafeFilePart -Value $candidateName)
        $lockPath = Join-Path $OutputDir $lockName
        $lockStream = $null

        try {
            $lockStream = [TranscriptFileCleanupTools]::OpenDeleteOnCloseLock($lockPath)
        }
        catch [System.IO.IOException] {
            $nativeError = $_.Exception.HResult -band 0xFFFF
            if ($nativeError -in 80, 183) { continue }
            throw
        }

        $collision = @($suffixes | Where-Object { Test-Path -LiteralPath "$candidateStem$_" }).Count -gt 0
        if ($collision) {
            $lockStream.Dispose()
            continue
        }

        $stageDirectory = Join-Path $stagingRoot ("publication-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $stageDirectory -ErrorAction Stop | Out-Null
        $entries = New-Object System.Collections.Generic.List[object]
        $entryIndex = 0
        foreach ($suffix in $suffixes) {
            $entries.Add([pscustomobject]@{
                    Suffix = [string]$suffix
                    TargetPath = "$candidateStem$suffix"
                    StagePath = Join-Path $stageDirectory ("artifact-{0:D2}.stage" -f $entryIndex)
                })
            $entryIndex++
        }
        return [pscustomobject]@{
            StemPath = $candidateStem
            Entries = $entries.ToArray()
            LockStream = $lockStream
            StageDirectory = $stageDirectory
            ManifestPath = Join-Path $stageDirectory "manifest.json"
            CommitPath = Join-Path $stageDirectory "commit.marker"
        }
    }
}

function Get-TranscriptReservationEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Reservation,

        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    $entry = $Reservation.Entries |
        Where-Object { [string]$_.Suffix -eq $Suffix } |
        Select-Object -First 1
    if (-not $entry) {
        throw "The output reservation does not contain suffix '$Suffix'."
    }

    return $entry
}

function Write-TranscriptReservationText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Reservation,

        [Parameter(Mandatory = $true)]
        [string]$Suffix,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $entry = Get-TranscriptReservationEntry -Reservation $Reservation -Suffix $Suffix
    [System.IO.File]::WriteAllText(
        [string]$entry.StagePath,
        $Text,
        (New-Object System.Text.UTF8Encoding($true))
    )
}

function Copy-TranscriptFileToReservation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Reservation,

        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    $entry = Get-TranscriptReservationEntry -Reservation $Reservation -Suffix $Suffix
    [System.IO.File]::Copy($Path, [string]$entry.StagePath, $false)
}

function Publish-TranscriptOutputReservation {
    param(
        [Parameter(Mandatory = $true)][object]$Reservation,
        [scriptblock]$OnArtifactPublished
    )

    $manifestEntries = @(
        foreach ($entry in @($Reservation.Entries)) {
            if (-not (Test-Path -LiteralPath $entry.StagePath)) {
                throw "Transcript staging artifact is missing: $($entry.StagePath)"
            }
            [pscustomobject]@{
                TargetPath = [string]$entry.TargetPath
                Identity = [TranscriptFileCleanupTools]::GetIdentity([string]$entry.StagePath)
            }
        }
    )
    $manifestTemp = "$($Reservation.ManifestPath).tmp"
    [System.IO.File]::WriteAllText(
        $manifestTemp,
        ([pscustomobject]@{ Version = 1; Entries = $manifestEntries } | ConvertTo-Json -Depth 4),
        (New-Object System.Text.UTF8Encoding($true))
    )
    [System.IO.File]::Move($manifestTemp, [string]$Reservation.ManifestPath)

    $publishedCount = 0
    foreach ($entry in @($Reservation.Entries)) {
        [System.IO.File]::Move([string]$entry.StagePath, [string]$entry.TargetPath)
        $publishedCount++
        if ($OnArtifactPublished) {
            & $OnArtifactPublished $publishedCount $entry | Out-Null
        }
    }
    [System.IO.File]::WriteAllText([string]$Reservation.CommitPath, "committed")
}

function Save-TranscriptFromSubtitleFileAtReservation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Reservation,

        [bool]$CleanTranscript
    )

    $textSuffix = if ($CleanTranscript) {
        ".clean.txt"
    }
    else {
        ".txt"
    }

    $textPath = "$($Reservation.StemPath)$textSuffix"
    $text = Convert-SubtitleFileToTranscriptText -Path $Path -TranscriptMode:$CleanTranscript
    Write-TranscriptReservationText `
        -Reservation $Reservation `
        -Suffix $textSuffix `
        -Text ($text + [System.Environment]::NewLine)

    $reviewPath = $null
    if ($CleanTranscript) {
        $reviewPath = "$($Reservation.StemPath).review.txt"
        Write-TranscriptReservationText `
            -Reservation $Reservation `
            -Suffix ".review.txt" `
            -Text (Get-TranscriptReviewText -CleanPath $textPath)
    }

    return [pscustomobject]@{
        TextPath = $textPath
        ReviewPath = $reviewPath
    }
}

function Save-TranscriptFromSubtitleFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [bool]$CleanTranscript,

        [string]$OperationId
    )

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $operation = New-TranscriptOperationId -OperationId $OperationId
    $sourceStem = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $Path))
    $artifactSuffixes = if ($CleanTranscript) {
        @(".clean.txt", ".review.txt")
    }
    else {
        @(".txt")
    }
    $reservation = New-TranscriptOutputReservation `
        -OutputDir $OutputDir `
        -Stem $sourceStem `
        -ArtifactSuffixes $artifactSuffixes `
        -OperationId $operation

    $succeeded = $false
    try {
        $result = Save-TranscriptFromSubtitleFileAtReservation `
            -Path $Path `
            -Reservation $reservation `
            -CleanTranscript $CleanTranscript
        Publish-TranscriptOutputReservation -Reservation $reservation
        $succeeded = $true
        return $result
    }
    finally {
        Close-TranscriptOutputReservation `
            -Reservation $reservation `
            -DeleteFiles (-not $succeeded)
        $stagingRoot = Get-TranscriptOperationStagingRoot -OutputDir $OutputDir -OperationId $operation
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-TranscriptOperationStagingRoot -StagingRoot $stagingRoot
        }
    }
}

function Get-CliSubtitleLanguageTags {
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

function Resolve-CliPreferredLanguage {
    param(
        [AllowNull()]
        [string]$Language
    )

    if ($Language -match '^ru') {
        return "ru"
    }

    if ($Language -match '^en') {
        return "en"
    }

    if ($Language -match '^de') {
        return "de"
    }

    return $null
}

function Get-CliVideoLanguage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$YtDlpPath,

        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $result = Invoke-TranscriptProcess -FilePath $YtDlpPath -ArgumentList @(
            "--skip-download", "--print", "%(language)s", $Url
        )

        if ($result.ExitCode -eq 0) {
            $language = @($result.StdOut -split '[\r\n]+' | Where-Object { $_ } | Select-Object -First 1)[0]
            if ($language -and $language -ne "NA") {
                return $language.Trim().ToLowerInvariant()
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-CliSubtitleLanguagePlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Preference,

        [string]$SubtitleLanguages,

        [Parameter(Mandatory = $true)]
        [string]$YtDlpPath
    )

    if ($SubtitleLanguages) {
        $preferred = if ($Preference -ne "auto") { $Preference } else { $null }
        return [pscustomobject]@{
            Attempts = @($SubtitleLanguages)
            PreferredLanguage = $preferred
        }
    }

    if ($Preference -ne "auto") {
        return [pscustomobject]@{
            Attempts = @(Get-CliSubtitleLanguageTags -Language $Preference)
            PreferredLanguage = $Preference
        }
    }

    $detected = Resolve-CliPreferredLanguage -Language (Get-CliVideoLanguage -YtDlpPath $YtDlpPath -Url $Url)
    $languages = New-Object System.Collections.Generic.List[string]
    if ($detected) {
        $languages.Add($detected)
    }

    foreach ($fallback in @("ru", "en", "de")) {
        if (-not $languages.Contains($fallback)) {
            $languages.Add($fallback)
        }
    }

    $attempts = @(
        foreach ($language in $languages) {
            Get-CliSubtitleLanguageTags -Language $language
        }
    )

    return [pscustomobject]@{
        Attempts = $attempts
        PreferredLanguage = $detected
    }
}

function Get-CliSubtitlePriority {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [AllowNull()]
        [string]$PreferredLanguage
    )

    $name = $File.Name.ToLowerInvariant()
    $priority = if ($PreferredLanguage -eq "en") {
        @("en-orig", "en", "ru", "ru-orig", "de-orig", "de")
    }
    elseif ($PreferredLanguage -eq "ru") {
        @("ru-orig", "ru", "en", "en-orig", "de-orig", "de")
    }
    elseif ($PreferredLanguage -eq "de") {
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

function Select-CliPreferredSubtitleFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$Subtitles,

        [AllowNull()]
        [string]$PreferredLanguage
    )

    return $Subtitles |
        Sort-Object `
            @{ Expression = { Get-CliSubtitlePriority -File $_ -PreferredLanguage $PreferredLanguage }; Ascending = $true },
            @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true } |
        Select-Object -First 1
}

function Get-BoundedTranscriptDiagnostic {
    param(
        [AllowNull()]
        [string]$Text,

        [int]$MaximumLength = 2000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $diagnostic = $Text.Trim()
    if ($diagnostic.Length -le $MaximumLength) {
        return $diagnostic
    }

    return $diagnostic.Substring($diagnostic.Length - $MaximumLength)
}

function Save-TranscriptFromYoutubeCli {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [Parameter(Mandatory = $true)]
        [string]$Preference,

        [string]$SubtitleLanguages,

        [bool]$NoClean,

        [bool]$KeepSubtitles,

        [bool]$Srt,

        [bool]$CleanTranscript,

        [string]$YtDlpPath,

        [scriptblock]$OnAttempt,

        [string]$OperationId
    )

    $tool = Get-YtDlpPath -PreferredPath $YtDlpPath
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $operation = New-TranscriptOperationId -OperationId $OperationId

    $plan = Get-CliSubtitleLanguagePlan `
        -Url $Url `
        -Preference $Preference `
        -SubtitleLanguages $SubtitleLanguages `
        -YtDlpPath $tool

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("youtube-transcript-cli-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $downloadedSubtitles = @()
    $lastExitCode = 0
    $lastOutput = ""
    $lastStdErr = ""

    try {
        for ($attemptIndex = 0; $attemptIndex -lt $plan.Attempts.Count; $attemptIndex++) {
            $subtitleLanguages = $plan.Attempts[$attemptIndex]
            $attemptDir = Join-Path $tempDir ("attempt-{0:D2}" -f $attemptIndex)
            New-Item -ItemType Directory -Path $attemptDir -Force | Out-Null

            if ($OnAttempt) {
                & $OnAttempt $subtitleLanguages | Out-Null
            }

            $arguments = @(
                "--skip-download",
                "--write-subs",
                "--write-auto-subs",
                "--sub-langs", $subtitleLanguages
            )

            if ($Srt) {
                $arguments += @("--sub-format", "srt/best", "--convert-subs", "srt")
            }
            else {
                $arguments += @("--sub-format", "vtt/best")
            }

            $arguments += @(
                "-o", (Join-Path $attemptDir "%(title)s [%(id)s].%(ext)s"),
                $Url
            )

            $downloadResult = Invoke-TranscriptProcess `
                -FilePath $tool `
                -ArgumentList $arguments `
                -WorkingDirectory $attemptDir
            $lastExitCode = $downloadResult.ExitCode
            $lastOutput = Get-BoundedTranscriptDiagnostic -Text ([string]$downloadResult.Output)
            $lastStdErr = Get-BoundedTranscriptDiagnostic -Text ([string]$downloadResult.StdErr)
            $downloadedSubtitles = @(Get-ChildItem -LiteralPath $attemptDir -File |
                Where-Object { $_.Extension -in ".vtt", ".srt" })

            if ($downloadedSubtitles.Count -gt 0) {
                break
            }
        }

        if ($downloadedSubtitles.Count -eq 0) {
            return [pscustomobject]@{
                TextPath = $null
                ReviewPath = $null
                SubtitlePaths = @()
                OutputDir = $OutputDir
                FoundSubtitles = $false
                ExitCode = if ($NoClean) { $lastExitCode } else { 1 }
                YtDlpExitCode = $lastExitCode
                Output = $lastOutput
                StdErr = $lastStdErr
            }
        }

        if ($NoClean) {
            $subtitlePaths = New-Object System.Collections.Generic.List[string]
            $subtitleGroups = $downloadedSubtitles |
                Group-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
            foreach ($subtitleGroup in $subtitleGroups) {
                $relatedSubtitles = @($subtitleGroup.Group)
                $relatedSuffixes = @($relatedSubtitles |
                    ForEach-Object { $_.Extension } |
                    Select-Object -Unique)
                $reservation = New-TranscriptOutputReservation `
                    -OutputDir $OutputDir `
                    -Stem ([string]$subtitleGroup.Name) `
                    -ArtifactSuffixes $relatedSuffixes `
                    -OperationId $operation
                $groupSucceeded = $false
                try {
                    foreach ($subtitle in $relatedSubtitles) {
                        Copy-TranscriptFileToReservation `
                            -Path $subtitle.FullName `
                            -Reservation $reservation `
                            -Suffix $subtitle.Extension
                        $subtitlePaths.Add("$($reservation.StemPath)$($subtitle.Extension)")
                    }
                    Publish-TranscriptOutputReservation -Reservation $reservation
                    $groupSucceeded = $true
                }
                finally {
                    Close-TranscriptOutputReservation `
                        -Reservation $reservation `
                        -DeleteFiles (-not $groupSucceeded)
                }
            }

            return [pscustomobject]@{
                TextPath = $null
                ReviewPath = $null
                SubtitlePaths = $subtitlePaths.ToArray()
                OutputDir = $OutputDir
                FoundSubtitles = $true
                ExitCode = 0
                YtDlpExitCode = $lastExitCode
                Output = $lastOutput
                StdErr = $lastStdErr
            }
        }

        $selected = Select-CliPreferredSubtitleFile `
            -Subtitles $downloadedSubtitles `
            -PreferredLanguage $plan.PreferredLanguage
        $selectedStem = [System.IO.Path]::GetFileNameWithoutExtension($selected.Name)
        $artifactSuffixes = @(
            if ($CleanTranscript) {
                ".clean.txt"
                ".review.txt"
            }
            else {
                ".txt"
            }
        )
        if ($KeepSubtitles) {
            $artifactSuffixes += $selected.Extension
        }

        $reservation = New-TranscriptOutputReservation `
            -OutputDir $OutputDir `
            -Stem $selectedStem `
            -ArtifactSuffixes $artifactSuffixes `
            -OperationId $operation
        $reservationSucceeded = $false
        try {
            $saved = Save-TranscriptFromSubtitleFileAtReservation `
                -Path $selected.FullName `
                -Reservation $reservation `
                -CleanTranscript $CleanTranscript
            $subtitlePaths = @()

            if ($KeepSubtitles) {
                $destination = "$($reservation.StemPath)$($selected.Extension)"
                Copy-TranscriptFileToReservation `
                    -Path $selected.FullName `
                    -Reservation $reservation `
                    -Suffix $selected.Extension
                $subtitlePaths = @($destination)
            }
            Publish-TranscriptOutputReservation -Reservation $reservation
            $reservationSucceeded = $true
        }
        finally {
            Close-TranscriptOutputReservation `
                -Reservation $reservation `
                -DeleteFiles (-not $reservationSucceeded)
        }

        return [pscustomobject]@{
            TextPath = $saved.TextPath
            ReviewPath = $saved.ReviewPath
            SubtitlePaths = $subtitlePaths
            OutputDir = $OutputDir
            FoundSubtitles = $true
            ExitCode = 0
            YtDlpExitCode = $lastExitCode
            Output = $lastOutput
            StdErr = $lastStdErr
        }
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        $stagingRoot = Get-TranscriptOperationStagingRoot -OutputDir $OutputDir -OperationId $operation
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-TranscriptOperationStagingRoot -StagingRoot $stagingRoot
        }
    }
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

        [scriptblock]$OnStatus,

        [string]$OperationId
    )

    if (-not (Test-YoutubeUrl -Url $Url)) {
        throw "The link does not look like a YouTube video URL."
    }

    $tool = Get-YtDlpPath -PreferredPath $YtDlpPath
    $operation = New-TranscriptOperationId -OperationId $OperationId

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

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("youtube-transcript-tool-" + $operation)
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
            $fullMessage = ([string]$downloadOutput).Trim()
            $message = Get-BoundedTranscriptDiagnostic -Text $fullMessage

            if ($fullMessage -match "HTTP Error 429|Too Many Requests|rate.?limit") {
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
        $outputStemName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $artifactSuffixes = @(".txt")
        if ($KeepSubtitles) {
            $artifactSuffixes += $subtitleFile.Extension
        }

        $reservation = New-TranscriptOutputReservation `
            -OutputDir $OutputDir `
            -Stem $outputStemName `
            -ArtifactSuffixes $artifactSuffixes `
            -OperationId $operation
        $reservationSucceeded = $false
        try {
            $txtPath = "$($reservation.StemPath).txt"
            $text = Convert-SubtitleFileToTranscriptText -Path $subtitleFile.FullName
            Write-TranscriptReservationText `
                -Reservation $reservation `
                -Suffix ".txt" `
                -Text ($text + [System.Environment]::NewLine)

            $subtitlePath = $null
            if ($KeepSubtitles) {
                $subtitlePath = "$($reservation.StemPath)$($subtitleFile.Extension)"
                Copy-TranscriptFileToReservation `
                    -Path $subtitleFile.FullName `
                    -Reservation $reservation `
                    -Suffix $subtitleFile.Extension
            }
            Publish-TranscriptOutputReservation -Reservation $reservation
            $reservationSucceeded = $true
        }
        finally {
            Close-TranscriptOutputReservation `
                -Reservation $reservation `
                -DeleteFiles (-not $reservationSucceeded)
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
        $stagingRoot = Get-TranscriptOperationStagingRoot -OutputDir $OutputDir -OperationId $operation
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-TranscriptOperationStagingRoot -StagingRoot $stagingRoot
        }
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
    "Save-TranscriptFromSubtitleFile",
    "Save-TranscriptFromYoutubeCli",
    "Save-TranscriptFromYoutube"
)
