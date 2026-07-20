# Batch Video Queue and Project Folders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Russian Windows GUI that sequentially processes up to six YouTube videos, routes each transcript to the root or one project folder, and exposes clear copy actions.

**Architecture:** Keep the existing one-video worker and lifecycle cleanup intact. Add a testable GUI model module for projects, batch planning, and queue state; add a focused WinForms view module for adaptive controls; make `transcript-tool-gui.ps1` the coordinator that runs one existing worker at a time.

**Tech Stack:** Windows PowerShell 5+, WinForms, `System.Drawing`, existing `yt-dlp.exe`, custom PowerShell regression scripts.

## Global Constraints

- The GUI is Russian-only.
- The queue contains one to six cards and runs non-empty cards top-to-bottom.
- One failed card does not stop later cards.
- Downloads remain sequential; no parallel jobs.
- The desktop GUI always passes `KeepSubtitles=0` and exposes no `.vtt` option.
- Projects are immediate child folders of the selected root; nested projects are unsupported.
- Closing the form retains the existing current-worker identity-safe cleanup.
- There is no visible cancel button.
- Inputs are disabled while a queue or retry is active.

## File Structure

- Create `transcript-gui-model.psm1`: project validation/discovery/resolution, immutable batch planning, and mutable sequential queue state.
- Create `transcript-gui-view.psm1`: Russian text loading, resizable WinForms layout, video card factory, card state rendering, and project dialog.
- Create `ui-text.ru.json`: UTF-8 Russian labels and validation messages loaded explicitly with `-Encoding UTF8` for Windows PowerShell 5.
- Modify `transcript-tool-gui.ps1`: bind view events, coordinate one worker at a time, continue after item failure, and perform clipboard/root actions.
- Create `tests/run-gui-model-tests.ps1`: deterministic model tests with temporary project roots.
- Create `tests/run-gui-view-tests.ps1`: construct controls without displaying the form and inspect layout/accessibility properties.
- Modify `tests/run-gui-smoke-tests.ps1`: confirm the redesigned top-level window launches and responds.
- Modify `app-files.txt`: package both modules and the text resource.
- Modify `README.md`: document queue, projects, and copy actions; remove desktop `.vtt` instructions.

---

### Task 1: Project folder model

**Files:**
- Create: `transcript-gui-model.psm1`
- Create: `tests/run-gui-model-tests.ps1`

**Interfaces:**
- Produces: `Get-TranscriptProjectNameValidation -Name <string>` returning `{ IsValid, Name, ErrorCode }`.
- Produces: `Get-TranscriptProjectNames -RootDir <string>` returning sorted immediate directory names.
- Produces: `Resolve-TranscriptProjectOutputDirectory -RootDir <string> -ProjectName <string> [-RequireExisting]` returning a canonical full path.
- Produces: `New-TranscriptProjectDirectory -RootDir <string> -Name <string>` returning the created full path.
- Produces: `Assert-TranscriptOutputDirectoriesWritable -OutputDirs <string[]>`, which probes every unique batch destination before the first worker starts.

- [ ] **Step 1: Write failing project validation and discovery tests**

Add a small assertion harness and cases for trimming, empty names, separators, invalid characters, trailing dot/space, device names, length, immediate discovery, transient-directory exclusion, root mapping, child mapping, and traversal rejection:

```powershell
$modelPath = Join-Path $root "transcript-gui-model.psm1"
Import-Module $modelPath -Force

$valid = Get-TranscriptProjectNameValidation -Name "  Research  "
Assert-True $valid.IsValid "A normal project name was rejected."
Assert-Equal $valid.Name "Research" "Project name was not trimmed."

foreach ($invalid in @("", ".", "..", "a/b", "a\\b", "bad:name", "trail.", "trail ", "CON")) {
    $validation = Get-TranscriptProjectNameValidation -Name $invalid
    Assert-True (-not $validation.IsValid) "Invalid project name was accepted: $invalid"
}

$rootProject = Resolve-TranscriptProjectOutputDirectory -RootDir $testRoot -ProjectName ""
Assert-Equal $rootProject ([System.IO.Path]::GetFullPath($testRoot)) "Root mapping changed."
```

- [ ] **Step 2: Run the model tests and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-model-tests.ps1
```

Expected: FAIL because `transcript-gui-model.psm1` or the project functions do not exist.

- [ ] **Step 3: Implement the project functions**

Use one canonical root prefix and reject every path that does not remain below it:

```powershell
function Get-TranscriptProjectNameValidation {
    param([AllowEmptyString()][string]$Name)
    $trimmed = ([string]$Name).Trim()
    $errorCode = $null
    if (-not $trimmed) { $errorCode = "Empty" }
    elseif ($trimmed.Length -gt 80) { $errorCode = "TooLong" }
    elseif ($trimmed -in ".", "..") { $errorCode = "Relative" }
    elseif ($trimmed.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { $errorCode = "InvalidCharacters" }
    elseif ($trimmed.EndsWith(".") -or $trimmed.EndsWith(" ")) { $errorCode = "TrailingDotOrSpace" }
    elseif ($trimmed -match "(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$") { $errorCode = "Reserved" }
    [pscustomobject]@{ IsValid = ($null -eq $errorCode); Name = $trimmed; ErrorCode = $errorCode }
}

function Resolve-TranscriptProjectOutputDirectory {
    param([string]$RootDir, [AllowEmptyString()][string]$ProjectName, [switch]$RequireExisting)
    $root = [System.IO.Path]::GetFullPath($RootDir).TrimEnd("\\")
    if ([string]::IsNullOrWhiteSpace($ProjectName)) { return $root }
    $validation = Get-TranscriptProjectNameValidation -Name $ProjectName
    if (-not $validation.IsValid) { throw [System.ArgumentException]::new($validation.ErrorCode) }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $validation.Name))
    $prefix = $root + "\\"
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [System.ArgumentException]::new("OutsideRoot")
    }
    if ($RequireExisting -and -not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("ProjectMissing")
    }
    return $candidate
}
```

`Get-TranscriptProjectNames` must enumerate with `-Directory`, exclude `.youtube-transcript-operation-*`, select `Name`, and `Sort-Object`. `New-TranscriptProjectDirectory` must validate, reject an existing path, call `New-Item -ItemType Directory`, and return the canonical path.

`Assert-TranscriptOutputDirectoriesWritable` must canonicalize and de-duplicate paths, require each to be an existing directory, create a uniquely named probe file with `FileMode.CreateNew`, dispose it, and delete only that exact probe in `finally`. Tests use a normal temporary directory for success and a regular file passed as a directory for failure.

- [ ] **Step 4: Run the model tests and verify GREEN**

Run the command from Step 2. Expected: every project-model case prints `PASS` and the process exits 0.

- [ ] **Step 5: Commit the project model**

```powershell
git add -- transcript-gui-model.psm1 tests/run-gui-model-tests.ps1
git commit -m "feat: add transcript project model"
```

### Task 2: Batch plan and sequential queue state

**Files:**
- Modify: `transcript-gui-model.psm1`
- Modify: `tests/run-gui-model-tests.ps1`

**Interfaces:**
- Consumes: `Resolve-TranscriptProjectOutputDirectory` from Task 1.
- Produces: `New-TranscriptBatchPlan -Rows <object[]> -RootDir <string> -Language <string>`.
- Produces: `New-TranscriptQueueState -Items <object[]>`, `Get-TranscriptQueueCurrentItem -State <object>`, `Move-TranscriptQueueNext -State <object> -Succeeded <bool>`, and `Get-TranscriptQueueSummary -State <object>`.

- [ ] **Step 1: Add failing batch tests**

Test ignored blank rows, visual order, root/project mapping, maximum six cards, no-active-row failure, continuation after a failed item, and final counts:

```powershell
$rows = @(
    [pscustomobject]@{ CardId = "one"; Url = " https://youtu.be/one "; ProjectName = "Research" },
    [pscustomobject]@{ CardId = "blank"; Url = " "; ProjectName = "" },
    [pscustomobject]@{ CardId = "two"; Url = "https://youtu.be/two"; ProjectName = "" }
)
$plan = @(New-TranscriptBatchPlan -Rows $rows -RootDir $testRoot -Language "ru")
Assert-Equal $plan.Count 2 "Blank rows were not ignored."
Assert-Equal $plan[0].CardId "one" "Batch order changed."
Assert-Equal $plan[1].CardId "two" "Batch order changed."

$state = New-TranscriptQueueState -Items $plan
Assert-Equal (Get-TranscriptQueueCurrentItem -State $state).CardId "one" "Wrong first item."
Move-TranscriptQueueNext -State $state -Succeeded $false
Assert-Equal (Get-TranscriptQueueCurrentItem -State $state).CardId "two" "Failure stopped the queue."
Move-TranscriptQueueNext -State $state -Succeeded $true
$summary = Get-TranscriptQueueSummary -State $state
Assert-Equal $summary.Failed 1 "Failed count changed."
Assert-Equal $summary.Completed 1 "Completed count changed."
Assert-True (-not $summary.IsRunning) "Queue did not become idle."
```

- [ ] **Step 2: Run tests and verify RED**

Run the GUI model suite. Expected: FAIL because `New-TranscriptBatchPlan` is not defined.

- [ ] **Step 3: Implement the minimal state machine**

```powershell
function New-TranscriptBatchPlan {
    param([object[]]$Rows, [string]$RootDir, [ValidateSet("auto", "ru", "en", "de")][string]$Language)
    if (@($Rows).Count -gt 6) { throw [System.ArgumentException]::new("TooManyRows") }
    $items = @()
    foreach ($row in @($Rows)) {
        $url = ([string]$row.Url).Trim()
        if (-not $url) { continue }
        $outputDir = Resolve-TranscriptProjectOutputDirectory `
            -RootDir $RootDir -ProjectName ([string]$row.ProjectName) -RequireExisting
        $items += [pscustomobject]@{
            CardId = [string]$row.CardId
            Url = $url
            ProjectName = [string]$row.ProjectName
            OutputDir = $outputDir
            Language = $Language
        }
    }
    if ($items.Count -eq 0) { throw [System.ArgumentException]::new("NoVideos") }
    return @($items)
}

function New-TranscriptQueueState {
    param([object[]]$Items)
    [pscustomobject]@{ Items = @($Items); NextIndex = 0; Completed = 0; Failed = 0; IsRunning = (@($Items).Count -gt 0) }
}
```

`Get-TranscriptQueueCurrentItem` returns `$null` when idle. `Move-TranscriptQueueNext` increments either `Completed` or `Failed`, advances `NextIndex`, and sets `IsRunning=$false` at the end. `Get-TranscriptQueueSummary` returns a new object and does not expose mutable internal arrays.

- [ ] **Step 4: Run tests and verify GREEN**

Run the GUI model suite. Expected: all project and queue cases pass.

- [ ] **Step 5: Commit batch planning**

```powershell
git add -- transcript-gui-model.psm1 tests/run-gui-model-tests.ps1
git commit -m "feat: add sequential transcript batch model"
```

### Task 3: Adaptive WinForms view and Russian resources

**Files:**
- Create: `ui-text.ru.json`
- Create: `transcript-gui-view.psm1`
- Create: `tests/run-gui-view-tests.ps1`

**Interfaces:**
- Produces: `Get-TranscriptUiText -Path <string>`.
- Produces: `New-TranscriptMainView -UiText <object> -Settings <object> -Projects <string[]>`.
- Produces: `New-TranscriptVideoCardView -UiText <object> -Index <int> -Projects <string[]>`.
- Produces: `Set-TranscriptVideoCardState -Card <object> -State <string> [-Message <string>]`.
- Produces: `Show-TranscriptProjectDialog -Owner <Form> -UiText <object> -RootDir <string>` returning a project name or `$null`.

- [ ] **Step 1: Write failing view-construction tests**

Construct the form without calling `Application.Run` and assert:

```powershell
$uiText = Get-TranscriptUiText -Path (Join-Path $root "ui-text.ru.json")
$view = New-TranscriptMainView `
    -UiText $uiText `
    -Settings ([pscustomobject]@{ OutputDir = $testRoot; Language = "ru" }) `
    -Projects @("Research")

Assert-True $view.Form.MinimumSize.Width -ge 720 "Minimum width is too small."
Assert-True $view.Form.MinimumSize.Height -ge 520 "Minimum height is too small."
Assert-True $view.VideoList.AutoScroll "Video list does not scroll."
Assert-True ($null -eq $view.KeepSubtitlesBox) "The removed VTT option is still exposed."
Assert-Equal $view.LanguageBox.Items.Count 4 "Language choices changed."

$card = New-TranscriptVideoCardView -UiText $uiText -Index 2 -Projects @("Research")
Assert-Equal $card.ClearButton.AccessibleName $uiText.ClearUrl "Clear action is not accessible."
Assert-True $card.RemoveButton.Visible "Added cards cannot be removed."
Assert-True (-not $card.CopyTextButton.Visible) "Copy action is visible before success."
```

- [ ] **Step 2: Run view tests and verify RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-view-tests.ps1
```

Expected: FAIL because the resource and view module do not exist.

- [ ] **Step 3: Add the UTF-8 resource**

Include exact keys for title, folder, browse, language labels, add/remove/clear, project controls, states, queue summaries, clipboard feedback, and project validation. Load it with:

```powershell
function Get-TranscriptUiText {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}
```

- [ ] **Step 4: Implement adaptive form and card factories**

Use nested `TableLayoutPanel` and `FlowLayoutPanel` controls with `Dock=Fill`, `AutoSize`, and `AutoScroll`; do not use absolute card coordinates. Return a `PSCustomObject` containing stable references to every interactive control. The URL host is a two-column panel with the textbox filling the first column and a flat `×` clear button in the second. The project selector uses items shaped as `{ Label, Value }`, sets `DisplayMember="Label"`, and defaults to `{ Label="Без проекта"; Value="" }`. Existing projects use the same name for both fields. The first card hides `RemoveButton`; later cards show it.

`Set-TranscriptVideoCardState` supports `Idle`, `Queued`, `Running`, `Success`, and `Error`, and controls visibility as follows:

```powershell
$Card.CopyTextButton.Visible = ($State -eq "Success")
$Card.RetryButton.Visible = ($State -eq "Error")
$Card.StatusLabel.Text = $Message
```

The modal project dialog must stay open on validation or filesystem errors, show the mapped Russian error beside the input, and return the created trimmed name only after successful directory creation.

- [ ] **Step 5: Run view tests and verify GREEN**

Run the view suite. Expected: all form, card, resource, and state-rendering checks pass and exit 0.

- [ ] **Step 6: Commit the view layer**

```powershell
git add -- ui-text.ru.json transcript-gui-view.psm1 tests/run-gui-view-tests.ps1
git commit -m "feat: add adaptive transcript queue view"
```

### Task 4: GUI queue coordinator and actions

**Files:**
- Modify: `transcript-tool-gui.ps1`
- Modify: `tests/run-gui-smoke-tests.ps1`

**Interfaces:**
- Consumes: all Task 1–3 functions and existing `Request-TranscriptBackgroundJobStop`/`Complete-TranscriptBackgroundJobCleanup` behavior.
- Produces: the complete interactive desktop workflow.

- [ ] **Step 1: Extend the smoke test with failing window assertions**

After locating the main window, use `System.Windows.Automation.AutomationElement.FromHandle` to assert accessible buttons named `Добавить видео`, `Сохранить видео`, `Открыть папку`, and `Скопировать путь`, plus at least one URL edit and project combo box. Expected before implementation: FAIL because the old window does not expose these controls.

- [ ] **Step 2: Run the smoke test and verify RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-smoke-tests.ps1
```

Expected: FAIL on the first new accessible-control assertion.

- [ ] **Step 3: Replace fixed control construction with the view module**

Import `transcript-gui-model.psm1` and `transcript-gui-view.psm1`, load `ui-text.ru.json`, build the main view, add one card, and keep cards in `System.Collections.ArrayList`. Bind:

- add up to six;
- remove cards after the first and renumber;
- clear a URL without removing its card;
- create a project from the originating card, refresh all project selectors, and select the created project there;
- refresh project selectors when the root changes;
- update the `N из 6` counter and `Сохранить N видео` label from non-empty URL count.

- [ ] **Step 4: Add queue start and per-item completion**

Extract the current one-item job creation into `Start-ActiveTranscriptItem -Item <object> -Card <object>`. At queue start:

```powershell
$rows = @($script:cards | ForEach-Object {
    [pscustomobject]@{
        CardId = $_.Id
        Url = $_.UrlBox.Text
        ProjectName = [string]$_.ProjectBox.SelectedItem.Value
    }
})
$plan = New-TranscriptBatchPlan -Rows $rows -RootDir $view.RootBox.Text -Language $language
Assert-TranscriptOutputDirectoriesWritable -OutputDirs @($plan | ForEach-Object { $_.OutputDir })
$script:queueState = New-TranscriptQueueState -Items $plan
Set-TranscriptUiBusy -Busy $true
Start-NextTranscriptQueueItem
```

On worker completion, set `TextPath` and success state or store the error and error state, call `Move-TranscriptQueueNext`, and immediately start the next item while `IsRunning`. When idle, re-enable all inputs and report `Готово: X; ошибок: Y`.

Always pass `KeepSubtitles="0"`. Do not display a modal for an individual video failure. Preserve modal errors only for failures that prevent the queue itself from starting safely.

- [ ] **Step 5: Bind retry and clipboard/root actions**

- Retry builds a one-row plan for the failed card only and starts it when no queue is active.
- Copy text reads `Card.TextPath` with `Get-Content -Raw -Encoding UTF8`, calls `[System.Windows.Forms.Clipboard]::SetText`, and updates that card's message.
- Open folder launches Explorer with the canonical root.
- Copy path writes the canonical root path to the clipboard and updates the global status.
- During a queue, disable root, language, URL, project, add/remove/create, and footer actions. No cancel control is added.

- [ ] **Step 6: Run focused GUI tests and verify GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-view-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-smoke-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-job-lifecycle-tests.ps1
```

Expected: every suite exits 0, the smoke test reports the accessible controls, and lifecycle cleanup still passes.

- [ ] **Step 7: Commit the coordinated GUI**

```powershell
git add -- transcript-tool-gui.ps1 tests/run-gui-smoke-tests.ps1
git commit -m "feat: process transcript video queues"
```

### Task 5: Packaging, documentation, and full regression

**Files:**
- Modify: `app-files.txt`
- Modify: `README.md`
- Modify: `tests/run-install-tests.ps1`

**Interfaces:**
- Consumes: the final application files from Tasks 1–4.
- Produces: installable and documented queue-enabled package.

- [ ] **Step 1: Add failing package-manifest expectations**

Extend the install/package expectations to require:

```powershell
"transcript-gui-model.psm1"
"transcript-gui-view.psm1"
"ui-text.ru.json"
```

- [ ] **Step 2: Run install tests and verify RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-install-tests.ps1
```

Expected: FAIL because the new files are absent from `app-files.txt` and the built package.

- [ ] **Step 3: Update manifest and README**

Add the three files to `app-files.txt`. Rewrite the desktop usage section around adding up to six videos, selecting/creating projects, sequential processing, retry, per-card text copying, and root-folder actions. Remove the GUI instruction for saving original subtitle files while retaining CLI documentation for `-KeepSubs`.

- [ ] **Step 4: Run the complete regression set**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-model-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-view-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-smoke-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-job-lifecycle-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-install-tests.ps1
```

Expected: all suites exit 0 with no failed assertions.

- [ ] **Step 5: Build and inspect the distributable**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-package.ps1
```

Expected: exit 0 and a ZIP containing the GUI, both GUI modules, the Russian resource, worker, lifecycle module, transcript core, launchers, installer, uninstaller, README, manifest, and `yt-dlp.exe`.

- [ ] **Step 6: Capture the redesigned window for visual verification**

Launch `transcript-tool-gui.ps1`, add six cards, create a temporary project under a temporary root, and capture the window. Verify that Russian labels are not clipped, the list scrolls, URL clear and row removal are distinct, and the footer remains visible. Remove only the temporary project root created for this verification.

- [ ] **Step 7: Commit packaging and documentation**

```powershell
git add -- app-files.txt README.md tests/run-install-tests.ps1
git commit -m "docs: package and explain transcript queues"
```
