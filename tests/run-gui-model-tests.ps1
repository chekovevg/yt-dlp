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
