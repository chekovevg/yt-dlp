# Save Text Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the desktop application's primary queue action from `Сохранить видео` to `Сохранить текст`, including its counted form.

**Architecture:** Keep the existing `SaveVideos` and `SaveVideosFormat` resource keys and queue-action logic unchanged. Update only the Russian copy, its focused assertions, and the README references so the interface describes the generated text rather than implying a video download.

**Tech Stack:** Windows PowerShell 5, WinForms, UTF-8 JSON resources, PowerShell test scripts.

## Global Constraints

- The idle/default button label is exactly `Сохранить текст`.
- The dynamic label is exactly `Сохранить текст ({0})`, for example `Сохранить текст (2)`.
- Queue behavior, keyboard behavior, generated files, internal control names, and resource keys remain unchanged.
- Preserve all unrelated working-tree changes, including the existing application-icon work.
- Do not create a Git commit unless the user explicitly requests one.

---

### Task 1: Rename and verify the primary queue action

**Files:**
- Modify: `tests/run-gui-view-tests.ps1`
- Modify: `ui-text.ru.json`
- Modify: `README.md`

**Interfaces:**
- Consumes: `Get-TranscriptUiText`, `New-TranscriptMainView`, resource properties `SaveVideos` and `SaveVideosFormat`.
- Produces: unchanged resource properties whose values are `Сохранить текст` and `Сохранить текст ({0})`.

- [x] **Step 1: Write the failing copy and view assertions**

Add these assertions after loading `$uiText` and creating `$mainView` in `tests/run-gui-view-tests.ps1`:

```powershell
Assert-Equal $uiText.SaveVideos "Сохранить текст" "Primary action still describes saving a video."
Assert-Equal ($uiText.SaveVideosFormat -f 2) "Сохранить текст (2)" "Counted primary action copy is incorrect."
Assert-Equal $mainView.SaveQueueButton.Text $uiText.SaveVideos "Idle primary action does not use the save-text copy."
```

- [x] **Step 2: Run the focused test and observe the expected failure**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-view-tests.ps1
```

Expected: FAIL because `SaveVideos` still equals `Сохранить видео`.

- [x] **Step 3: Apply the minimal resource change**

Change only these values in `ui-text.ru.json`:

```json
"SaveVideos": "Сохранить текст",
"SaveVideosFormat": "Сохранить текст ({0})"
```

- [x] **Step 4: Run the focused test and observe success**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-view-tests.ps1
```

Expected: all GUI view tests pass.

- [x] **Step 5: Update user instructions**

In `README.md`, replace both visible-label references to `Сохранить видео` with `Сохранить текст`. Do not rename PowerShell variables, resource keys, or internal controls.

- [x] **Step 6: Verify behavior and rendered fit**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-smoke-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-model-tests.ps1
```

Expected: the smoke test passes and all GUI model tests pass. Render the main window at its minimum supported width and confirm `Сохранить текст` is fully visible, the Enter key still targets the same button, and no surrounding layout regresses.

- [x] **Step 7: Review the scoped diff**

Run:

```powershell
git diff --check
git diff -- ui-text.ru.json README.md tests/run-gui-view-tests.ps1
```

Expected: no whitespace errors; only the agreed resource copy, README references, and focused assertions are added by this task.
