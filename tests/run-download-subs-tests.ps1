param(
    [string]$Filter = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptUnderTest = Join-Path $repoRoot "download-subs.ps1"
$moduleUnderTest = Join-Path $repoRoot "transcript-tool.psm1"

function New-FakeExe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    Add-Type -TypeDefinition $Source -OutputAssembly $Path -OutputType ConsoleApplication
}

function New-TestWorkspace {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("download-subs-tests-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -LiteralPath $scriptUnderTest -Destination (Join-Path $dir "download-subs.ps1")
    Copy-Item -LiteralPath $moduleUnderTest -Destination (Join-Path $dir "transcript-tool.psm1")

    $ytDlpSource = @'
using System;
using System.IO;
using System.Linq;
using System.Text;

public class Program {
    private static void LogInvocation(string[] args) {
        var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "yt-dlp-invocations.txt");
        using (var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
        using (var writer = new StreamWriter(stream, new UTF8Encoding(false))) {
            writer.WriteLine(String.Join("|", args));
        }
    }

    private static string GetOutputDirectory(string[] args) {
        var outputIndex = Array.IndexOf(args, "-o");
        if (outputIndex < 0 || outputIndex + 1 >= args.Length) {
            return null;
        }

        return Path.GetDirectoryName(Path.GetFullPath(args[outputIndex + 1]));
    }

    private static void WriteSubtitle(string[] args, string name, string content) {
        var directory = GetOutputDirectory(args);
        if (directory == null) {
            return;
        }

        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, name), content, new UTF8Encoding(false));
    }

    private static string GetArgumentValue(string[] args, string name) {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : "";
    }

    public static int Main(string[] args) {
        var isolated = args.Length >= 2 && args[0] == "--ignore-config" && args[1] == "--no-plugin-dirs";
        LogInvocation(args);
        if (args.Contains("--version")) {
            if (!isolated) return 12;
            Console.WriteLine("2026.07.04");
            return 0;
        }

        var url = args.Length == 0 ? "" : args[args.Length - 1];
        if (args.Contains("--dump-single-json")) {
            if (!isolated) return 12;
            if (url.Contains("list-fixture")) {
                Console.WriteLine("{\"id\":\"list\",\"title\":\"List\",\"subtitles\":{\"en\":[{\"ext\":\"vtt\",\"url\":\"https://example.test/en.vtt\",\"protocol\":\"https\"}],\"live_chat\":[{\"ext\":\"vtt\",\"url\":\"https://example.test/chat.vtt\",\"protocol\":\"https\"}]},\"automatic_captions\":{\"en-orig\":[{\"ext\":\"vtt\",\"url\":\"https://example.test/en-auto.vtt\",\"protocol\":\"https\"}],\"ru\":[{\"ext\":\"vtt\",\"url\":\"https://example.test/ru.vtt\",\"protocol\":\"https\"}]},\"formats\":[{\"acodec\":\"opus\",\"language\":\"en\",\"language_preference\":10}]}");
                return 0;
            }
            if (url.Contains("automatic-warning")) {
                Console.WriteLine("{\"id\":\"automatic\",\"title\":\"Automatic\",\"subtitles\":{},\"automatic_captions\":{\"en-orig\":[{\"ext\":\"vtt\",\"url\":\"https://example.test/en-auto.vtt\",\"protocol\":\"https\"}],\"ru\":[{\"ext\":\"vtt\",\"url\":\"https://example.test/ru.vtt\",\"protocol\":\"https\"}]},\"formats\":[{\"acodec\":\"opus\",\"language\":\"en\",\"language_preference\":10}]}");
                return 0;
            }

            var language = url.Contains("german-video") || url.Contains("prefer-german") ? "de" : (url.Contains("option-run") ? "custom-lang" : "en");
            Console.WriteLine("{\"id\":\"fixture\",\"title\":\"Fixture\",\"subtitles\":{\"" + language + "\":[{\"ext\":\"vtt\",\"url\":\"https://example.test/manual.vtt\",\"protocol\":\"https\"}]},\"automatic_captions\":{},\"formats\":[{\"acodec\":\"opus\",\"language\":\"" + language + "\",\"language_preference\":10}]}");
            return 0;
        }

        if (args.Contains("--print")) {
            var printUrl = args.Length == 0 ? "" : args[args.Length - 1];
            if (printUrl.Contains("unknown-language")) {
                Console.WriteLine("NA");
                return 0;
            }

            if (printUrl.Contains("german-video")) {
                Console.WriteLine("de");
                return 0;
            }

            Console.WriteLine("en");
            return 0;
        }

        if (args.Contains("--list-subs")) {
            Console.WriteLine("en, ru");
            return 0;
        }

        if (url.Contains("all-attempts-fail")) {
            Console.Error.WriteLine("ERROR: synthetic all-attempt diagnostic");
            return 7;
        }

        if (url.Contains("downloaded-despite-error")) {
            WriteSubtitle(
                args,
                "Partial [partial].en.vtt",
                "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nPartial subtitle\n");
            Console.Error.WriteLine("ERROR: synthetic partial-download diagnostic");
            return 8;
        }

        if (url.Contains("option-run")) {
            var requestedLangs = GetArgumentValue(args, "--sub-langs");
            var isSrt = args.Contains("--convert-subs") && GetArgumentValue(args, "--convert-subs") == "srt";
            if (requestedLangs != "custom-lang" || !isSrt) {
                Console.Error.WriteLine("ERROR: option-run requires custom-lang and SRT");
                return 9;
            }

            WriteSubtitle(
                args,
                "Options [options].custom-lang.srt",
                "1\n00:00:00,000 --> 00:00:01,000\nOption subtitle\n");
            return 0;
        }

        if (url.Contains("existing")) {
            return 0;
        }

        if (url.Contains("fresh-concurrent")) {
            var marker = url.Contains("content=one") ? "FIRST-CLI-CONCURRENT" : "SECOND-CLI-CONCURRENT";
            var content = new StringBuilder("WEBVTT\n\n00:00:00.000 --> 00:30:00.000\n");
            for (var index = 0; index < 30000; index++) {
                content.Append(marker).Append(" ").Append(index).Append(".\n");
            }
            WriteSubtitle(args, "Concurrent [same].en.vtt", content.ToString());
            return 0;
        }

        if (url.Contains("fresh")) {
            WriteSubtitle(
                args,
                "Fresh [fresh].en.vtt",
                "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nFresh &amp; clean\n");
            return 0;
        }

        if (url.Contains("automatic-warning")) {
            WriteSubtitle(
                args,
                "Automatic [automatic].en-orig.vtt",
                "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nAutomatic subtitle\n");
            return 0;
        }

        if (url.Contains("unknown-language")) {
            var langIndex = Array.IndexOf(args, "--sub-langs");
            var requestedLangs = langIndex >= 0 && langIndex + 1 < args.Length ? args[langIndex + 1] : "";

            if (requestedLangs == "ru-orig" || requestedLangs == "ru") {
                WriteSubtitle(
                    args,
                    "Unknown [unknown-language].ru.vtt",
                    "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nRussian first\n");
            }

            return 0;
        }

        if (url.Contains("german-video")) {
            var langIndex = Array.IndexOf(args, "--sub-langs");
            var requestedLangs = langIndex >= 0 && langIndex + 1 < args.Length ? args[langIndex + 1] : "";

            if (requestedLangs == "de-orig" || requestedLangs == "de") {
                WriteSubtitle(
                    args,
                    "German [german-video].de.vtt",
                    "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nGuten Tag\n");
            }

            return 0;
        }

        if (url.Contains("prefer-german")) {
            var langIndex = Array.IndexOf(args, "--sub-langs");
            var requestedLangs = langIndex >= 0 && langIndex + 1 < args.Length ? args[langIndex + 1] : "";

            if (requestedLangs == "de-orig" || requestedLangs == "de") {
                WriteSubtitle(
                    args,
                    "Prefer German [prefer-german].de.vtt",
                    "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nNur Deutsch\n");
            }

            return 0;
        }

        return 1;
    }
}
'@

    $notepadSource = @'
public class Program {
    public static int Main(string[] args) {
        return 0;
    }
}
'@

    New-FakeExe -Path (Join-Path $dir "yt-dlp.exe") -Source $ytDlpSource
    New-FakeExe -Path (Join-Path $dir "notepad.exe") -Source $notepadSource

    return $dir
}

function Invoke-DownloadSubs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [string]$WorkingDirectory
    )

    if (-not $WorkingDirectory) {
        $WorkingDirectory = $Directory
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "powershell.exe"
    $psi.WorkingDirectory = $WorkingDirectory
    $escapedArgs = $Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }
    $psi.Arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"' + (Join-Path $Directory "download-subs.ps1") + '"')
    ) + $escapedArgs -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $originalPath = $env:PATH
    try {
        $env:PATH = $Directory + [System.IO.Path]::PathSeparator + $originalPath
        $process = [System.Diagnostics.Process]::Start($psi)
    }
    finally {
        $env:PATH = $originalPath
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
        Output = ($stdout + "`n" + $stderr)
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-BytesEqual {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Expected,

        [Parameter(Mandatory = $true)]
        [byte[]]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Assert-True ($Expected.Length -eq $Actual.Length) "$Message Expected $($Expected.Length) bytes, got $($Actual.Length)."
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        Assert-True ($Expected[$i] -eq $Actual[$i]) "$Message Byte $i changed from $($Expected[$i]) to $($Actual[$i])."
    }
}

function Utf8 {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Get-CliTestTemporaryDirectories {
    return @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter "youtube-transcript-cli-*" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName } |
        Sort-Object)
}

$tests = @(
    @{
        Name = "Original CLI rejects legacy language overrides before download"
        Run = {
            $dir = New-TestWorkspace
            try {
                foreach ($arguments in @(
                        @("https://example.test/fresh", "-Prefer", "ru"),
                        @("https://example.test/fresh", "-Langs", "en")
                    )) {
                    $result = Invoke-DownloadSubs -Directory $dir -Arguments $arguments
                    Assert-True ($result.ExitCode -ne 0) "Legacy language override unexpectedly succeeded."
                    Assert-True ($result.Output -match [regex]::Escape("-Prefer and -Langs are no longer supported. Online downloads always use the video's original language.")) "Expected bounded migration guidance, got: $($result.Output)"
                }
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Original CLI List uses isolated metadata classification without download"
        Run = {
            $dir = New-TestWorkspace
            try {
                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("-List", "https://example.test/list-fixture")
                Assert-True ($result.ExitCode -eq 0) "Expected successful metadata listing, got: $($result.Output)"
                foreach ($expected in @("en`tManual", "en-orig`tAutomaticOriginal", "ru`tAutomaticUntrusted", "live_chat`tExcludedService")) {
                    Assert-True ($result.Output -match [regex]::Escape($expected)) "Missing classified track '$expected': $($result.Output)"
                }

                $invocations = @(Get-Content -LiteralPath (Join-Path $dir "yt-dlp-invocations.txt"))
                Assert-True (@($invocations | Where-Object { $_ -match '--dump-single-json' }).Count -eq 1) "List did not use exactly one metadata probe."
                Assert-True (@($invocations | Where-Object { $_ -match '--write-(auto-)?subs' }).Count -eq 0) "List attempted a subtitle download."
                Assert-True (@($invocations | Where-Object { $_ -match '--list-subs' }).Count -eq 0) "List bypassed the managed metadata inventory."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Original CLI successful automatic captions emit accuracy warning with exit zero"
        Run = {
            $dir = New-TestWorkspace
            try {
                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("https://example.test/automatic-warning")
                Assert-True ($result.ExitCode -eq 0) "ASR warning was treated as a failure: $($result.Output)"
                Assert-True ($result.Output -match "ошибки распознавания") "Expected ASR accuracy warning, got: $($result.Output)"
                Assert-True (Test-Path -LiteralPath (Join-Path $dir "texts\Automatic [automatic].en.txt")) "Expected canonical ASR transcript filename."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Original CLI CleanOnly selects newest subtitle without language priority"
        Run = {
            $dir = New-TestWorkspace
            try {
                $older = Join-Path $dir "Older.en.vtt"
                $newer = Join-Path $dir "Newer.ja.vtt"
                Set-Content -LiteralPath $older -Encoding utf8 -Value "WEBVTT`n`n00:00:00.000 --> 00:00:01.000`nOLDER"
                Set-Content -LiteralPath $newer -Encoding utf8 -Value "WEBVTT`n`n00:00:00.000 --> 00:00:01.000`nNEWER"
                [System.IO.File]::SetLastWriteTimeUtc($older, [datetime]"2026-01-01T00:00:00Z")
                [System.IO.File]::SetLastWriteTimeUtc($newer, [datetime]"2026-01-02T00:00:00Z")

                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("-CleanOnly")
                Assert-True ($result.ExitCode -eq 0) "Expected CleanOnly success, got: $($result.Output)"
                Assert-True (Test-Path -LiteralPath (Join-Path $dir "texts\Newer.ja.txt")) "CleanOnly retained obsolete language priority."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "CleanOnly without subtitle files reports the intended error"
        Run = {
            $dir = New-TestWorkspace
            try {
                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("-CleanOnly")
                Assert-True ($result.ExitCode -ne 0) "Expected a non-zero exit code."
                Assert-True ($result.Output -match "No \.vtt or \.srt files were found") "Expected missing subtitle message, got: $($result.Output)"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "CleanOnly decodes common HTML entities through the platform decoder"
        Run = {
            $dir = New-TestWorkspace
            try {
                $subtitle = Join-Path $dir "Entities [entities].en.vtt"
                Set-Content -LiteralPath $subtitle -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    "Tom &amp; Jerry&nbsp;&quot;hi&quot;"
                )

                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("-CleanOnly")
                Assert-True ($result.ExitCode -eq 0) "Expected success, got: $($result.Output)"

                $txt = Join-Path $dir "texts\Entities [entities].en.txt"
                Assert-True (Test-Path -LiteralPath $txt) "Expected text file to be created."
                $content = Get-Content -LiteralPath $txt -Raw -Encoding utf8
                Assert-True ($content -match 'Tom & Jerry\s+"hi"') "Expected decoded text, got: $content"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "CleanOnly creates text without deleting its subtitle source"
        Run = {
            $dir = New-TestWorkspace
            try {
                $subtitle = Join-Path $dir "Preserved [preserved].en.vtt"
                Set-Content -LiteralPath $subtitle -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    "Keep this source"
                )

                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("-CleanOnly")
                Assert-True ($result.ExitCode -eq 0) "Expected success, got: $($result.Output)"
                Assert-True (Test-Path -LiteralPath $subtitle) "Expected CleanOnly to preserve its subtitle source."

                $txt = Join-Path $dir "texts\Preserved [preserved].en.txt"
                Assert-True (Test-Path -LiteralPath $txt) "Expected text file to be created."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "CleanTranscript creates editor-friendly transcript and review files"
        Run = {
            $dir = New-TestWorkspace
            try {
                $subtitle = Join-Path $dir "Transcript [transcript].ru-orig.vtt"
                Set-Content -LiteralPath $subtitle -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    (Utf8 @(209,141,32,209,129,208,176,208,185,209,130,32,208,190,32,208,154,208,184,209,128,208,188,209,131,209,128,208,176,209,130,208,190,208,178,208,190,208,185,32,208,180,208,181,208,187,208,176,208,187,208,184,32,208,178,32,208,160,208,181,208,180,208,184,208,188,208,176,208,179,208,190,208,188,32,208,184,32,209,132,208,184,208,179,208,188,208,176,46)),
                    "",
                    "00:00:01.000 --> 00:00:02.000",
                    (Utf8 @(86,80,32,208,176,208,189,208,184,208,188,208,176,209,134,208,184,209,143,32,208,184,32,71,73,32,209,141,208,186,209,129,208,191,208,190,209,128,209,130,46,32,208,173,209,130,208,190,32,208,178,209,130,208,190,209,128,208,190,208,185,32,209,129,208,188,209,139,209,129,208,187,208,190,208,178,208,190,208,185,32,208,177,208,187,208,190,208,186,46)),
                    "",
                    "00:00:02.000 --> 00:00:03.000",
                    (Utf8 @(208,148,208,176,208,187,209,140,209,136,208,181,32,208,179,208,190,208,178,208,190,209,128,208,184,208,188,32,208,191,209,128,208,190,32,208,173,208,180,208,178,209,131,208,180,32,208,184,32,208,154,208,176,209,128,208,178,208,176,209,143,46))
                )

                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("-CleanOnly", "-CleanTranscript")
                Assert-True ($result.ExitCode -eq 0) "Expected success, got: $($result.Output)"

                $clean = Join-Path $dir "texts\Transcript [transcript].ru-orig.clean.txt"
                $review = Join-Path $dir "texts\Transcript [transcript].ru-orig.review.txt"
                Assert-True (Test-Path -LiteralPath $clean) "Expected clean transcript file to be created."
                Assert-True (Test-Path -LiteralPath $review) "Expected review file to be created."

                $content = Get-Content -LiteralPath $clean -Raw -Encoding utf8
                Assert-True ($content -match [regex]::Escape((Utf8 @(208,154,208,184,209,128,208,181,32,208,156,209,131,209,128,208,176,209,130,208,190,208,178,208,190,208,185)))) "Expected Kire Muratovoy normalization, got: $content"
                Assert-True ($content -match "Readymag") "Expected Readymag normalization, got: $content"
                Assert-True ($content -match "Figma") "Expected Figma normalization, got: $content"
                Assert-True ($content -match "WebP") "Expected WebP normalization, got: $content"
                Assert-True ($content -match "GIF") "Expected GIF normalization, got: $content"
                Assert-True ($content -match [regex]::Escape((Utf8 @(208,173,208,180,32,208,146,209,131,208,180)))) "Expected Ed Wood normalization, got: $content"
                Assert-True ($content -match [regex]::Escape((Utf8 @(208,146,208,190,208,189,208,179,32,208,154,208,176,209,128,45,208,178,208,176,208,185)))) "Expected Wong Kar-wai normalization, got: $content"
                Assert-True ($content -match "`r?`n`r?`n") "Expected paragraph breaks, got: $content"
                $fillerPattern = '(^|\s)' + [regex]::Escape((Utf8 @(209,141))) + '(\s|$)'
                Assert-True ($content -notmatch $fillerPattern) "Expected standalone filler to be removed, got: $content"

                $reviewContent = Get-Content -LiteralPath $review -Raw -Encoding utf8
                Assert-True ($reviewContent -match "Readymag") "Expected review checklist, got: $reviewContent"
                Assert-True ($reviewContent -match [regex]::Escape((Utf8 @(208,154,208,184,209,128,208,176,32,208,156,209,131,209,128,208,176,209,130,208,190,208,178,208,176)))) "Expected review checklist, got: $reviewContent"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Online download preserves unrelated subtitles and converts only fresh output"
        Run = {
            $dir = New-TestWorkspace
            try {
                $first = Join-Path $dir "Unrelated First [old-1].en.vtt"
                $second = Join-Path $dir "Unrelated Second [old-2].en.vtt"
                Set-Content -LiteralPath $first -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    "Old first"
                )
                Set-Content -LiteralPath $second -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    "Old second"
                )
                (Get-Item -LiteralPath $first).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-2)
                (Get-Item -LiteralPath $second).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-1)

                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("https://example.test/fresh")
                Assert-True ($result.ExitCode -eq 0) "Expected success, got: $($result.Output)"
                Assert-True (Test-Path -LiteralPath $first) "Expected first unrelated subtitle to remain present."
                Assert-True (Test-Path -LiteralPath $second) "Expected second unrelated subtitle to remain present."

                $freshText = Join-Path $dir "texts\Fresh [fresh].en.txt"
                Assert-True (Test-Path -LiteralPath $freshText) "Expected only the fresh subtitle to be converted."
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $dir "texts\Unrelated First [old-1].en.txt"))) "Unexpected conversion of first unrelated subtitle."
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $dir "texts\Unrelated Second [old-2].en.txt"))) "Unexpected conversion of second unrelated subtitle."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Online download honors OutputDir when process working directory differs"
        Run = {
            $dir = New-TestWorkspace
            $workingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("download-subs-cwd-" + [System.Guid]::NewGuid().ToString("N"))
            $outputDir = Join-Path ([System.IO.Path]::GetTempPath()) ("download-subs-output-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $workingDir -Force | Out-Null

            try {
                $result = Invoke-DownloadSubs `
                    -Directory $dir `
                    -WorkingDirectory $workingDir `
                    -Arguments @("https://example.test/fresh", "-OutputDir", $outputDir)

                Assert-True ($result.ExitCode -eq 0) "Expected success, got: $($result.Output)"
                $txt = Join-Path $outputDir "Fresh [fresh].en.txt"
                Assert-True (Test-Path -LiteralPath $txt) "Expected text in the requested output directory."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
                Remove-Item -LiteralPath $workingDir -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $outputDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "NoClean honors Srt while preserving original-track subtitle collisions"
        Run = {
            $dir = New-TestWorkspace
            $outputDir = Join-Path $dir "custom-output"
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

            try {
                $oldBase = Join-Path $outputDir "Options [options].custom-lang.srt"
                $oldSecond = Join-Path $outputDir "Options [options].custom-lang-2.srt"
                $oldBaseBytes = [byte[]]@(41, 42, 43, 44)
                $oldSecondBytes = [byte[]]@(51, 52, 53, 54)
                [System.IO.File]::WriteAllBytes($oldBase, $oldBaseBytes)
                [System.IO.File]::WriteAllBytes($oldSecond, $oldSecondBytes)

                $result = Invoke-DownloadSubs `
                    -Directory $dir `
                    -Arguments @(
                        "https://example.test/option-run",
                        "-NoClean",
                        "-Srt",
                        "-OutputDir", $outputDir
                    )

                Assert-True ($result.ExitCode -eq 0) "Expected NoClean success, got: $($result.Output)"
                Assert-BytesEqual -Expected $oldBaseBytes -Actual ([System.IO.File]::ReadAllBytes($oldBase)) -Message "Existing base SRT changed."
                Assert-BytesEqual -Expected $oldSecondBytes -Actual ([System.IO.File]::ReadAllBytes($oldSecond)) -Message "Existing -2 SRT changed."

                $third = Join-Path $outputDir "Options [options].custom-lang-3.srt"
                Assert-True (Test-Path -LiteralPath $third) "Expected collision-safe -3 SRT output."
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $outputDir "Options [options].custom-lang-3.txt"))) "NoClean unexpectedly created text."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "KeepSubs coordinates transcript and subtitle collision suffixes"
        Run = {
            $dir = New-TestWorkspace
            $outputDir = Join-Path $dir "keep-output"
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

            try {
                $oldText = Join-Path $outputDir "Fresh [fresh].en.txt"
                $oldSecondSubtitle = Join-Path $outputDir "Fresh [fresh].en-2.vtt"
                $oldTextBytes = [byte[]]@(61, 62, 63, 64)
                $oldSecondSubtitleBytes = [byte[]]@(71, 72, 73, 74)
                [System.IO.File]::WriteAllBytes($oldText, $oldTextBytes)
                [System.IO.File]::WriteAllBytes($oldSecondSubtitle, $oldSecondSubtitleBytes)

                $result = Invoke-DownloadSubs `
                    -Directory $dir `
                    -Arguments @(
                        "https://example.test/fresh",
                        "-KeepSubs",
                        "-OutputDir", $outputDir
                    )

                Assert-True ($result.ExitCode -eq 0) "Expected KeepSubs success, got: $($result.Output)"
                Assert-BytesEqual -Expected $oldTextBytes -Actual ([System.IO.File]::ReadAllBytes($oldText)) -Message "Existing transcript changed. CLI output: $($result.Output)"
                Assert-BytesEqual -Expected $oldSecondSubtitleBytes -Actual ([System.IO.File]::ReadAllBytes($oldSecondSubtitle)) -Message "Existing -2 subtitle changed."
                Assert-True (Test-Path -LiteralPath (Join-Path $outputDir "Fresh [fresh].en-3.txt")) "Expected -3 transcript."
                Assert-True (Test-Path -LiteralPath (Join-Path $outputDir "Fresh [fresh].en-3.vtt")) "Expected coordinated -3 subtitle."
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $outputDir "Fresh [fresh].en.vtt"))) "KeepSubs wrote an unsuffixed subtitle beside an existing transcript."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Concurrent KeepSubs processes atomically coordinate transcript and subtitle stems"
        Run = {
            $dir = New-TestWorkspace
            $outputDir = Join-Path $dir "concurrent-output"
            $runnerPath = Join-Path $dir "concurrent-runner.ps1"
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            $processes = @()
            $gate = $null
            $beforeTemp = Get-CliTestTemporaryDirectories

            try {
                $oldText = Join-Path $outputDir "Concurrent [same].en.txt"
                $oldSubtitle = Join-Path $outputDir "Concurrent [same].en.vtt"
                $oldTextBytes = [byte[]]@(101, 102, 103, 104)
                $oldSubtitleBytes = [byte[]]@(111, 112, 113, 114)
                [System.IO.File]::WriteAllBytes($oldText, $oldTextBytes)
                [System.IO.File]::WriteAllBytes($oldSubtitle, $oldSubtitleBytes)

                Set-Content -LiteralPath $runnerPath -Encoding utf8 -Value @(
                    'param([string]$Directory64,[string]$Output64,[string]$Url64,[string]$GateName)',
                    '$ErrorActionPreference = "Stop"',
                    '$decode = { param($value) [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) }',
                    '$directory = & $decode $Directory64',
                    '$outputDir = & $decode $Output64',
                    '$url = & $decode $Url64',
                    '$gate = [System.Threading.EventWaitHandle]::OpenExisting($GateName)',
                    'try { [void]$gate.WaitOne() } finally { $gate.Dispose() }',
                    '$env:PATH = $directory + [System.IO.Path]::PathSeparator + $env:PATH',
                    'Set-Location -LiteralPath $directory',
                    '& (Join-Path $directory "download-subs.ps1") $url -KeepSubs -OutputDir $outputDir',
                    'exit $LASTEXITCODE'
                )
                $gateName = "Local\TranscriptAtomicCli-" + [Guid]::NewGuid().ToString("N")
                $gate = New-Object System.Threading.EventWaitHandle -ArgumentList @($false, [System.Threading.EventResetMode]::ManualReset, $gateName)
                $encode = {
                    param($value)
                    [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$value))
                }
                $urls = @(
                    "https://example.test/fresh-concurrent?content=one",
                    "https://example.test/fresh-concurrent?content=two"
                )
                for ($processIndex = 0; $processIndex -lt 2; $processIndex++) {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = "powershell.exe"
                    $psi.Arguments = @(
                        '-NoProfile',
                        '-ExecutionPolicy', 'Bypass',
                        '-File', ('"' + $runnerPath + '"'),
                        '-Directory64', (& $encode $dir),
                        '-Output64', (& $encode $outputDir),
                        '-Url64', (& $encode $urls[$processIndex]),
                        '-GateName', $gateName
                    ) -join ' '
                    $psi.UseShellExecute = $false
                    $psi.CreateNoWindow = $true
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError = $true
                    $processes += [System.Diagnostics.Process]::Start($psi)
                }

                [void]$gate.Set()
                for ($processIndex = 0; $processIndex -lt $processes.Count; $processIndex++) {
                    $process = $processes[$processIndex]
                    Assert-True ($process.WaitForExit(60000)) "Concurrent KeepSubs process $processIndex timed out."
                    $stdout = $process.StandardOutput.ReadToEnd()
                    $stderr = $process.StandardError.ReadToEnd()
                    Assert-True ($process.ExitCode -eq 0) "Concurrent KeepSubs process $processIndex failed: $stdout $stderr"
                }

                Assert-BytesEqual -Expected $oldTextBytes -Actual ([System.IO.File]::ReadAllBytes($oldText)) -Message "Concurrent KeepSubs changed the pre-existing transcript."
                Assert-BytesEqual -Expected $oldSubtitleBytes -Actual ([System.IO.File]::ReadAllBytes($oldSubtitle)) -Message "Concurrent KeepSubs changed the pre-existing subtitle."
                foreach ($suffix in 2, 3) {
                    $textPath = Join-Path $outputDir "Concurrent [same].en-$suffix.txt"
                    $subtitlePath = Join-Path $outputDir "Concurrent [same].en-$suffix.vtt"
                    Assert-True (Test-Path -LiteralPath $textPath) "Missing concurrent transcript suffix -$suffix."
                    Assert-True (Test-Path -LiteralPath $subtitlePath) "Missing coordinated subtitle suffix -$suffix."
                    $textContent = Get-Content -LiteralPath $textPath -Raw -Encoding utf8
                    $subtitleContent = Get-Content -LiteralPath $subtitlePath -Raw -Encoding utf8
                    $marker = if ($textContent -match "FIRST-CLI-CONCURRENT") { "FIRST-CLI-CONCURRENT" } elseif ($textContent -match "SECOND-CLI-CONCURRENT") { "SECOND-CLI-CONCURRENT" } else { "" }
                    Assert-True ([bool]$marker) "Concurrent transcript -$suffix has no invocation marker."
                    Assert-True ($subtitleContent -match $marker) "Transcript/subtitle suffix -$suffix came from different invocations."
                }
                $combinedText = @(
                    Get-Content -LiteralPath (Join-Path $outputDir "Concurrent [same].en-2.txt") -Raw -Encoding utf8
                    Get-Content -LiteralPath (Join-Path $outputDir "Concurrent [same].en-3.txt") -Raw -Encoding utf8
                ) -join "`n"
                Assert-True ($combinedText -match "FIRST-CLI-CONCURRENT") "First concurrent CLI content was lost."
                Assert-True ($combinedText -match "SECOND-CLI-CONCURRENT") "Second concurrent CLI content was lost."
                $outputFiles = @(Get-ChildItem -LiteralPath $outputDir -File)
                Assert-True ($outputFiles.Count -eq 6) "Concurrent KeepSubs left unexpected reservation files: $($outputFiles.Name -join ', ')"
                Assert-True (@($outputFiles | Where-Object Length -eq 0).Count -eq 0) "Concurrent KeepSubs left zero-byte reservations."
            }
            finally {
                if ($gate) { $gate.Dispose() }
                foreach ($process in $processes) {
                    if ($process -and -not $process.HasExited) { $process.Kill() }
                    if ($process) { $process.Dispose() }
                }
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }

            $afterTemp = Get-CliTestTemporaryDirectories
            Assert-True (($beforeTemp -join '|') -eq ($afterTemp -join '|')) "Concurrent KeepSubs leaked CLI temporary workspaces."
        }
    },
    @{
        Name = "All failed attempts print the last yt-dlp diagnostic"
        Run = {
            $dir = New-TestWorkspace
            try {
                $result = Invoke-DownloadSubs `
                    -Directory $dir `
                    -Arguments @("https://example.test/all-attempts-fail")

                Assert-True ($result.ExitCode -eq 1) "Expected normal-mode no-subtitle exit 1, got $($result.ExitCode): $($result.Output)"
                Assert-True ($result.Output -match "synthetic all-attempt diagnostic") "Expected preserved failure diagnostic, got: $($result.Output)"
                Assert-True ($result.Output -match "No verified original subtitle track") "Expected original-track guidance, got: $($result.Output)"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Downloaded-despite-error warning includes yt-dlp diagnostic"
        Run = {
            $dir = New-TestWorkspace
            try {
                $result = Invoke-DownloadSubs `
                    -Directory $dir `
                    -Arguments @("https://example.test/downloaded-despite-error")

                Assert-True ($result.ExitCode -eq 0) "Expected downloaded subtitle to be converted, got: $($result.Output)"
                Assert-True ($result.Output -match "yt-dlp reported an error") "Expected downloaded-despite-error warning, got: $($result.Output)"
                Assert-True ($result.Output -match "synthetic partial-download diagnostic") "Expected warning diagnostic, got: $($result.Output)"
                Assert-True (Test-Path -LiteralPath (Join-Path $dir "texts\Partial [partial].en.txt")) "Expected partial subtitle transcript."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Original-only mode does not fall back after the selected track is absent"
        Run = {
            $dir = New-TestWorkspace
            try {
                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("https://example.test/unknown-language")
                Assert-True ($result.ExitCode -eq 1) "Missing selected track unexpectedly fell back: $($result.Output)"
                Assert-True ($result.Output -match "No verified original subtitle track") "Expected original-only failure guidance, got: $($result.Output)"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Original-only mode downloads the confirmed German manual track"
        Run = {
            $dir = New-TestWorkspace
            try {
                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("https://example.test/german-video")
                Assert-True ($result.ExitCode -eq 0) "Expected success, got: $($result.Output)"
                $txt = Join-Path $dir "texts\German [german-video].de.txt"
                Assert-True (Test-Path -LiteralPath $txt) "Expected German subtitle text to be created."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Legacy explicit German preference is rejected"
        Run = {
            $dir = New-TestWorkspace
            try {
                $result = Invoke-DownloadSubs -Directory $dir -Arguments @("https://example.test/prefer-german", "-Prefer", "de")
                Assert-True ($result.ExitCode -ne 0) "Legacy language preference unexpectedly succeeded."
                Assert-True ($result.Output -match "no longer supported") "Expected migration guidance, got: $($result.Output)"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }
)

$selectedTests = @(
    if ($Filter) {
        $tests | Where-Object { $_.Name -like "*$Filter*" }
    }
    else {
        $tests
    }
)

if ($selectedTests.Count -eq 0) {
    throw "No tests matched filter '$Filter'."
}

$failed = 0
$passed = 0

foreach ($test in $selectedTests) {
    try {
        & $test.Run
        $passed++
        Write-Host "PASS $($test.Name)"
    }
    catch {
        $failed++
        Write-Host "FAIL $($test.Name)"
        Write-Host $_.Exception.Message
    }
}

if ($failed -gt 0) {
    throw "$failed test(s) failed."
}

Write-Host "$passed/$($selectedTests.Count) CLI tests passed."
