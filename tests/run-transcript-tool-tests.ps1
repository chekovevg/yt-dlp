param(
    [string]$Filter = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot "transcript-tool.psm1"
Import-Module $modulePath -Force

function New-FakeYtDlp {
    param([Parameter(Mandatory = $true)][string]$Path)

    $source = @'
using System;
using System.IO;
using System.Linq;
using System.Text;

public class Program {
    public static int Main(string[] args) {
        var url = args.Length == 0 ? "" : args[args.Length - 1];
        if (url.Contains("cli-failure")) {
            Console.Error.WriteLine("ERROR: " + new string('x', 3000) + " TAIL-CLI-DIAGNOSTIC");
            return 7;
        }
        if (url.Contains("unavailable")) {
            Console.Error.WriteLine("ERROR: Video unavailable");
            return 1;
        }
        if (args.Contains("--dump-single-json")) {
            Console.Error.WriteLine("WARNING: harmless warning");
            Console.WriteLine("{\"id\":\"abc123\",\"title\":\"Test\",\"subtitles\":{},\"automatic_captions\":{\"ru\":[{\"ext\":\"vtt\"}]}}");
            return 0;
        }
        var outputIndex = Array.IndexOf(args, "-o");
        var template = args[outputIndex + 1];
        var directory = Path.GetDirectoryName(template);
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "abc123.ru.vtt"), "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nWorking transcript\n", new UTF8Encoding(false));
        Console.Error.WriteLine("WARNING: harmless warning");
        return 0;
    }
}
'@
    Add-Type -TypeDefinition $source -OutputAssembly $Path -OutputType ConsoleApplication
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

function Assert-PropertyNames {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string[]]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $actual = @($Value.PSObject.Properties.Name)
    Assert-True (($actual -join "|") -eq ($Expected -join "|")) "$Message Expected '$($Expected -join ", ")', got '$($actual -join ", ")'."
}

function Get-CliTemporaryDirectories {
    return @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter "youtube-transcript-cli-*" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName } |
        Sort-Object)
}

function Assert-StringSetsEqual {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Expected,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $expectedValues = @($Expected)
    $actualValues = @($Actual)
    Assert-True (($expectedValues -join "|") -eq ($actualValues -join "|")) "$Message Expected '$($expectedValues -join ", ")', got '$($actualValues -join ", ")'."
}

function New-FakeInfo {
    $subtitles = [pscustomobject]@{
        en = @([pscustomobject]@{ ext = "vtt" })
    }

    $automaticCaptions = [pscustomobject]@{
        ru = @([pscustomobject]@{ ext = "vtt" })
        "en-GB" = @([pscustomobject]@{ ext = "vtt" })
    }

    [pscustomobject]@{
        id = "abc123"
        title = "Unsafe / Video: Title?"
        subtitles = $subtitles
        automatic_captions = $automaticCaptions
    }
}

$tests = @(
    @{
        Name = "Auto chooses ru auto captions before manual en and de"
        Run = {
            $choice = Resolve-TranscriptSubtitleChoice -Info (New-FakeInfo) -Preference "auto"
            Assert-True ($choice.Language -eq "ru") "Expected ru, got $($choice.Language)"
            Assert-True ($choice.Source -eq "auto") "Expected auto captions, got $($choice.Source)"
        }
    },
    @{
        Name = "Auto chooses Russian captions when only automatic captions exist"
        Run = {
            $autoOnly = [pscustomobject]@{
                subtitles = $null
                automatic_captions = [pscustomobject]@{
                    ru = @([pscustomobject]@{ ext = "vtt" })
                }
            }

            $choice = Resolve-TranscriptSubtitleChoice -Info $autoOnly -Preference "auto"
            Assert-True ($choice.Tag -eq "ru") "Expected auto-only Russian captions."
        }
    },
    @{
        Name = "Auto chooses English captions when only manual captions exist"
        Run = {
            $manualOnly = [pscustomobject]@{
                subtitles = [pscustomobject]@{
                    en = @([pscustomobject]@{ ext = "vtt" })
                }
                automatic_captions = $null
            }

            $choice = Resolve-TranscriptSubtitleChoice -Info $manualOnly -Preference "auto"
            Assert-True ($choice.Tag -eq "en") "Expected manual-only English captions."
        }
    },
    @{
        Name = "Explicit English preference accepts an Australian regional tag"
        Run = {
            $regionalEnglish = [pscustomobject]@{
                subtitles = [pscustomobject]@{
                    "en-AU" = @([pscustomobject]@{ ext = "vtt" })
                }
                automatic_captions = [pscustomobject]@{
                    ja = @([pscustomobject]@{ ext = "vtt" })
                }
            }

            $choice = Resolve-TranscriptSubtitleChoice -Info $regionalEnglish -Preference "en"
            Assert-True ($choice.Tag -eq "en-AU") "Expected en-AU for an explicit English preference."
        }
    },
    @{
        Name = "Auto skips manual live chat in favor of Japanese captions"
        Run = {
            $liveChatAndCaptions = [pscustomobject]@{
                subtitles = [pscustomobject]@{
                    live_chat = @([pscustomobject]@{ ext = "vtt" })
                }
                automatic_captions = [pscustomobject]@{
                    ja = @([pscustomobject]@{ ext = "vtt" })
                }
            }

            $choice = Resolve-TranscriptSubtitleChoice -Info $liveChatAndCaptions -Preference "auto"
            Assert-True ($choice.Tag -eq "ja") "Expected Japanese captions instead of live chat."
        }
    },
    @{
        Name = "Auto skips unusable manual formats in favor of Japanese captions"
        Run = {
            $unusableManualAndCaptions = [pscustomobject]@{
                subtitles = [pscustomobject]@{
                    fr = @([pscustomobject]@{ ext = "json" })
                }
                automatic_captions = [pscustomobject]@{
                    ja = @([pscustomobject]@{ ext = "vtt" })
                }
            }

            $choice = Resolve-TranscriptSubtitleChoice -Info $unusableManualAndCaptions -Preference "auto"
            Assert-True ($choice.Tag -eq "ja") "Expected Japanese captions instead of an unusable manual format."
        }
    },
    @{
        Name = "Selected unavailable supported language returns available language list"
        Run = {
            try {
                Resolve-TranscriptSubtitleChoice -Info (New-FakeInfo) -Preference "de" | Out-Null
                throw "Expected language error."
            }
            catch {
                Assert-True ($_.Exception.Message -match "de") "Expected selected language in error: $($_.Exception.Message)"
                Assert-True ($_.Exception.Message -match "Available") "Expected available list in error: $($_.Exception.Message)"
                Assert-True ($_.Exception.Message -match "ru") "Expected ru in available list: $($_.Exception.Message)"
            }
        }
    },
    @{
        Name = "Safe transcript filename includes date title id and language"
        Run = {
            $name = New-TranscriptFileName -Title "Unsafe / Video: Title?" -VideoId "abc123" -Language "de" -Date ([datetime]"2026-05-30")
            Assert-True ($name -eq "2026-05-30_Unsafe-Video-Title_abc123_de.txt") "Unexpected filename: $name"
        }
    },
    @{
        Name = "Subtitle conversion removes whitespace just inside brackets"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-bracket-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            try {
                $vtt = Join-Path $dir "brackets.vtt"
                Set-Content -LiteralPath $vtt -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    "Keep ( inner words ) and { brace words }."
                )

                $text = Convert-SubtitleFileToTranscriptText -Path $vtt
                Assert-True ($text -eq "Keep (inner words) and {brace words}.") "Expected legacy bracket whitespace cleanup, got: $text"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Subtitle-file saving preserves collisions and coordinates clean artifacts"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-save-collision-tests-" + [System.Guid]::NewGuid().ToString("N"))
            $outputDir = Join-Path $dir "output"
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

            try {
                $vtt = Join-Path $dir "Sample.en.vtt"
                Set-Content -LiteralPath $vtt -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    "New transcript."
                )

                $oldClean = Join-Path $outputDir "Sample.en.clean.txt"
                $oldReview = Join-Path $outputDir "Sample.en.review.txt"
                $oldSecondReview = Join-Path $outputDir "Sample.en-2.review.txt"
                $oldCleanBytes = [byte[]]@(1, 2, 3, 4)
                $oldReviewBytes = [byte[]]@(5, 6, 7, 8)
                $oldSecondReviewBytes = [byte[]]@(9, 10, 11, 12)
                [System.IO.File]::WriteAllBytes($oldClean, $oldCleanBytes)
                [System.IO.File]::WriteAllBytes($oldReview, $oldReviewBytes)
                [System.IO.File]::WriteAllBytes($oldSecondReview, $oldSecondReviewBytes)

                $saved = Save-TranscriptFromSubtitleFile -Path $vtt -OutputDir $outputDir -CleanTranscript $true

                Assert-PropertyNames -Value $saved -Expected @("TextPath", "ReviewPath") -Message "Unexpected subtitle-file result shape."
                Assert-True ($saved.TextPath -eq (Join-Path $outputDir "Sample.en-3.clean.txt")) "Expected -3 clean path, got $($saved.TextPath)"
                Assert-True ($saved.ReviewPath -eq (Join-Path $outputDir "Sample.en-3.review.txt")) "Expected coordinated -3 review path, got $($saved.ReviewPath)"
                Assert-True (Test-Path -LiteralPath $saved.TextPath) "Expected suffixed clean transcript."
                Assert-True (Test-Path -LiteralPath $saved.ReviewPath) "Expected suffixed review file."
                Assert-BytesEqual -Expected $oldCleanBytes -Actual ([System.IO.File]::ReadAllBytes($oldClean)) -Message "Existing clean transcript changed."
                Assert-BytesEqual -Expected $oldReviewBytes -Actual ([System.IO.File]::ReadAllBytes($oldReview)) -Message "Existing review file changed."
                Assert-BytesEqual -Expected $oldSecondReviewBytes -Actual ([System.IO.File]::ReadAllBytes($oldSecondReview)) -Message "Existing -2 review file changed."

            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Subtitle-file saving uses -2 without changing the existing transcript"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-save-second-tests-" + [System.Guid]::NewGuid().ToString("N"))
            $outputDir = Join-Path $dir "output"
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

            try {
                $vtt = Join-Path $dir "Second.en.vtt"
                Set-Content -LiteralPath $vtt -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    "Second transcript."
                )
                $oldText = Join-Path $outputDir "Second.en.txt"
                $oldTextBytes = [byte[]]@(13, 14, 15, 16)
                [System.IO.File]::WriteAllBytes($oldText, $oldTextBytes)

                $saved = Save-TranscriptFromSubtitleFile -Path $vtt -OutputDir $outputDir -CleanTranscript $false

                Assert-True ($saved.TextPath -eq (Join-Path $outputDir "Second.en-2.txt")) "Expected -2 transcript path, got $($saved.TextPath)"
                Assert-True (Test-Path -LiteralPath $saved.TextPath) "Expected collision-safe -2 transcript."
                Assert-BytesEqual -Expected $oldTextBytes -Actual ([System.IO.File]::ReadAllBytes($oldText)) -Message "Existing unsuffixed transcript changed."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "VTT conversion removes technical lines and keeps readable paragraphs"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            try {
                $vtt = Join-Path $dir "sample.vtt"
                Set-Content -LiteralPath $vtt -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    "<c>Hello &amp; welcome</c>",
                    "",
                    "00:00:01.000 --> 00:00:02.000",
                    "Hello &amp; welcome",
                    "",
                    "00:00:02.000 --> 00:00:03.000",
                    "Second idea starts here."
                )

                $text = Convert-SubtitleFileToTranscriptText -Path $vtt
                Assert-True ($text -notmatch "WEBVTT") "Technical header should be removed: $text"
                Assert-True ($text -notmatch "-->") "Timestamps should be removed: $text"
                Assert-True ($text -match "Hello & welcome") "HTML entities should be decoded: $text"
                Assert-True (($text | Select-String -Pattern "Hello & welcome" -AllMatches).Matches.Count -eq 1) "Duplicate lines should be collapsed: $text"
                Assert-True ($text -match "Second idea") "Expected content was missing: $text"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "VTT conversion skips structural blocks and cue ids without losing caption text"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-structure-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            try {
                $vtt = Join-Path $dir "structured.vtt"
                Set-Content -LiteralPath $vtt -Encoding utf8 -Value @(
                    "WEBVTT",
                    "Kind: captions",
                    "Language: en",
                    "",
                    "NOTE internal note heading",
                    "Internal note text must not become speech.",
                    "A second note line must also be skipped.",
                    "",
                    "STYLE",
                    "::cue { color: lime; }",
                    "::cue(.important) { font-weight: bold; }",
                    "",
                    "REGION",
                    "id:transcript-region",
                    "width:40%",
                    "",
                    "intro-cue",
                    "00:00:00.000 --> 00:00:01.000 align:start position:0%",
                    "<c.green>Hello &amp; welcome</c>",
                    "",
                    "year-cue",
                    "00:00:01.000 --> 00:00:02.000",
                    "2026",
                    "",
                    "repeat-cue",
                    "00:00:02.000 --> 00:00:03.000",
                    "Repeated <i>caption</i>.",
                    "",
                    "repeat-cue-2",
                    "00:00:03.000 --> 00:00:04.000",
                    "Repeated caption."
                )

                $text = Convert-SubtitleFileToTranscriptText -Path $vtt -TranscriptMode:$false
                Assert-True ($text -notmatch "Internal note text") "NOTE block contents leaked into transcript: $text"
                Assert-True ($text -notmatch "color: lime") "STYLE block contents leaked into transcript: $text"
                Assert-True ($text -notmatch "transcript-region") "REGION block contents leaked into transcript: $text"
                Assert-True ($text -notmatch "(?:intro|year|repeat)-cue") "Cue identifiers leaked into transcript: $text"
                Assert-True ($text -match "Hello & welcome") "HTML entities should be decoded: $text"
                Assert-True ($text -match "(?:^|\s)2026(?:\s|$)") "Numeric caption text was lost: $text"
                Assert-True (($text | Select-String -Pattern "Repeated caption\." -AllMatches).Matches.Count -eq 1) "Adjacent duplicate captions should be collapsed: $text"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Subtitle conversion rejects a file containing only structure"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-empty-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            try {
                $srt = Join-Path $dir "empty.srt"
                Set-Content -LiteralPath $srt -Encoding utf8 -Value @(
                    "1",
                    "00:00:00,000 --> 00:00:01,000",
                    ""
                )

                try {
                    Convert-SubtitleFileToTranscriptText -Path $srt | Out-Null
                    throw "Expected empty-transcript error."
                }
                catch {
                    Assert-True ($_.Exception.Message -eq "Subtitle file did not contain readable transcript text.") "Unexpected empty-transcript error: $($_.Exception.Message)"
                }
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "VTT conversion preserves cue payloads beginning with structural block names"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-block-name-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            try {
                $vtt = Join-Path $dir "block-name-speech.vtt"
                Set-Content -LiteralPath $vtt -Encoding utf8 -Value @(
                    "WEBVTT",
                    "",
                    "note-cue",
                    "00:00:00.000 --> 00:00:01.000",
                    "NOTE this carefully",
                    "",
                    "style-cue",
                    "00:00:01.000 --> 00:00:02.000",
                    "STYLE matters",
                    "",
                    "region-cue",
                    "00:00:02.000 --> 00:00:03.000",
                    "REGION names matter",
                    "",
                    "ordinary-cue",
                    "00:00:03.000 --> 00:00:04.000",
                    "Anchor text."
                )

                $text = Convert-SubtitleFileToTranscriptText -Path $vtt
                $expected = "NOTE this carefully STYLE matters REGION names matter Anchor text."
                Assert-True ($text -eq $expected) "Cue payloads beginning with structural names were lost. Expected '$expected', got '$text'."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "CLI core returns one public result when attempt callback writes output"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-cli-result-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $beforeTemp = Get-CliTemporaryDirectories

            try {
                $results = @(Save-TranscriptFromYoutubeCli `
                    -Url "https://example.test/callback-output" `
                    -OutputDir $dir `
                    -Preference "ru" `
                    -SubtitleLanguages "ru" `
                    -NoClean $false `
                    -KeepSubtitles $false `
                    -Srt $false `
                    -CleanTranscript $false `
                    -YtDlpPath $fakeYtDlpPath `
                    -OnAttempt { param($language) "callback-output-$language" })

                Assert-True ($results.Count -eq 1) "Expected one result object, got $($results.Count): $($results -join ", ")"
                Assert-True ($results[0] -is [pscustomobject]) "Expected a PSCustomObject result."
                Assert-PropertyNames `
                    -Value $results[0] `
                    -Expected @("TextPath", "ReviewPath", "SubtitlePaths", "OutputDir", "FoundSubtitles", "ExitCode", "YtDlpExitCode", "Output", "StdErr") `
                    -Message "Unexpected CLI-core result shape."
                Assert-True ($results[0].FoundSubtitles) "Expected downloaded subtitles."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }

            $afterTemp = Get-CliTemporaryDirectories
            Assert-StringSetsEqual -Expected $beforeTemp -Actual $afterTemp -Message "CLI success left a temporary workspace behind."
        }
    },
    @{
        Name = "CLI core preserves bounded diagnostics and cleans failed temporary workspaces"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-cli-diagnostic-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $beforeTemp = Get-CliTemporaryDirectories

            try {
                $result = Save-TranscriptFromYoutubeCli `
                    -Url "https://example.test/cli-failure" `
                    -OutputDir $dir `
                    -Preference "ru" `
                    -SubtitleLanguages "ru" `
                    -NoClean $false `
                    -KeepSubtitles $false `
                    -Srt $false `
                    -CleanTranscript $false `
                    -YtDlpPath $fakeYtDlpPath

                Assert-True (-not $result.FoundSubtitles) "Expected no subtitle on fake failure."
                Assert-True ($result.YtDlpExitCode -eq 7) "Expected native exit 7, got $($result.YtDlpExitCode)."
                Assert-True ($result.StdErr -match "TAIL-CLI-DIAGNOSTIC") "Expected stderr tail in result: $($result.StdErr)"
                Assert-True ($result.Output -match "TAIL-CLI-DIAGNOSTIC") "Expected combined output tail in result: $($result.Output)"
                Assert-True ($result.StdErr.Length -le 2000) "Expected bounded stderr, got $($result.StdErr.Length) characters."
                Assert-True ($result.Output.Length -le 2000) "Expected bounded output, got $($result.Output.Length) characters."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }

            $afterTemp = Get-CliTemporaryDirectories
            Assert-StringSetsEqual -Expected $beforeTemp -Actual $afterTemp -Message "CLI failure left a temporary workspace behind."
        }
    },
    @{
        Name = "GUI core preserves collisions with coordinated transcript and subtitle suffixes"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-gui-collision-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            try {
                $baseName = New-TranscriptFileName -Title "Test" -VideoId "abc123" -Language "ru"
                $baseStem = [System.IO.Path]::GetFileNameWithoutExtension($baseName)
                $oldText = Join-Path $dir "$baseStem.txt"
                $oldSecondSubtitle = Join-Path $dir "$baseStem-2.vtt"
                $oldTextBytes = [byte[]]@(21, 22, 23, 24)
                $oldSecondSubtitleBytes = [byte[]]@(31, 32, 33, 34)
                [System.IO.File]::WriteAllBytes($oldText, $oldTextBytes)
                [System.IO.File]::WriteAllBytes($oldSecondSubtitle, $oldSecondSubtitleBytes)

                $saved = Save-TranscriptFromYoutube `
                    -Url "https://youtube.com/watch?v=working" `
                    -OutputDir $dir `
                    -Language "ru" `
                    -KeepSubtitles $true `
                    -YtDlpPath $fakeYtDlpPath

                Assert-PropertyNames `
                    -Value $saved `
                    -Expected @("TextPath", "SubtitlePath", "OutputDir", "Language", "SubtitleTag", "Source", "Title", "VideoId", "AvailableLanguages") `
                    -Message "Unexpected GUI-core result shape."
                Assert-True ($saved.TextPath -eq (Join-Path $dir "$baseStem-3.txt")) "Expected -3 GUI transcript, got $($saved.TextPath)"
                Assert-True ($saved.SubtitlePath -eq (Join-Path $dir "$baseStem-3.vtt")) "Expected coordinated -3 GUI subtitle, got $($saved.SubtitlePath)"
                Assert-True (Test-Path -LiteralPath $saved.TextPath) "Expected suffixed GUI transcript."
                Assert-True (Test-Path -LiteralPath $saved.SubtitlePath) "Expected suffixed GUI subtitle."
                Assert-BytesEqual -Expected $oldTextBytes -Actual ([System.IO.File]::ReadAllBytes($oldText)) -Message "Existing GUI transcript changed."
                Assert-BytesEqual -Expected $oldSecondSubtitleBytes -Actual ([System.IO.File]::ReadAllBytes($oldSecondSubtitle)) -Message "Existing GUI -2 subtitle changed."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "yt-dlp warning on stderr does not abort successful metadata"
        Run = {
            $info = Invoke-YtDlpJson -YtDlpPath $fakeYtDlpPath -Url "https://youtube.com/watch?v=working"
            Assert-True ($info.id -eq "abc123") "Expected abc123, got $($info.id)"
        }
    },
    @{
        Name = "Unavailable video stderr maps to friendly message"
        Run = {
            try {
                Invoke-YtDlpJson -YtDlpPath $fakeYtDlpPath -Url "https://youtube.com/watch?v=unavailable" | Out-Null
                throw "Expected unavailable-video error."
            }
            catch {
                Assert-True ($_.Exception.Message -eq "This video is unavailable without login or cannot be accessed by yt-dlp.") "Unexpected error: $($_.Exception.Message)"
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
$fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-native-tests-" + [System.Guid]::NewGuid().ToString("N"))
$fakeYtDlpPath = Join-Path $fakeRoot "yt-dlp.exe"
New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
New-FakeYtDlp -Path $fakeYtDlpPath

try {
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
}
finally {
    Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    throw "$failed test(s) failed."
}

Write-Host "$passed/$($selectedTests.Count) module tests passed."
