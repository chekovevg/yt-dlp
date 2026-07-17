# YouTube Transcript Tool Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both the WinForms desktop app and the command-line interface reliably download and convert YouTube subtitles without treating warnings as failures or deleting pre-existing files.

**Architecture:** `transcript-tool.psm1` is the shared core for native process execution, language selection, temporary download workspaces, conversion, and error mapping. `transcript-tool-gui.ps1` and `download-subs.ps1` remain thin interfaces that preserve their current visible controls and command-line switches.

**Tech Stack:** Windows PowerShell 5.1, .NET Framework `System.Diagnostics.Process`, WinForms, custom PowerShell regression runners, official `yt-dlp.exe` stable binary.

## Global Constraints

- Keep Windows PowerShell 5.1 compatibility; do not require PowerShell 7 or Python.
- Keep both `youtube-transcript-tool.cmd` and `download-subs.cmd`.
- Keep the current visible WinForms layout and wording.
- Preserve CLI switches: `-List`, `-CleanOnly`, `-NoClean`, `-KeepSubs`, `-Srt`, `-CleanTranscript`, `-Prefer`, `-OutputDir`, and `-Langs`.
- Never delete or overwrite `.vtt`, `.srt`, or `.txt` files that existed before the current invocation. If any planned target exists, select the next free numeric stem (`-2`, `-3`, and so on) and use that same stem for coordinated transcript, review, and copied-subtitle artifacts.
- Keep transcript-specific normalization opt-in behind `-CleanTranscript`.
- Add a failing regression test before each production behavior change except the WinForms thread handoff, for which the user explicitly approved a launch/responding smoke test plus live verification instead of test-only UI hooks.

---

### Task 1: Capture native stdout and stderr safely

**Files:**
- Modify: `tests/run-transcript-tool-tests.ps1`
- Modify: `transcript-tool.psm1:101-137`

**Interfaces:**
- Produces: internal `ConvertTo-NativeArgument([string]) -> string`.
- Produces: exported `Invoke-TranscriptProcess([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory) -> PSCustomObject` with `ExitCode`, `StdOut`, `StdErr`, and `Output`; the CLI reuses it for `-List` and language detection.
- Updates: `Invoke-YtDlpJson` to use `Invoke-TranscriptProcess`.

- [ ] **Step 1: Add a reusable fake `yt-dlp.exe` builder and failing warning test**

Add `New-FakeYtDlp` near the top of `tests/run-transcript-tool-tests.ps1`. Compile a console executable whose `--dump-single-json` path writes a warning to stderr, valid JSON to stdout, and exits `0`; an URL containing `unavailable` writes `ERROR: Video unavailable` to stderr and exits `1`.

```powershell
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
```

Add tests that call `Invoke-YtDlpJson` under `$ErrorActionPreference = 'Stop'` and assert that the warning path returns `id = abc123`, while the unavailable path returns the friendly unavailable-video message.

- [ ] **Step 2: Run the module suite and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
```

Expected: the warning test fails with `NativeCommandError` or `RemoteException`, proving stderr bypasses the current exit-code handling.

- [ ] **Step 3: Implement quoted native invocation**

Add `ConvertTo-NativeArgument` using the Windows `CommandLineToArgvW` escaping rules: quote empty or whitespace-containing arguments, double backslashes before embedded quotes, and double trailing backslashes before the closing quote. Add `Invoke-TranscriptProcess` with `ProcessStartInfo.UseShellExecute = $false`, redirected stdout/stderr, `CreateNoWindow = $true`, asynchronous `ReadToEndAsync()`, and an explicit `WaitForExit()`.

Replace the direct `& $YtDlpPath ... 2>&1` call in `Invoke-YtDlpJson` with:

```powershell
$result = Invoke-TranscriptProcess -FilePath $YtDlpPath -ArgumentList @(
    '--skip-download', '--dump-single-json', '--no-warnings', '--no-playlist', $Url
)

if ($result.ExitCode -ne 0) {
    $message = $result.Output.Trim()
    # Preserve the existing invalid URL, unavailable video, and network mappings.
}

return ($result.StdOut | ConvertFrom-Json)
```

Replace the subtitle download call in `Save-TranscriptFromYoutube` with the same helper:

```powershell
$downloadResult = Invoke-TranscriptProcess -FilePath $tool -ArgumentList $args
$downloadOutput = $downloadResult.Output
$exitCode = $downloadResult.ExitCode
```

Add `Invoke-TranscriptProcess` to `Export-ModuleMember` so `download-subs.ps1` can use exactly the same stderr and exit-code behavior.

- [ ] **Step 4: Run the module suite and verify GREEN**

Run the command from Step 2. Expected: both new native-process tests pass and the original four tests remain green.

- [ ] **Step 5: Commit the isolated native-process fix**

```powershell
git add -- transcript-tool.psm1 tests/run-transcript-tool-tests.ps1
git commit -m "fix: handle yt-dlp warnings without aborting"
```

---

### Task 2: Select real subtitle tracks across empty and regional maps

**Files:**
- Modify: `tests/run-transcript-tool-tests.ps1`
- Modify: `transcript-tool.psm1:139-268`

**Interfaces:**
- Updates: `Get-SubtitleMapLanguages([object]) -> string[]` to exclude service tracks and unusable formats.
- Updates: `Find-LanguageTag([string[]], [string]) -> string|null` to accept empty arrays and regional variants.
- Keeps: `Resolve-TranscriptSubtitleChoice([object], [string])` return shape.

- [ ] **Step 1: Add four failing selection tests**

Add independent test cases for:

```powershell
$autoOnly = [pscustomobject]@{
    subtitles = $null
    automatic_captions = [pscustomobject]@{ ru = @([pscustomobject]@{ ext = 'vtt' }) }
}
$choice = Resolve-TranscriptSubtitleChoice -Info $autoOnly -Preference 'auto'
Assert-True ($choice.Tag -eq 'ru') 'Expected auto-only Russian captions.'
```

Also assert that manual-only `en` succeeds when automatic captions are absent, explicit `en` selects `en-AU`, and auto mode skips manual `live_chat` in favor of automatic `ja` with `ext = vtt`.

- [ ] **Step 2: Run the module suite and verify RED**

Expected: auto-only/manual-only tests fail with `ParameterBindingValidationException`, `en-AU` reports unavailable, and `live_chat` is selected.

- [ ] **Step 3: Implement empty collection, regional, and service-track rules**

Allow empty input explicitly:

```powershell
param(
    [AllowEmptyCollection()]
    [string[]]$AvailableTags = @(),
    [Parameter(Mandatory = $true)]
    [string]$Language
)
```

Filter `live_chat` and tags whose non-empty format list contains neither `vtt` nor `srt`. After exact candidates, select the first tag matching `^<language>(-|$)` case-insensitively. Preserve the `ru`, `en`, `de`, then fallback ordering.

- [ ] **Step 4: Run both suites and verify GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
```

Expected: all old and new tests pass.

- [ ] **Step 5: Commit subtitle selection**

```powershell
git add -- transcript-tool.psm1 tests/run-transcript-tool-tests.ps1
git commit -m "fix: select available subtitle tracks reliably"
```

---

### Task 3: Parse VTT and SRT structure without losing speech

**Files:**
- Modify: `tests/run-transcript-tool-tests.ps1`
- Modify: `transcript-tool.psm1:317-384`

**Interfaces:**
- Keeps: `Convert-SubtitleFileToTranscriptText([string]$Path, [switch]$TranscriptMode) -> string`; default behavior remains unchanged and Task 4 supplies the opt-in normalization implementation.
- Adds: internal `Test-SubtitleTimestamp([string]) -> bool`.
- Adds: internal `Format-TranscriptParagraphs([string[]]) -> string`.

- [ ] **Step 1: Add structural parser regressions**

Create a VTT fixture containing a full `NOTE` block, a `STYLE` block, an arbitrary cue id followed by a timestamp, the numeric caption `2026`, inline tags, HTML entities, and a repeated adjacent caption. Assert that block contents and cue ids are absent, `2026` is preserved, entities decode, and duplicates occur once.

Add a second fixture containing only headers/timestamps and assert that conversion throws `Subtitle file did not contain readable transcript text.`

- [ ] **Step 2: Run the module suite and verify RED**

Expected: comment/style contents leak, `2026` disappears, or the empty fixture returns an empty string.

- [ ] **Step 3: Replace the broad line filter with a stateful parser**

Iterate through `Get-Content -Encoding utf8` by index. Maintain `$block` until a blank line after `NOTE`, `STYLE`, or `REGION`. Treat a line as a cue identifier only when the next non-empty line matches a VTT/SRT timestamp. Treat a numeric line as an SRT sequence number only under the same look-ahead condition. Clean caption text with the existing markup removal, HTML decoding, non-breaking-space conversion, bracket removal, trimming, and adjacent deduplication.

After joining and punctuation cleanup, throw the exact empty-transcript error when no readable text remains. Move the current sentence grouping into `Format-TranscriptParagraphs` without changing its four-sentence/520-character limits.

- [ ] **Step 4: Run the module suite and verify GREEN**

Expected: all parser regressions and previous tests pass.

- [ ] **Step 5: Commit parser changes**

```powershell
git add -- transcript-tool.psm1 tests/run-transcript-tool-tests.ps1
git commit -m "fix: parse subtitle structure safely"
```

---

### Task 4: Move CLI downloads into the shared safe core

**Files:**
- Modify: `tests/run-download-subs-tests.ps1`
- Modify: `transcript-tool.psm1`
- Modify: `download-subs.ps1`

**Interfaces:**
- Adds: `Save-TranscriptFromSubtitleFile([string]$Path, [string]$OutputDir, [bool]$CleanTranscript) -> PSCustomObject` with `TextPath` and `ReviewPath`.
- Adds: `Save-TranscriptFromYoutubeCli([string]$Url, [string]$OutputDir, [string]$Preference, [string]$SubtitleLanguages, [bool]$NoClean, [bool]$KeepSubtitles, [bool]$Srt, [bool]$CleanTranscript, [string]$YtDlpPath, [scriptblock]$OnAttempt) -> PSCustomObject` with one result object containing `TextPath`, `ReviewPath`, `SubtitlePaths`, `OutputDir`, `FoundSubtitles`, `ExitCode`, `YtDlpExitCode`, bounded `Output`, and bounded `StdErr`.
- Keeps: every existing CLI parameter and exit-code convention.

- [ ] **Step 1: Add failing file-safety tests**

Extend the CLI test suite with three cases:

1. `-CleanOnly` creates text but leaves its input `.vtt` present.
2. An online run with two unrelated `.en.vtt` files beside the script leaves both present and converts only the fake executable's fresh output.
3. A run whose process working directory differs from the script directory still writes the expected result to the requested `-OutputDir`.

Add review regressions proving that pre-existing output bytes remain unchanged while new `.txt`, `.clean.txt`, `.review.txt`, `.vtt`, and `.srt` artifacts use coordinated `-2`/`-3` stems. Cover `-NoClean`, `-KeepSubs`, `-Srt`, explicit `-Langs`, exact public result shapes, callback output, bounded failure diagnostics, downloaded-despite-error diagnostics, temporary cleanup, and whitespace immediately inside brackets.

Update `Invoke-DownloadSubs` with an optional `WorkingDirectory` parameter used only by test case 3.

- [ ] **Step 2: Run the CLI suite and verify RED**

Expected: case 1 loses its source, case 2 deletes unrelated files or converts the newest unrelated file, and case 3 cannot find the freshly downloaded subtitle.

- [ ] **Step 3: Add shared subtitle-file saving**

Move the opt-in transcript normalization helpers from `download-subs.ps1` into `transcript-tool.psm1`. Implement `Save-TranscriptFromSubtitleFile` so it converts through the shared structural parser, writes `.txt` or `.clean.txt` in `OutputDir`, writes `.review.txt` only for transcript mode, and never deletes `Path` or overwrites an output. Acquire each candidate stem with a `CreateNew`/`DeleteOnClose` interprocess lock, write complete artifacts into an operation-GUID staging directory on the output volume, record stable file identities in a manifest, then publish with atomic no-replace renames and a final commit marker. Roll back interrupted publication only through identity-validated handles.

- [ ] **Step 4: Add safe CLI online saving**

Implement `Save-TranscriptFromYoutubeCli` with one top-level GUID temporary directory and one attempt subdirectory per language expression. Determine attempts from explicit `SubtitleLanguages`, explicit `Preference`, or detected video language followed by `ru`, `en`, and `de`. For each attempt invoke `yt-dlp` with both subtitle-source flags, explicit `-o` inside the attempt directory, and `vtt/best` or `srt/best` settings. Stop only when that attempt directory contains a new `.vtt` or `.srt`.

For `NoClean`, atomically reserve each coordinated current-run subtitle group in `OutputDir` and copy through the reserved streams. Otherwise select the preferred current-run file, atomically reserve every transcript/review/subtitle target for one stem, convert and copy through those streams, and release only this invocation's reservations on failure. Suppress output from `OnAttempt` so the function returns exactly one object. Carry the last process `Output` and `StdErr`, bounded to 2,000 characters each, in every result. Remove only the top-level temporary directory in `finally`.

- [ ] **Step 5: Replace CLI orchestration with module calls**

Keep the parameter block and console messages in `download-subs.ps1`. Import `transcript-tool.psm1`; route `-List` through `Invoke-TranscriptProcess`, `-CleanOnly` through `Save-TranscriptFromSubtitleFile`, and online work through `Save-TranscriptFromYoutubeCli`. Print the bounded last-attempt diagnostic when every attempt fails and include it in the downloaded-despite-error warning. Open Notepad only when a text result exists. Remove the old download-state comparison and `Remove-IntermediateSubtitleFiles` logic.

- [ ] **Step 6: Run both suites and verify GREEN**

Expected: all module tests and all CLI tests pass, including preservation of unrelated subtitle files.

- [ ] **Step 7: Commit the shared CLI core**

```powershell
git add -- transcript-tool.psm1 download-subs.ps1 tests/run-download-subs-tests.ps1
git commit -m "fix: isolate command-line subtitle downloads"
```

---

### Task 5: Keep the WinForms window responsive

**Files:**
- Create: `tests/run-gui-smoke-tests.ps1`
- Modify: `transcript-tool-gui.ps1:182-238`
- Modify: `README.md`

**Interfaces:**
- Adds: GUI-owned `$activeJob` and a 200 ms `System.Windows.Forms.Timer`.
- Keeps: all existing controls, labels, status strings, settings, and result display.

- [ ] **Step 1: Add a GUI launch smoke test**

Create `tests/run-gui-smoke-tests.ps1`. Repeat the production launcher semantics by passing `-WindowStyle Hidden` to `powershell.exe` before `-File transcript-tool-gui.ps1` (do not use the `Start-Process -WindowStyle Hidden` property, which also hides the WinForms window). Enumerate visible top-level windows for the exact child PID for up to ten seconds, require the title `YouTube Transcript Tool`, assert `Responding`, then stop only that exact process id in `finally`.

- [ ] **Step 2: Run the smoke test before editing**

Expected: PASS. This establishes that the existing window launches before changing its execution model.

- [ ] **Step 3: Move save work into a PowerShell background job**

On click, save settings, disable buttons, and start a job that imports the module and calls `Save-TranscriptFromYoutube`. Emit objects shaped as `{ Kind = 'Status'; Value = <status> }` and `{ Kind = 'Result'; Value = <result> }`. Start the WinForms timer.

On each timer tick, call `Receive-Job` without `-Keep`, map status objects through the existing localized status switch, store the result object, and when job state is complete or failed: stop the timer, show the result or the job's first error, remove the terminal job, re-enable controls, and enable Open Folder only after success. Before worker work begins, the GUI parent owns the operation GUID and exact staging/download paths. On form close, dispose the start gate and capture those values in a cleanup ticket without calling process termination synchronously. After `Application.Run` returns, terminate/dispose the process group, perform any safe identity fallback, remove the active job, roll back only identity-matching partial publication, and remove the validated operation workspaces.

- [ ] **Step 4: Run GUI smoke and backend suites**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-smoke-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
```

Expected: the GUI launches and responds; all backend tests pass.

- [ ] **Step 5: Document the responsive background behavior and commit**

Add the GUI smoke command to the README developer checks and state that the window remains usable while `yt-dlp` is running.

```powershell
git add -- transcript-tool-gui.ps1 tests/run-gui-smoke-tests.ps1 README.md
git commit -m "fix: run desktop transcript saves in background"
```

---

### Task 6: Update yt-dlp and establish repository hygiene

**Files:**
- Create: `.gitignore`
- Modify: `yt-dlp.exe`
- Modify: `README.md`

**Interfaces:**
- Keeps: local bundled executable discovery before `PATH` discovery.
- Documents: explicit stable update command and version check.

- [ ] **Step 1: Add `.gitignore` and verify generated files are ignored**

Create:

```gitignore
texts/
*.vtt
*.srt
*.part
*.ytdl
.lazyweb/
```

Run `git check-ignore texts/example.txt sample.vtt .lazyweb/report.json`. Expected: all three paths are printed.

- [ ] **Step 2: Download the current official stable binary to a temporary path**

Use GitHub's official latest-release API to obtain the tag, download `yt-dlp.exe` and that tag's `SHA2-256SUMS`, and compare the downloaded file's SHA-256 with the `yt-dlp.exe` manifest entry. Abort without replacing the bundled binary if they differ.

- [ ] **Step 3: Replace the binary and verify its version**

After checksum success, replace only `yt-dlp.exe`, run `.\yt-dlp.exe --version`, and assert it matches the API tag.

- [ ] **Step 4: Update README operations guidance**

Document both launchers, the safe meanings of `-NoClean` and `-KeepSubs`, the developer commands for all three suites, and the manual update command `.\yt-dlp.exe -U`. Do not add an automatic updater or GUI button.

- [ ] **Step 5: Run all tests and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-smoke-tests.ps1
git add -- .gitignore yt-dlp.exe README.md
git commit -m "chore: update yt-dlp and ignore generated files"
```

Expected: all suites pass and the committed binary reports the official stable tag.

---

### Task 7: Final syntax, integration, and safety verification

**Files:**
- Modify only if a verification failure identifies a specific defect.

**Interfaces:**
- Verifies the complete product behavior without adding new public interfaces.

- [ ] **Step 1: Parse every PowerShell source file**

Use `[System.Management.Automation.Language.Parser]::ParseFile` for every `.ps1` and `.psm1`. Expected: zero parser errors.

- [ ] **Step 2: Run every automated suite fresh**

Run all three test scripts in new `powershell.exe` processes. Expected: zero failures and exit code `0` from each.

- [ ] **Step 3: Run a real GUI-core transcript download**

Call `Save-TranscriptFromYoutube` for `https://www.youtube.com/watch?v=m5CoBnRl_dE` with a GUID temporary output directory, `Language auto`, and `KeepSubtitles false`. Assert that the text exists, is non-empty, contains no `WEBVTT` or timestamps, then delete only the GUID directory.

- [ ] **Step 4: Run a real CLI transcript download from another working directory**

Invoke `download-subs.ps1` from a separate GUID temporary working directory with an absolute GUID `-OutputDir`. Assert exit code `0`, at least one non-empty `.txt`, and no subtitle files created in the tool root or the external working directory. Delete only the two GUID directories.

- [ ] **Step 5: Verify version, checksum source, and worktree scope**

Confirm bundled version equals the latest official stable tag, re-check SHA-256 against the official manifest, run `git diff --check`, and inspect `git status --short` to ensure generated transcripts and user files were not staged.

- [ ] **Step 6: Commit only a verification-driven correction if needed**

If Steps 1-5 reveal a defect, first add a failing regression, make the smallest correction, rerun all steps, and commit only the affected source and test files. If all steps pass, create no empty commit.
