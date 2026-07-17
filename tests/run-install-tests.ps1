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

                $uninstallCommand = Join-Path $installDir "uninstall.cmd"
                Assert-True `
                    (Test-Path -LiteralPath $uninstallCommand -PathType Leaf) `
                    "Installer omitted the uninstall command."

                $uninstallShortcutPath = Join-Path `
                    $startMenuDir `
                    "Uninstall YouTube Transcript Tool.lnk"
                $uninstallShortcut = Get-ShortcutData -Path $uninstallShortcutPath
                Assert-True `
                    ($uninstallShortcut.TargetPath -eq [System.IO.Path]::GetFullPath($uninstallCommand)) `
                    "Uninstall shortcut targets the wrong command."
                Assert-True `
                    ($uninstallShortcut.WorkingDirectory -eq $canonicalInstallDir) `
                    "Uninstall shortcut uses the wrong working directory."

                $unrelatedShortcutPath = Join-Path $startMenuDir "Unrelated.lnk"
                [System.IO.File]::WriteAllText($unrelatedShortcutPath, "preserve shortcut")
                $settingsDir = Join-Path $testRoot "settings\YouTubeTranscriptTool"
                New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
                $settingsPath = Join-Path $settingsDir "settings.json"
                [System.IO.File]::WriteAllText($settingsPath, '{"language":"auto"}')

                & $uninstallCommand
                if ($LASTEXITCODE -ne 0) {
                    throw "Uninstaller exited with code $LASTEXITCODE."
                }

                $selfCleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while ((Test-Path -LiteralPath $uninstallCommand) -and
                    [DateTime]::UtcNow -lt $selfCleanupDeadline) {
                    Start-Sleep -Milliseconds 100
                }

                foreach ($relativePath in $expectedFiles) {
                    Assert-True `
                        (-not (Test-Path -LiteralPath (Join-Path $installDir $relativePath))) `
                        "Uninstaller left installed file $relativePath."
                }

                Assert-True `
                    (-not (Test-Path -LiteralPath $markerPath)) `
                    "Uninstaller left the installation marker."
                Assert-True `
                    ([System.IO.File]::ReadAllText($sentinelPath) -eq "preserve me") `
                    "Uninstaller changed an unrelated installation file."
                Assert-True `
                    ([System.IO.File]::ReadAllText($unrelatedShortcutPath) -eq "preserve shortcut") `
                    "Uninstaller changed an unrelated shortcut."
                Assert-True `
                    (Test-Path -LiteralPath $settingsPath -PathType Leaf) `
                    "Uninstaller removed user settings without permission."
                foreach ($shortcutPath in @(
                        $desktopShortcutPath,
                        $startMenuShortcutPath,
                        $uninstallShortcutPath
                    )) {
                    Assert-True `
                        (-not (Test-Path -LiteralPath $shortcutPath)) `
                        "Uninstaller left application shortcut $shortcutPath."
                }
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
    },
    @{
        Name = "Uninstaller rejects a marker for another installation directory"
        Run = {
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

                $markerPath = Join-Path $installDir ".install-manifest.json"
                $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
                $marker.InstallDir = Join-Path $testRoot "another-installation"
                $marker | ConvertTo-Json -Depth 4 |
                    Set-Content -LiteralPath $markerPath -Encoding UTF8

                $uninstallScript = Join-Path $installDir "uninstall.ps1"
                $previousErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = "Continue"
                    & powershell.exe `
                        -NoProfile `
                        -ExecutionPolicy Bypass `
                        -File $uninstallScript `
                        -InstallDir $installDir 2>$null
                    $exitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }

                Assert-True `
                    ($exitCode -ne 0) `
                    "Uninstaller accepted a marker for another directory."
                Assert-True `
                    (Test-Path -LiteralPath (Join-Path $installDir "youtube-transcript-tool.cmd") -PathType Leaf) `
                    "Rejected uninstall removed application files."
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
    },
    @{
        Name = "RemoveSettings deletes only the validated application settings directory"
        Run = {
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

                $settingsParent = Join-Path $testRoot "settings-root"
                $settingsDir = Join-Path $settingsParent "YouTubeTranscriptTool"
                New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
                [System.IO.File]::WriteAllText(
                    (Join-Path $settingsDir "settings.json"),
                    '{"language":"auto"}'
                )
                $siblingPath = Join-Path $settingsParent "preserve.txt"
                [System.IO.File]::WriteAllText($siblingPath, "preserve settings sibling")

                $uninstallCommand = Join-Path $installDir "uninstall.cmd"
                $previousErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = "Continue"
                    & $uninstallCommand -RemoveSettings -SettingsDir $settingsDir 2>$null
                    $exitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }

                Assert-True `
                    ($exitCode -eq 0) `
                    "RemoveSettings uninstall exited with code $exitCode."

                $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while ((Test-Path -LiteralPath $installDir) -and
                    [DateTime]::UtcNow -lt $cleanupDeadline) {
                    Start-Sleep -Milliseconds 100
                }

                Assert-True `
                    (-not (Test-Path -LiteralPath $settingsDir)) `
                    "RemoveSettings left the application settings directory."
                Assert-True `
                    ([System.IO.File]::ReadAllText($siblingPath) -eq "preserve settings sibling") `
                    "RemoveSettings changed a sibling settings file."
                Assert-True `
                    (-not (Test-Path -LiteralPath $installDir)) `
                    "Uninstall left an otherwise empty installation directory."
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
    },
    @{
        Name = "Package contains exactly the installable application files"
        Run = {
            $buildScript = Join-Path $repoRoot "build-package.ps1"
            if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
                throw "Package builder was not found: $buildScript"
            }

            $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
            $testRoot = Join-Path $temporaryRoot ("youtube-transcript-install-test-" + [Guid]::NewGuid().ToString("N"))
            $packagePath = Join-Path $testRoot "youtube-transcript-tool-windows.zip"

            try {
                New-Item -ItemType Directory -Path $testRoot | Out-Null
                & powershell.exe `
                    -NoProfile `
                    -ExecutionPolicy Bypass `
                    -File $buildScript `
                    -OutputPath $packagePath
                if ($LASTEXITCODE -ne 0) {
                    throw "Package builder exited with code $LASTEXITCODE."
                }

                Assert-True `
                    (Test-Path -LiteralPath $packagePath -PathType Leaf) `
                    "Package builder did not create the ZIP archive."

                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $archive = [System.IO.Compression.ZipFile]::OpenRead($packagePath)
                try {
                    $actualEntries = @(
                        $archive.Entries |
                            Where-Object { $_.Name } |
                            ForEach-Object { $_.FullName.Replace("\", "/") } |
                            Sort-Object
                    )
                }
                finally {
                    $archive.Dispose()
                }

                $expectedEntries = @(
                    Get-Content -LiteralPath $fileManifest |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { $_ -and -not $_.StartsWith("#") } |
                        ForEach-Object { "YouTubeTranscriptTool/" + $_.Replace("\", "/") } |
                        Sort-Object
                )

                Assert-True `
                    (($actualEntries -join "|") -eq ($expectedEntries -join "|")) `
                    ("Package entries did not match app-files.txt.`nActual: " +
                        ($actualEntries -join ", "))
                Assert-True `
                    (-not ($actualEntries | Where-Object {
                                $_ -match "(^|/)(tests|docs|\.git|\.worktrees)(/|$)"
                            })) `
                    "Package included development-only directories."
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
