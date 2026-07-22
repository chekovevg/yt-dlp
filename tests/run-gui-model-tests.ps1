$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$modelPath = Join-Path $root "transcript-gui-model.psm1"

if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
    throw "GUI model module is missing: $modelPath"
}

Import-Module $modelPath -Force

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-ThrowsMessage {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage,
        [string]$Message
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -eq $ExpectedMessage) {
            return
        }

        throw "$Message Expected '$ExpectedMessage', got '$($_.Exception.Message)'."
    }

    throw "$Message Expected an exception."
}

$tests = @(
    @{
        Name = "Project names are trimmed and validated"
        Run = {
            $valid = Get-TranscriptProjectNameValidation -Name "  Research  "
            Assert-True $valid.IsValid "A normal project name was rejected."
            Assert-Equal $valid.Name "Research" "Project name was not trimmed."
            Assert-Equal $valid.ErrorCode $null "A valid name returned an error code."

            $cases = @(
                @{ Name = ""; Code = "Empty" },
                @{ Name = "."; Code = "Relative" },
                @{ Name = ".."; Code = "Relative" },
                @{ Name = "a/b"; Code = "InvalidCharacters" },
                @{ Name = "a\b"; Code = "InvalidCharacters" },
                @{ Name = "bad:name"; Code = "InvalidCharacters" },
                @{ Name = "trail."; Code = "TrailingDotOrSpace" },
                @{ Name = "CON"; Code = "Reserved" },
                @{ Name = "lpt1.notes"; Code = "Reserved" },
                @{ Name = ("x" * 81); Code = "TooLong" }
            )

            foreach ($case in $cases) {
                $validation = Get-TranscriptProjectNameValidation -Name $case.Name
                Assert-True (-not $validation.IsValid) "Invalid project name was accepted: $($case.Name)"
                Assert-Equal $validation.ErrorCode $case.Code "Wrong project validation code."
            }
        }
    },
    @{
        Name = "Project discovery returns immediate user folders only"
        Run = {
            $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
                "transcript-gui-model-tests-" + [Guid]::NewGuid().ToString("N")
            )

            try {
                New-Item -ItemType Directory -Path (Join-Path $testRoot "Beta") -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $testRoot "Alpha\Nested") -Force | Out-Null
                New-Item `
                    -ItemType Directory `
                    -Path (Join-Path $testRoot ".youtube-transcript-operation-hidden") `
                    -Force | Out-Null

                $projects = @(Get-TranscriptProjectNames -RootDir $testRoot)
                Assert-Equal $projects.Count 2 "Unexpected number of projects."
                Assert-Equal $projects[0] "Alpha" "Projects were not sorted."
                Assert-Equal $projects[1] "Beta" "Projects were not sorted."
            }
            finally {
                if (Test-Path -LiteralPath $testRoot) {
                    Remove-Item -LiteralPath $testRoot -Recurse -Force
                }
            }
        }
    },
    @{
        Name = "Project output resolution stays inside the root"
        Run = {
            $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
                "transcript-gui-model-tests-" + [Guid]::NewGuid().ToString("N")
            )

            try {
                $projectDir = Join-Path $testRoot "Research"
                New-Item -ItemType Directory -Path $projectDir -Force | Out-Null

                $rootOutput = Resolve-TranscriptProjectOutputDirectory `
                    -RootDir $testRoot `
                    -ProjectName "" `
                    -RequireExisting
                Assert-Equal `
                    $rootOutput `
                    ([System.IO.Path]::GetFullPath($testRoot).TrimEnd("\")) `
                    "Root project mapping changed."

                $projectOutput = Resolve-TranscriptProjectOutputDirectory `
                    -RootDir $testRoot `
                    -ProjectName "Research" `
                    -RequireExisting
                Assert-Equal `
                    $projectOutput `
                    ([System.IO.Path]::GetFullPath($projectDir).TrimEnd("\")) `
                    "Named project mapping changed."

                Assert-ThrowsMessage `
                    -Action {
                        Resolve-TranscriptProjectOutputDirectory `
                            -RootDir $testRoot `
                            -ProjectName "Missing" `
                            -RequireExisting
                    } `
                    -ExpectedMessage "ProjectMissing" `
                    -Message "A missing project was accepted."

                Assert-ThrowsMessage `
                    -Action {
                        Resolve-TranscriptProjectOutputDirectory `
                            -RootDir $testRoot `
                            -ProjectName ".."
                    } `
                    -ExpectedMessage "Relative" `
                    -Message "Traversal was accepted."
            }
            finally {
                if (Test-Path -LiteralPath $testRoot) {
                    Remove-Item -LiteralPath $testRoot -Recurse -Force
                }
            }
        }
    },
    @{
        Name = "Project creation rejects duplicates"
        Run = {
            $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
                "transcript-gui-model-tests-" + [Guid]::NewGuid().ToString("N")
            )

            try {
                New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
                $created = New-TranscriptProjectDirectory -RootDir $testRoot -Name "  Notes  "
                Assert-True (Test-Path -LiteralPath $created -PathType Container) "Project was not created."
                Assert-Equal (Split-Path -Leaf $created) "Notes" "Created project name was not normalized."

                Assert-ThrowsMessage `
                    -Action { New-TranscriptProjectDirectory -RootDir $testRoot -Name "Notes" } `
                    -ExpectedMessage "ProjectExists" `
                    -Message "An existing project was silently reused."
            }
            finally {
                if (Test-Path -LiteralPath $testRoot) {
                    Remove-Item -LiteralPath $testRoot -Recurse -Force
                }
            }
        }
    },
    @{
        Name = "Output directory preflight probes every destination"
        Run = {
            $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
                "transcript-gui-model-tests-" + [Guid]::NewGuid().ToString("N")
            )

            try {
                $first = Join-Path $testRoot "first"
                $second = Join-Path $testRoot "second"
                New-Item -ItemType Directory -Path $first -Force | Out-Null
                New-Item -ItemType Directory -Path $second -Force | Out-Null

                Assert-TranscriptOutputDirectoriesWritable -OutputDirs @($first, $second, $first)
                Assert-Equal @(Get-ChildItem -LiteralPath $first -Force).Count 0 "Preflight left a probe behind."
                Assert-Equal @(Get-ChildItem -LiteralPath $second -Force).Count 0 "Preflight left a probe behind."

                $notDirectory = Join-Path $testRoot "file.txt"
                [System.IO.File]::WriteAllText($notDirectory, "not a directory")
                Assert-ThrowsMessage `
                    -Action { Assert-TranscriptOutputDirectoriesWritable -OutputDirs @($notDirectory) } `
                    -ExpectedMessage "OutputDirectoryMissing" `
                    -Message "A regular file was accepted as an output directory."
            }
            finally {
                if (Test-Path -LiteralPath $testRoot) {
                    Remove-Item -LiteralPath $testRoot -Recurse -Force
                }
            }
        }
    },
    @{
        Name = "Batch planning ignores blanks and preserves visual order"
        Run = {
            $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
                "transcript-gui-model-tests-" + [Guid]::NewGuid().ToString("N")
            )

            try {
                $projectDir = Join-Path $testRoot "Research"
                New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
                $rows = @(
                    [pscustomobject]@{
                        CardId = "one"
                        Url = " https://youtu.be/one "
                        ProjectName = "Research"
                    },
                    [pscustomobject]@{
                        CardId = "blank"
                        Url = " "
                        ProjectName = ""
                    },
                    [pscustomobject]@{
                        CardId = "two"
                        Url = "https://youtu.be/two"
                        ProjectName = ""
                    }
                )

                $plan = @(
                    New-TranscriptBatchPlan `
                        -Rows $rows `
                        -RootDir $testRoot
                )

                Assert-Equal $plan.Count 2 "Blank rows were not ignored."
                Assert-Equal $plan[0].CardId "one" "Batch order changed."
                Assert-Equal $plan[0].Url "https://youtu.be/one" "URL was not trimmed."
                Assert-Equal $plan[0].OutputDir ([System.IO.Path]::GetFullPath($projectDir)) "Project output changed."
                Assert-Equal $plan[1].CardId "two" "Batch order changed."
                Assert-Equal $plan[1].OutputDir ([System.IO.Path]::GetFullPath($testRoot)) "Root output changed."
                Assert-True (-not $plan[1].PSObject.Properties["Language"]) "Batch items still carry a user-selected language."
            }
            finally {
                if (Test-Path -LiteralPath $testRoot) {
                    Remove-Item -LiteralPath $testRoot -Recurse -Force
                }
            }
        }
    },
    @{
        Name = "Batch planning enforces queue limits and existing projects"
        Run = {
            $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
                "transcript-gui-model-tests-" + [Guid]::NewGuid().ToString("N")
            )

            try {
                New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

                Assert-ThrowsMessage `
                    -Action {
                        New-TranscriptBatchPlan `
                            -Rows @([pscustomobject]@{ CardId = "one"; Url = ""; ProjectName = "" }) `
                            -RootDir $testRoot
                    } `
                    -ExpectedMessage "NoVideos" `
                    -Message "An empty batch was accepted."

                $tooMany = 1..7 | ForEach-Object {
                    [pscustomobject]@{ CardId = "card-$_"; Url = ""; ProjectName = "" }
                }
                Assert-ThrowsMessage `
                    -Action {
                        New-TranscriptBatchPlan `
                            -Rows $tooMany `
                            -RootDir $testRoot
                    } `
                    -ExpectedMessage "TooManyRows" `
                    -Message "More than six cards were accepted."

                Assert-ThrowsMessage `
                    -Action {
                        New-TranscriptBatchPlan `
                            -Rows @(
                                [pscustomobject]@{
                                    CardId = "one"
                                    Url = "https://youtu.be/one"
                                    ProjectName = "Missing"
                                }
                            ) `
                            -RootDir $testRoot
                    } `
                    -ExpectedMessage "ProjectMissing" `
                    -Message "A missing selected project was accepted."
            }
            finally {
                if (Test-Path -LiteralPath $testRoot) {
                    Remove-Item -LiteralPath $testRoot -Recurse -Force
                }
            }
        }
    },
    @{
        Name = "Result file actions resolve, read, and select the saved transcript"
        Run = {
            $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
                "transcript-gui-model-tests-" + [Guid]::NewGuid().ToString("N")
            )

            try {
                New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
                $resultPath = Join-Path $testRoot "result transcript.txt"
                $expectedText = "alpha " + [char]0x20AC
                [System.IO.File]::WriteAllText(
                    $resultPath,
                    $expectedText,
                    [System.Text.UTF8Encoding]::new($false)
                )

                $resolvedPath = Resolve-TranscriptResultFilePath -Path $resultPath
                Assert-Equal `
                    $resolvedPath `
                    ([System.IO.Path]::GetFullPath($resultPath)) `
                    "Result file path was not canonicalized."
                Assert-Equal `
                    (Read-TranscriptResultFileText -Path $resultPath) `
                    $expectedText `
                    "Result file contents were not read as UTF-8."
                Assert-Equal `
                    (Get-TranscriptExplorerSelectArgument -Path $resultPath) `
                    ('/select,"{0}"' -f ([System.IO.Path]::GetFullPath($resultPath))) `
                    "Explorer select argument changed."

                Assert-ThrowsMessage `
                    -Action {
                        Resolve-TranscriptResultFilePath `
                            -Path (Join-Path $testRoot "missing.txt")
                    } `
                    -ExpectedMessage "ResultFileMissing" `
                    -Message "A missing result file was accepted."
            }
            finally {
                if (Test-Path -LiteralPath $testRoot) {
                    Remove-Item -LiteralPath $testRoot -Recurse -Force
                }
            }
        }
    },
    @{
        Name = "Queue state continues after failure and reports totals"
        Run = {
            $items = @(
                [pscustomobject]@{ CardId = "one" },
                [pscustomobject]@{ CardId = "two" }
            )
            $state = New-TranscriptQueueState -Items $items

            Assert-True $state.IsRunning "A non-empty queue started idle."
            Assert-Equal `
                (Get-TranscriptQueueCurrentItem -State $state).CardId `
                "one" `
                "Wrong first queue item."

            Move-TranscriptQueueNext -State $state -Succeeded $false
            Assert-True $state.IsRunning "A failed item stopped the queue."
            Assert-Equal `
                (Get-TranscriptQueueCurrentItem -State $state).CardId `
                "two" `
                "Queue did not advance after failure."

            Move-TranscriptQueueNext -State $state -Succeeded $true
            $summary = Get-TranscriptQueueSummary -State $state
            Assert-Equal $summary.Total 2 "Queue total changed."
            Assert-Equal $summary.Completed 1 "Completed count changed."
            Assert-Equal $summary.Failed 1 "Failed count changed."
            Assert-True (-not $summary.IsRunning) "Finished queue remained active."
            Assert-Equal (Get-TranscriptQueueCurrentItem -State $state) $null "Finished queue exposed an item."
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
    throw "$failed GUI model test(s) failed."
}

Write-Host "$($tests.Count)/$($tests.Count) GUI model tests passed."
