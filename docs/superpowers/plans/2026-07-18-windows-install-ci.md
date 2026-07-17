# Windows Installation and CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe per-user Windows installer, uninstaller, distributable ZIP, and a GitHub Actions gate that verifies the complete application before merge.

**Architecture:** A checked-in `app-files.txt` is the single allowlist consumed by installation, uninstall metadata, and packaging. PowerShell scripts install into a current-user directory and create normal Windows shortcuts; a single `windows-latest` workflow runs parser checks, all regression suites, installer/package tests, and uploads the ZIP.

**Tech Stack:** Windows PowerShell 5.1, WScript.Shell COM shortcuts, JSON installation marker, `System.IO.Compression`, GitHub Actions Windows hosted runner.

## Global Constraints

- Do not require administrator elevation.
- Default installation directory is `%LOCALAPPDATA%\Programs\YouTubeTranscriptTool`.
- Preserve `%APPDATA%\YouTubeTranscriptTool\settings.json` unless uninstall receives `-RemoveSettings`.
- Copy and delete only files named by `app-files.txt` and the generated installation marker.
- Preserve unrelated files in custom installation and shortcut directories.
- Keep Windows PowerShell 5.1 compatibility.
- Keep the existing GUI and CLI behavior unchanged.
- Require a successful GitHub-hosted Windows workflow before merging PR #1.

---

### Task 1: Runtime manifest and per-user installer

**Files:**
- Create: `app-files.txt`
- Create: `install.cmd`
- Create: `install.ps1`
- Create: `tests/run-install-tests.ps1`

**Interfaces:**
- Produces: `app-files.txt`, one repository-relative runtime path per line.
- Produces: `install.ps1 -InstallDir <string> -DesktopDirectory <string> -StartMenuDirectory <string>`.
- Produces: installed `.install-manifest.json` with `SchemaVersion`, `InstallDir`, `Files`, and `Shortcuts`.

- [ ] **Step 1: Add a failing isolated installation test**

Create a custom assertion runner in `tests/run-install-tests.ps1`. Use a GUID directory beneath `[System.IO.Path]::GetTempPath()`, invoke `install.ps1` with explicit install/desktop/Start Menu paths, and assert:

```powershell
$expectedFiles = Get-Content -LiteralPath (Join-Path $repoRoot "app-files.txt") |
    Where-Object { $_ -and -not $_.StartsWith("#") }

foreach ($relativePath in $expectedFiles) {
    Assert-True `
        (Test-Path -LiteralPath (Join-Path $installDir $relativePath) -PathType Leaf) `
        "Installer omitted $relativePath."
}

Assert-True `
    (Test-Path -LiteralPath (Join-Path $installDir ".install-manifest.json") -PathType Leaf) `
    "Installer omitted its installation marker."
Assert-True `
    (-not (Test-Path -LiteralPath (Join-Path $installDir "tests"))) `
    "Installer copied development tests."
```

Load all three `.lnk` files through `WScript.Shell.CreateShortcut()` and assert that application links target the installed `youtube-transcript-tool.cmd`, the uninstall link targets installed `uninstall.cmd`, and all working directories equal the canonical installation directory.

- [ ] **Step 2: Run the installer test and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-install-tests.ps1
```

Expected: non-zero exit because `app-files.txt` and `install.ps1` do not exist.

- [ ] **Step 3: Add the runtime allowlist and command launcher**

Create `app-files.txt` containing exactly:

```text
README.md
app-files.txt
create-desktop-shortcut.ps1
download-subs.cmd
download-subs.ps1
install.cmd
install.ps1
transcript-job-lifecycle.ps1
transcript-tool-gui.ps1
transcript-tool.psm1
transcript-worker.ps1
youtube-transcript-tool.cmd
yt-dlp.exe
```

Create `install.cmd`:

```batch
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
```

- [ ] **Step 4: Implement validated installation and shortcuts**

In `install.ps1`, define parameters with production defaults:

```powershell
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Programs\YouTubeTranscriptTool"),
    [string]$DesktopDirectory = [Environment]::GetFolderPath("Desktop"),
    [string]$StartMenuDirectory = (Join-Path ([Environment]::GetFolderPath("Programs")) "YouTube Transcript Tool")
)
```

Canonicalize every path with `[System.IO.Path]::GetFullPath()`. Reject an installation directory equal to its filesystem root, the user profile, or `%LOCALAPPDATA%`. Read `app-files.txt`, reject rooted entries or entries containing `..`, and verify every source file before creating the destination.

Copy the allowlisted files into a GUID staging directory beside the target, create the destination, then copy only those staged files into the installation directory. Write `.install-manifest.json` only after all known files are present:

```powershell
$marker = [pscustomobject]@{
    SchemaVersion = 1
    InstallDir = $canonicalInstallDir
    Files = @($runtimeFiles)
    Shortcuts = @($desktopShortcut, $startMenuShortcut, $uninstallShortcut)
}
$marker | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $markerPath -Encoding UTF8
```

Create shortcuts with `WScript.Shell`; set `TargetPath`, `WorkingDirectory`, `Description`, and the existing Windows icon. Always remove only the exact GUID staging directory in `finally`.

- [ ] **Step 5: Verify installation and idempotent update**

Run the test twice against the same isolated destination. Expected: both installs exit `0`, all expected files remain, the marker is valid JSON, shortcuts still target the installed launcher, and an unrelated sentinel file remains unchanged.

- [ ] **Step 6: Commit the installer slice**

```powershell
git add -- app-files.txt install.cmd install.ps1 tests/run-install-tests.ps1
git commit -m "feat: add per-user Windows installer"
```

---

### Task 2: Safe uninstall

**Files:**
- Modify: `app-files.txt`
- Create: `uninstall.cmd`
- Create: `uninstall.ps1`
- Modify: `tests/run-install-tests.ps1`

**Interfaces:**
- Consumes: installed `.install-manifest.json` from Task 1.
- Produces: `uninstall.ps1 -InstallDir <string> [-RemoveSettings]`.
- Produces: `uninstall.cmd`, which invokes PowerShell and then removes only its own batch file and an empty installation directory.

- [ ] **Step 1: Add failing uninstall safety tests**

Extend `tests/run-install-tests.ps1` to place `unrelated.keep` in the installation directory and a fake unrelated shortcut beside the application shortcuts. Invoke `uninstall.cmd`, then assert:

```powershell
Assert-True (Test-Path -LiteralPath $unrelatedFile) "Uninstall deleted an unrelated file."
Assert-True (Test-Path -LiteralPath $unrelatedShortcut) "Uninstall deleted an unrelated shortcut."
Assert-True (-not (Test-Path -LiteralPath $desktopShortcut)) "Desktop shortcut remained."
Assert-True (-not (Test-Path -LiteralPath $startMenuShortcut)) "Start Menu shortcut remained."
Assert-True (-not (Test-Path -LiteralPath $markerPath)) "Installation marker remained."
```

Add a settings fixture under an explicit `-SettingsDir` test path and assert it remains without `-RemoveSettings` and is removed with the switch. Add a tampered-marker test whose `InstallDir` differs from the requested canonical directory and assert uninstall fails without removing any file.

- [ ] **Step 2: Run the focused test and verify RED**

Run the installer test. Expected: failure because uninstall entry points do not exist.

- [ ] **Step 3: Implement marker-bound removal**

Add `uninstall.cmd` and `uninstall.ps1` to `app-files.txt` before implementing removal, so every subsequent install includes the uninstaller.

`uninstall.ps1` accepts:

```powershell
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Programs\YouTubeTranscriptTool"),
    [switch]$RemoveSettings,
    [string]$SettingsDir = (Join-Path $env:APPDATA "YouTubeTranscriptTool")
)
```

Read `.install-manifest.json`; require `SchemaVersion -eq 1` and exact canonical equality between marker and requested installation paths. For every marker file, reject rooted or parent-traversing values and prove its canonical path starts with the canonical installation path plus a directory separator. Remove marker-listed files except `uninstall.cmd`, delete the marker, and remove only empty child directories.

For each marker shortcut, load it through WScript.Shell and delete it only when its canonical target is inside the installation directory. If `-RemoveSettings` is present, canonicalize the requested settings path and require its leaf directory to equal `YouTubeTranscriptTool` before removing it.

- [ ] **Step 4: Add the self-cleaning command entry point**

Create `uninstall.cmd`:

```batch
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -InstallDir "%~dp0" %*
if errorlevel 1 exit /b %ERRORLEVEL%
del "%~f0" & rmdir "%~dp0" 2>nul
```

The final `rmdir` is intentionally non-recursive, so it succeeds only when no unrelated files remain.

- [ ] **Step 5: Verify uninstall and preservation behavior**

Run the installer suite. Expected: installation, idempotent reinstall, tamper rejection, shortcut validation, uninstall, unrelated-file preservation, and settings behavior all pass.

- [ ] **Step 6: Commit safe uninstall**

```powershell
git add -- uninstall.cmd uninstall.ps1 tests/run-install-tests.ps1
git commit -m "feat: add safe Windows uninstall"
```

---

### Task 3: Distributable ZIP and user instructions

**Files:**
- Create: `build-package.ps1`
- Modify: `app-files.txt`
- Modify: `tests/run-install-tests.ps1`
- Modify: `README.md`

**Interfaces:**
- Consumes: `app-files.txt`.
- Produces: `build-package.ps1 -OutputPath <string>`.
- Produces: `youtube-transcript-tool-windows.zip` with one top-level `YouTubeTranscriptTool/` directory.

- [ ] **Step 1: Add a failing package-content test**

Invoke `build-package.ps1` into the isolated test directory. Open it with `System.IO.Compression.ZipFile`, normalize entry names to `/`, and assert the non-directory entries equal the allowlist exactly, each beneath `YouTubeTranscriptTool/`, with no `tests/`, `docs/`, `.git/`, `.worktrees/`, transcript, or local files.

- [ ] **Step 2: Run the focused test and verify RED**

Expected: failure because `build-package.ps1` does not exist.

- [ ] **Step 3: Implement package creation from the allowlist**

Add `build-package.ps1` to `app-files.txt`. In the script, validate the output extension is `.zip`, validate every manifest entry exactly as the installer does, copy entries into a GUID staging directory under `YouTubeTranscriptTool`, remove an existing output file only when it is the exact requested ZIP path, and call:

```powershell
Compress-Archive `
    -LiteralPath (Join-Path $stagingRoot "YouTubeTranscriptTool") `
    -DestinationPath $canonicalOutputPath `
    -CompressionLevel Optimal
```

Remove only the exact GUID staging directory in `finally`.

- [ ] **Step 4: Rewrite README installation entry points**

Place a concise `Install on Windows` section before manual/CLI usage:

1. Download and extract the repository ZIP or CI package.
2. Double-click `install.cmd`.
3. Launch `YouTube Transcript Tool` from Start Menu or desktop.
4. Run the installed `uninstall.cmd` or Start Menu uninstall shortcut to remove it.

Retain a `Portable use` subsection for direct `youtube-transcript-tool.cmd` launch, and document that installation is per-user and does not need admin rights.

- [ ] **Step 5: Verify package and all local suites**

Run installer tests and the existing four suites. Expected: all exit `0`; package entry set matches the manifest exactly.

- [ ] **Step 6: Commit packaging and docs**

```powershell
git add -- app-files.txt build-package.ps1 tests/run-install-tests.ps1 README.md
git commit -m "feat: package Windows application"
```

---

### Task 4: GitHub Actions merge gate

**Files:**
- Create: `.github/workflows/windows-ci.yml`

**Interfaces:**
- Produces: check run `Windows CI / Test and package`.
- Produces: workflow artifact `youtube-transcript-tool-windows`.

- [ ] **Step 1: Add the Windows workflow**

Create a workflow with this structure:

```yaml
name: Windows CI

on:
  pull_request:
    branches: [desktop-transcript-tool]
  push:
    branches: [desktop-transcript-tool]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: windows-ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  verify:
    name: Test and package
    runs-on: windows-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v6
      - name: Parse PowerShell sources
        shell: powershell
        run: |
          $ErrorActionPreference = "Stop"
          $failed = $false
          $files = @(git ls-files -- "*.ps1" "*.psm1")
          foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
              (Join-Path $PWD $file),
              [ref]$tokens,
              [ref]$errors
            )
            if ($errors.Count -gt 0) {
              $failed = $true
              $errors | ForEach-Object { Write-Error "${file}: $($_.Message)" }
            }
          }
          if ($failed) { exit 1 }
          Write-Host "Parsed $($files.Count) PowerShell files."
      - name: Run regression suites
        shell: powershell
        run: |
          $ErrorActionPreference = "Stop"
          $tests = @(
            ".\tests\run-gui-smoke-tests.ps1",
            ".\tests\run-gui-job-lifecycle-tests.ps1",
            ".\tests\run-transcript-tool-tests.ps1",
            ".\tests\run-download-subs-tests.ps1",
            ".\tests\run-install-tests.ps1"
          )
          foreach ($test in $tests) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
          }
      - name: Build Windows package
        shell: powershell
        run: .\build-package.ps1 -OutputPath .\dist\youtube-transcript-tool-windows.zip
      - name: Upload Windows package
        uses: actions/upload-artifact@v7
        with:
          name: youtube-transcript-tool-windows
          path: dist/youtube-transcript-tool-windows.zip
          if-no-files-found: error
          retention-days: 14
```

The parser step must fail on any parser error, and the suite step must invoke the GUI smoke, lifecycle, module, CLI, and installer scripts explicitly with Windows PowerShell 5.1 semantics.

- [ ] **Step 2: Validate workflow syntax and local parity**

Parse the YAML with the bundled workspace Python/PyYAML runtime or another already-installed YAML parser. Run the exact parser and suite commands from the workflow locally. Expected: YAML parses, every command exits `0`, and the ZIP exists.

- [ ] **Step 3: Commit and push CI**

```powershell
git add -- .github/workflows/windows-ci.yml
git commit -m "ci: verify and package Windows app"
git push origin codex/transcript-reliability
```

- [ ] **Step 4: Wait for the GitHub-hosted run**

Use `gh pr checks 1 --watch --interval 10`. Expected: `Windows CI / Test and package` completes successfully. If it fails, inspect `gh run view <id> --log-failed`, add the smallest regression-backed correction, push, and wait again.

- [ ] **Step 5: Mark ready and merge**

```powershell
gh pr ready 1
gh pr merge 1 --merge
```

Expected: PR #1 state is `MERGED`, base branch contains the CI workflow, and the merge commit is visible on `origin/desktop-transcript-tool`.

- [ ] **Step 6: Synchronize and verify the local base**

From `D:\Tools\yt-dlp`, fetch and fast-forward `desktop-transcript-tool`, then run the complete local regression set once on the merged result. Do not add or delete the unrelated untracked `скрипт.txt`.
