$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot "transcript-tool.psm1"
Import-Module $modulePath -Force

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
        en = @(@{})
    }

    $automaticCaptions = [pscustomobject]@{
        ru = @(@{})
        "en-GB" = @(@{})
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
    }
)

$failed = 0

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

if ($failed -gt 0) {
    throw "$failed test(s) failed."
}
