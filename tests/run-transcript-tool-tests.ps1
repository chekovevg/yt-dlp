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
                    live_chat = @([pscustomobject]@{ ext = "json" })
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

$failed = 0
$fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-native-tests-" + [System.Guid]::NewGuid().ToString("N"))
$fakeYtDlpPath = Join-Path $fakeRoot "yt-dlp.exe"
New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
New-FakeYtDlp -Path $fakeYtDlpPath

try {
    foreach ($test in $tests) {
        try {
            & $test.Run
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
