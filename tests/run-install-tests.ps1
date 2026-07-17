$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $repoRoot "install.ps1"
$fileManifest = Join-Path $repoRoot "app-files.txt"

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

function Invoke-Installer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir,

        [Parameter(Mandatory = $true)]
        [string]$DesktopDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StartMenuDirectory
    )

    if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
        throw "Installer script was not found: $installScript"
    }

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $installScript `
        -InstallDir $InstallDir `
        -DesktopDirectory $DesktopDirectory `
        -StartMenuDirectory $StartMenuDirectory

    if ($LASTEXITCODE -ne 0) {
        throw "Installer exited with code $LASTEXITCODE."
    }
}

function Get-ShortcutData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Assert-True `
        (Test-Path -LiteralPath $Path -PathType Leaf) `
        "Shortcut was not created: $Path"

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)

    return [pscustomobject]@{
        TargetPath = [System.IO.Path]::GetFullPath($shortcut.TargetPath)
        WorkingDirectory = [System.IO.Path]::GetFullPath($shortcut.WorkingDirectory)
    }
}

$tests = @(
    @{
        Name = "Installer copies only runtime files and creates stable shortcuts"
        Run = {
            if (-not (Test-Path -LiteralPath $fileManifest -PathType Leaf)) {
                throw "Application file manifest was not found: $fileManifest"
            }

            $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
            $testRoot = Join-Path $temporaryRoot ("youtube-transcript-install-test-" + [Guid]::NewGuid().ToString("N"))
            $installDir = Join-Path $testRoot "installed"
            $desktopDir = Join-Path $testRoot "desktop"
            $startMenuDir = Join-Path $testRoot "start-menu"

            try {
                New-Item -ItemType Directory -Path $testRoot | Out-Null

                Invoke-Installer `
                    -InstallDir $installDir `
                    -DesktopDirectory $desktopDir `
                    -StartMenuDirectory $startMenuDir

                $expectedFiles = @(
                    Get-Content -LiteralPath $fileManifest |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { $_ -and -not $_.StartsWith("#") }
                )

                foreach ($relativePath in $expectedFiles) {
                    Assert-True `
                        (Test-Path -LiteralPath (Join-Path $installDir $relativePath) -PathType Leaf) `
                        "Installer omitted $relativePath."
                }

                $markerPath = Join-Path $installDir ".install-manifest.json"
                Assert-True `
                    (Test-Path -LiteralPath $markerPath -PathType Leaf) `
                    "Installer omitted its installation marker."

                $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
                Assert-True ($marker.SchemaVersion -eq 1) "Unexpected installation marker schema."
                Assert-True `
                    ([System.IO.Path]::GetFullPath($marker.InstallDir) -eq [System.IO.Path]::GetFullPath($installDir)) `
                    "Installation marker recorded the wrong destination."
                Assert-True `
                    (@($marker.Files).Count -eq $expectedFiles.Count) `
                    "Installation marker recorded the wrong file count."

                Assert-True `
                    (-not (Test-Path -LiteralPath (Join-Path $installDir "tests"))) `
                    "Installer copied development tests."
                Assert-True `
                    (-not (Test-Path -LiteralPath (Join-Path $installDir "docs"))) `
                    "Installer copied development documents."

                $canonicalInstallDir = [System.IO.Path]::GetFullPath($installDir)
                $expectedLauncher = [System.IO.Path]::GetFullPath(
                    (Join-Path $installDir "youtube-transcript-tool.cmd")
                )
                $desktopShortcutPath = Join-Path $desktopDir "YouTube Transcript Tool.lnk"
                $startMenuShortcutPath = Join-Path $startMenuDir "YouTube Transcript Tool.lnk"

                foreach ($shortcutPath in @($desktopShortcutPath, $startMenuShortcutPath)) {
                    $shortcut = Get-ShortcutData -Path $shortcutPath
                    Assert-True `
                        ($shortcut.TargetPath -eq $expectedLauncher) `
                        "Application shortcut targets the wrong launcher."
                    Assert-True `
                        ($shortcut.WorkingDirectory -eq $canonicalInstallDir) `
                        "Application shortcut uses the wrong working directory."
                }

                $sentinelPath = Join-Path $installDir "unrelated.keep"
                [System.IO.File]::WriteAllText($sentinelPath, "preserve me")

                Invoke-Installer `
                    -InstallDir $installDir `
                    -DesktopDirectory $desktopDir `
                    -StartMenuDirectory $startMenuDir

                Assert-True `
                    ([System.IO.File]::ReadAllText($sentinelPath) -eq "preserve me") `
                    "Reinstall changed an unrelated file."
            }
            finally {
                if (Test-Path -LiteralPath $testRoot) {
                    $resolvedTestRoot = [System.IO.Path]::GetFullPath(
                        (Resolve-Path -LiteralPath $testRoot).Path
                    )
                    $expectedPrefix = Join-Path $temporaryRoot "youtube-transcript-install-test-"
                    if (-not $resolvedTestRoot.StartsWith(
                            $expectedPrefix,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )) {
                        throw "Refusing to clean an unexpected installer test path: $resolvedTestRoot"
                    }

                    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
                }
            }
        }
    }
)

$passed = 0
foreach ($test in $tests) {
    try {
        & $test.Run
        $passed++
        Write-Host "PASS $($test.Name)"
    }
    catch {
        Write-Host "FAIL $($test.Name)"
        Write-Host $_.Exception.Message
    }
}

Write-Host "$passed/$($tests.Count) installer tests passed."
if ($passed -ne $tests.Count) {
    exit 1
}
