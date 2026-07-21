# Result Context Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move transcript result-file actions from persistent buttons into a native context menu on each successful video card.

**Architecture:** The view module owns creation, attachment, localization, and enabled state of the native `ContextMenuStrip`. The GUI coordinator binds those menu items to file/clipboard/Explorer operations using the card's existing `TextPath`; no transcript-processing or queue-model changes are required.

**Tech Stack:** Windows PowerShell 5.1, WinForms, Pester-free PowerShell test scripts, Git.

## Global Constraints

- Keep the interface Russian.
- Keep `Сохранить видео` and error recovery visible; hide only secondary result-file actions.
- Expose exactly three menu items in this order: copy path, copy contents, show in Explorer.
- Do not show usable result actions until a successful transcript file exists.
- Do not add new runtime dependencies.

---

### Task 1: Context-menu view contract

**Files:**
- Modify: `tests/run-gui-view-tests.ps1`
- Modify: `tests/run-gui-smoke-tests.ps1`
- Modify: `transcript-gui-view.psm1`
- Modify: `ui-text.ru.json`

**Interfaces:**
- Produces card properties `ResultContextMenu`, `CopyPathMenuItem`, `CopyContentsMenuItem`, and `ShowInExplorerMenuItem`.
- `Set-TranscriptVideoCardState` enables the menu only for `Success`.
- Removes `CopyTextButton`, `OpenRootButton`, and `CopyRootPathButton` from the view contract.

- [ ] **Step 1: Write the failing view and smoke assertions**

Assert that a new card owns a disabled three-item context menu, that `Success` enables it, that all card controls reference it, and that the old action buttons are absent.

- [ ] **Step 2: Run tests to verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-view-tests.ps1`

Expected: FAIL because `ResultContextMenu` and its menu-item properties do not exist.

- [ ] **Step 3: Implement the minimal view**

Create a native `ContextMenuStrip`, add the three localized `ToolStripMenuItem` objects in the specified order, attach the menu recursively to the card controls, remove the persistent buttons, and toggle menu availability from `Set-TranscriptVideoCardState`.

- [ ] **Step 4: Verify GREEN**

Run the view and smoke tests. Expected: both suites pass and the live window no longer exposes the old footer actions.

- [ ] **Step 5: Commit**

Commit message: `feat: add transcript result context menu`

### Task 2: File actions and documentation

**Files:**
- Modify: `transcript-tool-gui.ps1`
- Modify: `ui-text.ru.json`
- Modify: `README.md`
- Test: `tests/run-gui-view-tests.ps1`
- Test: `tests/run-gui-smoke-tests.ps1`

**Interfaces:**
- `Copy-TranscriptCardPath -Card <object>` copies `Card.TextPath`.
- `Copy-TranscriptCardContents -Card <object>` reads `Card.TextPath` as UTF-8 and copies it.
- `Show-TranscriptCardInExplorer -Card <object>` invokes `explorer.exe /select,<full path>`.

- [ ] **Step 1: Bind the menu actions**

Replace the old copy-button event with handlers for `CopyPathMenuItem`, `CopyContentsMenuItem`, and `ShowInExplorerMenuItem`. Remove root-folder footer handlers and their busy-state references.

- [ ] **Step 2: Preserve result-menu state**

Ensure changing a successful URL clears `TextPath` and disables the menu, queue busy state disables it, and completion restores it.

- [ ] **Step 3: Update user documentation**

Describe right-click actions on a successful card and remove instructions for the old buttons.

- [ ] **Step 4: Run full verification**

Run all seven test scripts sequentially, then run `build-package.ps1` and verify the archive contents against `app-files.txt`.

- [ ] **Step 5: Commit**

Commit message: `docs: explain transcript file context actions`
