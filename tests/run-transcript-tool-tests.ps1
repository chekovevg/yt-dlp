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
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

public class Program {
    private static int HangWithChild(string markerPath) {
        var child = Process.Start(new ProcessStartInfo {
            FileName = Process.GetCurrentProcess().MainModule.FileName,
            Arguments = "--hang-child",
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        });
        File.AppendAllLines(markerPath, new[] {
            Process.GetCurrentProcess().Id.ToString(),
            child.Id.ToString()
        });
        Console.WriteLine("hang fixture started");
        Console.Out.Flush();
        child.WaitForExit();
        return child.ExitCode;
    }

    public static int Main(string[] args) {
        var url = args.Length == 0 ? "" : args[args.Length - 1];
        if (args.Contains("--hang-child")) {
            Thread.Sleep(Timeout.Infinite);
            return 0;
        }
        var hangIndex = Array.IndexOf(args, "--hang-with-child");
        if (hangIndex >= 0) {
            return HangWithChild(args[hangIndex + 1]);
        }
        if (args.Contains("--echo-args")) {
            foreach (var argument in args.SkipWhile(value => value != "--echo-args").Skip(1)) {
                Console.WriteLine(argument.Length + ":" + Convert.ToBase64String(Encoding.UTF8.GetBytes(argument)));
            }
            return 0;
        }
        if (url.Contains("metadata-rate-limit")) {
            Console.Error.WriteLine("ERROR: HTTP Error 429: Too Many Requests " + new string('r', 3000));
            return 9;
        }
        if (url.Contains("metadata-long")) {
            Console.Error.WriteLine("ERROR: " + new string('m', 3000) + " TAIL-METADATA-DIAGNOSTIC");
            return 9;
        }
        if (url.Contains("metadata-hang-once")) {
            var statePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "metadata-hang-once.flag");
            if (!File.Exists(statePath)) {
                File.WriteAllText(statePath, "first attempt started");
                return HangWithChild(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "metadata-hang-once-pids.txt"));
            }
        }
        if (url.Contains("metadata-hang-always")) {
            return HangWithChild(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "metadata-hang-always-pids.txt"));
        }
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
        if (url.Contains("download-long")) {
            Console.Error.WriteLine("ERROR: " + new string('d', 3000) + " TAIL-DOWNLOAD-DIAGNOSTIC");
            return 6;
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
        Name = "Auto skips a manual language whose format list is empty"
        Run = {
            $emptyManualAndCaptions = [pscustomobject]@{
                subtitles = [pscustomobject]@{
                    fr = @()
                }
                automatic_captions = [pscustomobject]@{
                    ja = @([pscustomobject]@{ ext = "VTT" })
                }
            }

            $choice = Resolve-TranscriptSubtitleChoice -Info $emptyManualAndCaptions -Preference "auto"
            Assert-True ($choice.Tag -eq "ja") "Expected Japanese VTT captions instead of empty French formats, got $($choice.Tag)."
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
        Name = "Concurrent subtitle-file saves atomically claim distinct stems"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-concurrent-core-tests-" + [System.Guid]::NewGuid().ToString("N"))
            $outputDir = Join-Path $dir "output"
            $runnerPath = Join-Path $dir "save-runner.ps1"
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            $processes = @()
            $gate = $null

            try {
                $sourceDirs = @((Join-Path $dir "one"), (Join-Path $dir "two"))
                $markers = @("FIRST-CONCURRENT-CONTENT", "SECOND-CONCURRENT-CONTENT")
                $sourcePaths = @()
                for ($sourceIndex = 0; $sourceIndex -lt 2; $sourceIndex++) {
                    New-Item -ItemType Directory -Path $sourceDirs[$sourceIndex] -Force | Out-Null
                    $sourcePath = Join-Path $sourceDirs[$sourceIndex] "Concurrent.en.vtt"
                    $builder = New-Object System.Text.StringBuilder
                    [void]$builder.Append("WEBVTT`r`n`r`n00:00:00.000 --> 00:30:00.000`r`n")
                    for ($lineIndex = 0; $lineIndex -lt 30000; $lineIndex++) {
                        [void]$builder.Append($markers[$sourceIndex]).Append(" ").Append($lineIndex).Append(".`r`n")
                    }
                    [System.IO.File]::WriteAllText($sourcePath, $builder.ToString(), (New-Object System.Text.UTF8Encoding($false)))
                    $sourcePaths += $sourcePath
                }

                $oldPath = Join-Path $outputDir "Concurrent.en.txt"
                $oldBytes = [byte[]]@(81, 82, 83, 84, 85)
                [System.IO.File]::WriteAllBytes($oldPath, $oldBytes)
                Set-Content -LiteralPath $runnerPath -Encoding utf8 -Value @(
                    'param([string]$Module64,[string]$Source64,[string]$Output64,[string]$Result64,[string]$GateName)',
                    '$ErrorActionPreference = "Stop"',
                    '$decode = { param($value) [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) }',
                    '$modulePath = & $decode $Module64',
                    '$sourcePath = & $decode $Source64',
                    '$outputDir = & $decode $Output64',
                    '$resultPath = & $decode $Result64',
                    '$gate = [System.Threading.EventWaitHandle]::OpenExisting($GateName)',
                    'try { [void]$gate.WaitOne() } finally { $gate.Dispose() }',
                    'Import-Module $modulePath -Force',
                    '$saved = Save-TranscriptFromSubtitleFile -Path $sourcePath -OutputDir $outputDir -CleanTranscript $false',
                    '$saved | ConvertTo-Json -Compress | Set-Content -LiteralPath $resultPath -Encoding utf8'
                )

                $gateName = "Local\TranscriptAtomicCore-" + [Guid]::NewGuid().ToString("N")
                $gate = New-Object System.Threading.EventWaitHandle -ArgumentList @($false, [System.Threading.EventResetMode]::ManualReset, $gateName)
                $encode = {
                    param($value)
                    [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$value))
                }
                $resultPaths = @((Join-Path $dir "one.json"), (Join-Path $dir "two.json"))
                for ($processIndex = 0; $processIndex -lt 2; $processIndex++) {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = "powershell.exe"
                    $psi.Arguments = @(
                        '-NoProfile',
                        '-ExecutionPolicy', 'Bypass',
                        '-File', ('"' + $runnerPath + '"'),
                        '-Module64', (& $encode $modulePath),
                        '-Source64', (& $encode $sourcePaths[$processIndex]),
                        '-Output64', (& $encode $outputDir),
                        '-Result64', (& $encode $resultPaths[$processIndex]),
                        '-GateName', $gateName
                    ) -join ' '
                    $psi.UseShellExecute = $false
                    $psi.CreateNoWindow = $true
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError = $true
                    $processes += [System.Diagnostics.Process]::Start($psi)
                }

                [void]$gate.Set()
                $results = @()
                for ($processIndex = 0; $processIndex -lt $processes.Count; $processIndex++) {
                    $process = $processes[$processIndex]
                    Assert-True ($process.WaitForExit(60000)) "Concurrent core process $processIndex timed out."
                    $stdout = $process.StandardOutput.ReadToEnd()
                    $stderr = $process.StandardError.ReadToEnd()
                    Assert-True ($process.ExitCode -eq 0) "Concurrent core process $processIndex failed: $stdout $stderr"
                    $results += (Get-Content -LiteralPath $resultPaths[$processIndex] -Raw -Encoding utf8 | ConvertFrom-Json)
                }

                $claimedPaths = @($results | ForEach-Object { [string]$_.TextPath } | Sort-Object)
                Assert-True (($claimedPaths | Select-Object -Unique).Count -eq 2) "Concurrent core saves claimed the same path: $($claimedPaths -join ', ')"
                Assert-True ($claimedPaths[0] -eq (Join-Path $outputDir "Concurrent.en-2.txt")) "Expected first atomic suffix -2, got $($claimedPaths[0])."
                Assert-True ($claimedPaths[1] -eq (Join-Path $outputDir "Concurrent.en-3.txt")) "Expected second atomic suffix -3, got $($claimedPaths[1])."
                for ($resultIndex = 0; $resultIndex -lt 2; $resultIndex++) {
                    $content = Get-Content -LiteralPath $results[$resultIndex].TextPath -Raw -Encoding utf8
                    Assert-True ($content -match $markers[$resultIndex]) "Concurrent output lost its invocation's content: $($results[$resultIndex].TextPath)"
                }
                Assert-BytesEqual -Expected $oldBytes -Actual ([System.IO.File]::ReadAllBytes($oldPath)) -Message "Concurrent saves changed the pre-existing transcript."
                $outputFiles = @(Get-ChildItem -LiteralPath $outputDir -File)
                Assert-True ($outputFiles.Count -eq 3) "Concurrent core left unexpected reservation files: $($outputFiles.Name -join ', ')"
                Assert-True (@($outputFiles | Where-Object Length -eq 0).Count -eq 0) "Concurrent core left zero-byte reservations."
            }
            finally {
                if ($gate) { $gate.Dispose() }
                foreach ($process in $processes) {
                    if ($process -and -not $process.HasExited) { $process.Kill() }
                    if ($process) { $process.Dispose() }
                }
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "Failed subtitle conversion releases only its own reservations"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-reservation-failure-tests-" + [System.Guid]::NewGuid().ToString("N"))
            $outputDir = Join-Path $dir "output"
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            try {
                $subtitle = Join-Path $dir "Broken.en.vtt"
                Set-Content -LiteralPath $subtitle -Encoding utf8 -Value @("WEBVTT", "", "00:00:00.000 --> 00:00:01.000", "")
                $oldPath = Join-Path $outputDir "Broken.en.clean.txt"
                $oldBytes = [byte[]]@(91, 92, 93, 94)
                [System.IO.File]::WriteAllBytes($oldPath, $oldBytes)

                try {
                    Save-TranscriptFromSubtitleFile -Path $subtitle -OutputDir $outputDir -CleanTranscript $true | Out-Null
                    throw "Expected failed subtitle conversion."
                }
                catch {
                    Assert-True ($_.Exception.Message -eq "Subtitle file did not contain readable transcript text.") "Unexpected conversion error: $($_.Exception.Message)"
                }

                Assert-BytesEqual -Expected $oldBytes -Actual ([System.IO.File]::ReadAllBytes($oldPath)) -Message "Failed conversion changed the pre-existing transcript."
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $outputDir "Broken.en-2.clean.txt"))) "Failed conversion left a zero-byte clean-text reservation."
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $outputDir "Broken.en-2.review.txt"))) "Failed conversion left a zero-byte review reservation."
                Assert-True (@(Get-ChildItem -LiteralPath $outputDir -File).Count -eq 1) "Failed conversion left unexpected output artifacts."
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Interrupted multi-artifact publish rolls back only identity-matched outputs"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-interrupted-publish-tests-" + [Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                $protectedPath = Join-Path $dir "Protected.txt"
                $protectedBytes = [byte[]]@(121, 122, 123, 124)
                [System.IO.File]::WriteAllBytes($protectedPath, $protectedBytes)
                $replacementBytes = [byte[]]@(41, 42, 43, 44, 45)
                $operationId = [Guid]::NewGuid().ToString("N")
                $module = Get-Module transcript-tool
                & $module {
                    param($outputDir, $operation, $replacement)
                    $reservation = New-TranscriptOutputReservation `
                        -OutputDir $outputDir `
                        -Stem "Interrupted" `
                        -ArtifactSuffixes @(".txt", ".vtt") `
                        -OperationId $operation
                    $publishError = $null
                    try {
                        Write-TranscriptReservationText -Reservation $reservation -Suffix ".txt" -Text "complete text"
                        Write-TranscriptReservationText -Reservation $reservation -Suffix ".vtt" -Text "complete subtitle"
                        $interruptAfterSubstitution = {
                            param($publishedCount, $entry)
                            if ($publishedCount -eq 1) {
                                $originalPath = "$($entry.TargetPath).original"
                                [System.IO.File]::Move([string]$entry.TargetPath, $originalPath)
                                [System.IO.File]::WriteAllBytes([string]$entry.TargetPath, $replacement)
                                [System.IO.File]::Delete($originalPath)
                                throw "injected publish interruption"
                            }
                        }.GetNewClosure()
                        Publish-TranscriptOutputReservation `
                            -Reservation $reservation `
                            -OnArtifactPublished $interruptAfterSubstitution
                    }
                    catch { $publishError = $_ }
                    finally {
                        Close-TranscriptOutputReservation -Reservation $reservation -DeleteFiles $true
                        $root = Get-TranscriptOperationStagingRoot -OutputDir $outputDir -OperationId $operation
                        if (Test-Path -LiteralPath $root) {
                            Remove-TranscriptOperationStagingRoot -StagingRoot $root
                        }
                    }
                    if (-not $publishError -or $publishError.Exception.Message -notmatch "injected publish interruption") {
                        throw "Interrupted publish did not exercise the expected failure."
                    }
                } $dir $operationId $replacementBytes

                Assert-BytesEqual -Expected $protectedBytes -Actual ([System.IO.File]::ReadAllBytes($protectedPath)) -Message "Interrupted publish changed an unrelated file."
                Assert-True (Test-Path -LiteralPath (Join-Path $dir "Interrupted.txt")) "Interrupted publish deleted the same-path replacement."
                Assert-BytesEqual -Expected $replacementBytes -Actual ([System.IO.File]::ReadAllBytes((Join-Path $dir "Interrupted.txt"))) -Message "Interrupted publish changed the same-path replacement."
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $dir "Interrupted.vtt"))) "Interrupted publish left its second final artifact."
                $leaks = @(Get-ChildItem -LiteralPath $dir -Force | Where-Object Name -like ".youtube-transcript-*")
                Assert-True ($leaks.Count -eq 0) "Interrupted publish left staging/lock artifacts: $($leaks.Name -join ', ')"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
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
        Name = "VTT and SRT preserve header-like tokens inside cue payloads"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-header-payload-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            try {
                $vtt = Join-Path $dir "payload.vtt"
                Set-Content -LiteralPath $vtt -Encoding utf8 -Value @(
                    "WEBVTT",
                    "Kind: captions",
                    "Language: en",
                    "",
                    "00:00:00.000 --> 00:00:01.000",
                    "WEBVTT",
                    "Kind: this is spoken",
                    "Language: this is also spoken"
                )
                $srt = Join-Path $dir "payload.srt"
                Set-Content -LiteralPath $srt -Encoding utf8 -Value @(
                    "1",
                    "00:00:00,000 --> 00:00:01,000",
                    "WEBVTT",
                    "Kind: SRT speech",
                    "Language: SRT speech"
                )

                $vttText = Convert-SubtitleFileToTranscriptText -Path $vtt
                $srtText = Convert-SubtitleFileToTranscriptText -Path $srt
                Assert-True ($vttText -eq "WEBVTT Kind: this is spoken Language: this is also spoken") "VTT cue payload header tokens were discarded: $vttText"
                Assert-True ($srtText -eq "WEBVTT Kind: SRT speech Language: SRT speech") "SRT cue payload header tokens were discarded: $srtText"
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    },
    @{
        Name = "Native invocation round-trips Windows argument edge cases"
        Run = {
            $arguments = @(
                "plain",
                "with space",
                'say "hello"',
                "",
                "C:\folder with space\",
                "C:\plain\",
                'slashes\\before"quote',
                "trailing slash with space\\"
            )
            $result = Invoke-TranscriptProcess -FilePath $fakeYtDlpPath -ArgumentList (@("--echo-args") + $arguments)
            Assert-True ($result.ExitCode -eq 0) "Argument echo process failed: $($result.Output)"
            $actual = @(
                $result.StdOut -split "`r?`n" |
                    Where-Object { $_ -match '^\d+:' } |
                    ForEach-Object {
                        $parts = $_ -split ':', 2
                        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))
                    }
            )
            Assert-True ($actual.Count -eq $arguments.Count) "Native argv count changed from $($arguments.Count) to $($actual.Count)."
            for ($index = 0; $index -lt $arguments.Count; $index++) {
                Assert-True ([string]$actual[$index] -ceq [string]$arguments[$index]) "Native argv[$index] changed. Expected '$($arguments[$index])', got '$($actual[$index])'."
            }
        }
    },
    @{
        Name = "Native invocation times out and terminates its process tree"
        Run = {
            $markerPath = Join-Path $fakeRoot ("hung-processes-" + [Guid]::NewGuid().ToString("N") + ".txt")
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            try {
                $result = Invoke-TranscriptProcess `
                    -FilePath $fakeYtDlpPath `
                    -ArgumentList @("--hang-with-child", $markerPath) `
                    -TimeoutMilliseconds 300
                $stopwatch.Stop()

                Assert-True $result.TimedOut "Expected the hung native process to report a timeout."
                Assert-True ($stopwatch.ElapsedMilliseconds -lt 5000) "Hung native cleanup took $($stopwatch.ElapsedMilliseconds) ms."
                Assert-True (Test-Path -LiteralPath $markerPath) "Hung native fixture did not publish its process IDs."

                $processIds = @(Get-Content -LiteralPath $markerPath | ForEach-Object { [int]$_ })
                Assert-True ($processIds.Count -eq 2) "Expected parent and child process IDs from the hung fixture."
                foreach ($processId in $processIds) {
                    Assert-True (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "Timed-out native process $processId survived cleanup."
                }
            }
            finally {
                Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "Clean worker process runs yt-dlp from a PowerShell background job"
        Run = {
            $realYtDlpPath = Join-Path $repoRoot "yt-dlp.exe"
            $probeScriptPath = Join-Path $fakeRoot "clean-worker-probe.ps1"
            $job = $null

            Assert-True (Test-Path -LiteralPath $realYtDlpPath -PathType Leaf) "The yt-dlp executable is required for the clean-worker regression test."

            $probeSource = @'
param(
    [Parameter(Mandatory = $true)]
    [string]$ModulePath,

    [Parameter(Mandatory = $true)]
    [string]$YtDlpPath
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

try {
    Import-Module $ModulePath -Force
    $probe = Invoke-TranscriptProcess `
        -FilePath $YtDlpPath `
        -ArgumentList @("--version") `
        -TimeoutMilliseconds 8000

    if ($probe.TimedOut) {
        throw "yt-dlp version probe timed out."
    }
    if ($probe.ExitCode -ne 0 -or -not ([string]$probe.StdOut).Trim()) {
        throw "yt-dlp version probe failed: $($probe.Output)"
    }

    $version = ([string]$probe.StdOut).Trim()

    $json = [pscustomobject]@{ Kind = "Result"; Value = $version.Trim() } |
        ConvertTo-Json -Compress
    [Console]::Out.WriteLine(
        "TT1:" + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    )
}
catch {
    $json = [pscustomobject]@{ Kind = "Error"; Value = $_.Exception.Message } |
        ConvertTo-Json -Compress
    [Console]::Out.WriteLine(
        "TT1:" + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    )
    exit 1
}
'@
            [System.IO.File]::WriteAllText(
                $probeScriptPath,
                $probeSource,
                (New-Object System.Text.UTF8Encoding($false))
            )

            try {
                $job = Start-Job `
                    -ArgumentList @($modulePath, $probeScriptPath, $realYtDlpPath) `
                    -ScriptBlock {
                        param($module, $probeScript, $ytDlp)
                        $ErrorActionPreference = "Stop"
                        Import-Module $module -Force
                        Invoke-TranscriptWorkerProcess `
                            -WorkerScriptPath $probeScript `
                            -ArgumentList @(
                                "-ModulePath", $module,
                                "-YtDlpPath", $ytDlp
                            )
                    }

                $completed = Wait-Job -Job $job -Timeout 15
                $receivedErrors = @()
                $messages = @(Receive-Job `
                    -Job $job `
                    -Keep `
                    -ErrorAction SilentlyContinue `
                    -ErrorVariable +receivedErrors)

                Assert-True ([bool]$completed) "The clean worker did not complete within 15 seconds."
                Assert-True ($job.State -eq "Completed") "The clean worker job failed: $((@($receivedErrors | ForEach-Object { $_.Exception.Message }) -join ' | '))"

                $result = $messages | Where-Object { [string]$_.Kind -eq "Result" } | Select-Object -Last 1
                Assert-True ([bool]$result) "The clean worker did not return a result message."
                Assert-True ([string]$result.Value -match '^\d{4}\.\d{2}\.\d{2}') "Unexpected yt-dlp version: $($result.Value)"
            }
            finally {
                if ($job) {
                    if ($job.State -notin "Completed", "Failed", "Stopped") {
                        Stop-Job -Job $job -ErrorAction SilentlyContinue
                    }
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                }
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
        Name = "Metadata timeout is cleaned up and retried once"
        Run = {
            $statePath = Join-Path $fakeRoot "metadata-hang-once.flag"
            $markerPath = Join-Path $fakeRoot "metadata-hang-once-pids.txt"
            Remove-Item -LiteralPath $statePath, $markerPath -Force -ErrorAction SilentlyContinue

            try {
                $info = Invoke-YtDlpJson `
                    -YtDlpPath $fakeYtDlpPath `
                    -Url "https://youtube.com/watch?v=metadata-hang-once" `
                    -TimeoutMilliseconds 300 `
                    -MaxAttempts 2

                Assert-True ($info.id -eq "abc123") "Expected the second metadata attempt to succeed."
                $processIds = @(Get-Content -LiteralPath $markerPath | ForEach-Object { [int]$_ })
                Assert-True ($processIds.Count -eq 2) "Expected one timed-out metadata process tree."
                foreach ($processId in $processIds) {
                    Assert-True (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "Retried metadata process $processId survived cleanup."
                }
            }
            finally {
                Remove-Item -LiteralPath $statePath, $markerPath -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "Repeated metadata timeout returns a bounded friendly error"
        Run = {
            $markerPath = Join-Path $fakeRoot "metadata-hang-always-pids.txt"
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()

            try {
                try {
                    Invoke-YtDlpJson `
                        -YtDlpPath $fakeYtDlpPath `
                        -Url "https://youtube.com/watch?v=metadata-hang-always" `
                        -TimeoutMilliseconds 300 `
                        -MaxAttempts 2 | Out-Null
                    throw "Expected metadata timeout error."
                }
                catch {
                    $stopwatch.Stop()
                    Assert-True ($_.Exception.Message -eq "Checking the YouTube link took too long. Please try again.") "Unexpected timeout error: $($_.Exception.Message)"
                    Assert-True ($stopwatch.ElapsedMilliseconds -lt 5000) "Repeated metadata timeout took $($stopwatch.ElapsedMilliseconds) ms."
                }

                $processIds = @(Get-Content -LiteralPath $markerPath | ForEach-Object { [int]$_ })
                Assert-True ($processIds.Count -eq 4) "Expected two timed-out metadata process trees."
                foreach ($processId in $processIds) {
                    Assert-True (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "Timed-out metadata process $processId survived cleanup."
                }
            }
            finally {
                Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
            }
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
    },
    @{
        Name = "Metadata diagnostics are bounded and rate limits map before network errors"
        Run = {
            try {
                Invoke-YtDlpJson -YtDlpPath $fakeYtDlpPath -Url "https://youtube.com/watch?v=metadata-long" | Out-Null
                throw "Expected bounded metadata error."
            }
            catch {
                $message = $_.Exception.Message
                Assert-True ($message -match "TAIL-METADATA-DIAGNOSTIC") "Expected metadata diagnostic tail: $message"
                Assert-True ($message.Length -le 2100) "Metadata exception was not bounded: $($message.Length) characters."
            }

            try {
                Invoke-YtDlpJson -YtDlpPath $fakeYtDlpPath -Url "https://youtube.com/watch?v=metadata-rate-limit" | Out-Null
                throw "Expected rate-limit error."
            }
            catch {
                Assert-True ($_.Exception.Message -eq "YouTube temporarily rate-limited requests. Wait a little and try again.") "Rate limit was hidden by generic network mapping: $($_.Exception.Message)"
            }
        }
    },
    @{
        Name = "GUI core download diagnostics are bounded"
        Run = {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-tool-download-diagnostic-tests-" + [System.Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                try {
                    Save-TranscriptFromYoutube `
                        -Url "https://youtube.com/watch?v=download-long" `
                        -OutputDir $dir `
                        -Language "ru" `
                        -KeepSubtitles $false `
                        -YtDlpPath $fakeYtDlpPath | Out-Null
                    throw "Expected bounded download error."
                }
                catch {
                    $message = $_.Exception.Message
                    Assert-True ($message -match "TAIL-DOWNLOAD-DIAGNOSTIC") "Expected download diagnostic tail: $message"
                    Assert-True ($message.Length -le 2100) "Download exception was not bounded: $($message.Length) characters."
                }
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
