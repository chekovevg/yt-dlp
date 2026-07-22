# Original-Only Subtitle Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to execute this plan task-by-task.

**Goal:** Make every online GUI and CLI download select only the video's original subtitle track, prefer creator-provided captions, allow original ASR with a persistent accuracy warning, and never fall back to a translation.

**Architecture:** Keep `yt-dlp` behind one isolated boundary in `transcript-tool.psm1`. Parse its metadata into explicit subtitle-track and original-language evidence objects, resolve one deterministic selection, and pass that selection to both GUI and CLI download paths. Presentation layers consume `WarningCode`; they do not infer quality from filenames or language preferences.

**Tech Stack:** PowerShell 5.1 modules and scripts, WinForms, bundled `yt-dlp.exe`, custom PowerShell test runners.

**Constraints:** Preserve the user's existing icon-related edits in GUI, installer, and test files. Do not commit, push, or otherwise mutate Git history because the applicable repository instructions require explicit user authorization for those actions.

---

## Task 1: Lock down the managed yt-dlp contract and build the resolver

**Files:**

- Modify: `transcript-tool.psm1`
- Modify: `tests/run-transcript-tool-tests.ps1`

### Step 1: Add failing contract and resolver tests

Add table-driven tests that call the public/core functions with metadata fixtures and assert:

- every probe starts with `--ignore-config --no-plugin-dirs`;
- production resolution accepts only the bundled executable while an explicit test path remains injectable;
- `2026.07.04` and newer date-like versions pass, older/invalid versions fail as `UnsupportedYtDlpContract`;
- `subtitles`, `automatic_captions`, and `formats` are required with the designed types;
- only direct HTTP(S) VTT/SRT formats are eligible and `live_chat` is excluded;
- `en-US-orig` becomes canonical `en-US`, base `en`, while retaining the raw tag;
- evidence tiers `*-orig`, audio preference 10, then 5, then unique non-descriptive audio behave exactly as designed;
- malformed/empty/`und`/`mul`/`zxx` values are ignored and repeated formats are deduplicated;
- manual exact and unique-base matches win before original ASR;
- conflicts, multiple same-base variants, and multiple manuals without evidence fail as ambiguity;
- a sole manual without evidence returns `ManualLanguageUnconfirmed`;
- original ASR returns `AutomaticOriginalAccuracy`;
- automatic tags without `-orig` are never eligible.

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
```

Expected: FAIL on missing contract and original-only behavior.

### Step 2: Implement the managed boundary

In `transcript-tool.psm1`:

- prepend `--ignore-config`, `--no-plugin-dirs` in one helper used by version, metadata, listing, and downloads;
- make `Get-YtDlpPath` reject PATH fallback in production but keep `-PreferredPath` for tests;
- validate and cache the executable version per resolved path;
- make `Invoke-YtDlpJson` validate the metadata shape and throw bounded `UnsupportedYtDlpContract` diagnostics.

Keep raw process output out of user-facing errors except for the existing bounded classifications.

### Step 3: Implement track parsing and original-language evidence

Add focused internal helpers for:

```powershell
ConvertTo-TranscriptLanguageIdentity -RawTrackTag <string>
Get-TranscriptSubtitleTracks -Info <object>
Get-TranscriptOriginalLanguageEvidence -Info <object> -Tracks <array>
Resolve-TranscriptSubtitleChoice -Info <object>
```

Return a single domain object with `RawTrackTag`, `CanonicalLanguageTag`, `BaseLanguage`, `SourceKind`, `Confidence`, `WarningCode`, and preferred representation. Use explicit failure codes for no tracks, no verified original, conflicting evidence, and ambiguous tracks.

### Step 4: Run the focused suite

Run the transcript-tool suite again and fix only resolver/contract regressions until it passes.

---

## Task 2: Make GUI and CLI share the one selected original track

**Files:**

- Modify: `transcript-tool.psm1`
- Modify: `tests/run-transcript-tool-tests.ps1`
- Modify: `tests/run-download-subs-tests.ps1`

### Step 1: Add failing end-to-end argument tests

Assert for both core save entry points:

- metadata is resolved before any subtitle write invocation;
- download args contain the isolation prefix, `youtube:skip=translated_subs`, one literal raw tag, `vtt/srt`, and exactly one of `--write-subs` or `--write-auto-subs`;
- manual captions win over matching ASR;
- translated automatic captions are never a retry/fallback;
- a failed selected-track download preserves the existing rate-limit/network/unavailable diagnostics;
- `en-US-orig` is requested literally but the output filename uses `en-US`;
- result objects carry the resolver fields and warning code.

Run both test runners and observe the new failures.

### Step 2: Introduce one download-argument builder

Add a helper equivalent to:

```powershell
New-TranscriptSubtitleDownloadArguments -Choice <object> -OutputTemplate <string> [-Srt]
```

It must produce one write flag and one raw selector, and must never accept a language preference or language list.

### Step 3: Replace legacy selection paths

Update `Save-TranscriptFromYoutube` and `Save-TranscriptFromYoutubeCli` to use the shared metadata probe, resolver, and argument builder. Remove the old `ru/en/de` fallback helpers and retry plan. Retain CLI-specific cleanup/no-clean/SRT behavior without allowing it to influence track selection.

Return `WarningCode`, `SourceKind`, `RawTrackTag`, `CanonicalLanguageTag`, and `BaseLanguage` from both flows.

### Step 4: Run both focused suites

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
```

Expected: PASS, including zero translation fallback attempts.

---

## Task 3: Remove language state from settings, queue, worker, and desktop UI

**Files:**

- Modify: `transcript-tool.psm1`
- Modify: `transcript-gui-model.psm1`
- Modify: `transcript-worker.ps1`
- Modify: `transcript-gui-view.psm1`
- Modify: `transcript-tool-gui.ps1`
- Modify: `ui-text.ru.json`
- Modify: `tests/run-transcript-tool-tests.ps1`
- Modify: `tests/run-gui-model-tests.ps1`
- Modify: `tests/run-gui-view-tests.ps1`
- Modify: `tests/run-gui-job-lifecycle-tests.ps1`

### Step 1: Add failing migration/model/view/lifecycle tests

Assert:

- old settings containing `Language` still load output directory and subtitle-retention state;
- newly written settings omit `Language`;
- batch items and worker args no longer contain a language;
- the main view has no language label/combo while retaining the existing icon behavior;
- an ASR success leaves the accuracy warning visibly present on its completed video card;
- a presumed-manual success leaves the unconfirmed-language warning present;
- warnings do not stop later queue items and are not treated as failures.

Run the four affected suites and confirm the tests fail for the intended old behavior.

### Step 2: Remove language settings and queue plumbing

- Reduce settings to `OutputDir` and `KeepSubtitles`; tolerate but ignore legacy `Language` on read.
- Remove `Language` from `New-TranscriptBatchPlan`, worker parameters, worker invocation, busy controls, and queue-start validation.
- Delete obsolete selector text keys only after all callers are removed.

### Step 3: Remove the selector and render persistent warnings

Delete the language row from `New-TranscriptMainView` and reflow the existing controls. Preserve the user-added optional `IconPath` parameter and form/dialog icon assignments unchanged.

Map warning codes to these Russian strings in the presentation layer:

```text
Автоматически распознанные субтитры. Имена, числа, адреса и другие детали могут содержать ошибки распознавания.
Язык не удалось независимо подтвердить. Сохранён единственный доступный авторский трек.
```

Render the warning in the completed card's status/message area together with the saved path, without color-only semantics.

### Step 4: Run model, view, lifecycle, and core suites

Expected: PASS, with the icon assertions still intact.

---

## Task 4: Update the public CLI surface and diagnostics

**Files:**

- Modify: `download-subs.ps1`
- Modify: `tests/run-download-subs-tests.ps1`

### Step 1: Add failing CLI compatibility tests

Assert:

- explicitly bound `-Prefer` or `-Langs` exits nonzero with the bounded migration message;
- omitting them performs original-only selection;
- `-List` makes only the isolated metadata call, does not write subtitles, and classifies manual/original-ASR/untrusted/service tracks;
- successful ASR and presumed-manual saves use the PowerShell warning stream while retaining exit code zero;
- `-CleanOnly` selects the newest eligible local subtitle, then full name as deterministic tie-break, without language priority.

### Step 2: Implement the CLI behavior

Keep legacy parameter declarations only to detect explicit use via `$PSBoundParameters`, then fail before invoking `yt-dlp`. Remove preference/language plan code. Make `-List` render the shared parsed inventory from metadata. Print success warnings from `WarningCode` after the file is saved.

### Step 3: Run the CLI suite

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
```

Expected: PASS.

---

## Task 5: Document, review, and verify the complete change

**Files:**

- Modify: `README.md`
- Review: all changed implementation and test files

### Step 1: Update user documentation

Document original-only behavior, manual-first preference, ASR/unconfirmed warnings, removal of the GUI selector, rejection of old online CLI switches, metadata-based `-List`, bundled `yt-dlp` minimum, and deterministic `-CleanOnly` behavior. Remove obsolete `auto/ru/en/de` fallback examples.

### Step 2: Run all relevant automated checks

Run each and record the observed outcome:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-model-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-view-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-job-lifecycle-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-smoke-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-install-tests.ps1
```

Also run the repository's package/file-list check if it is separate from the installer suite.

### Step 3: Inspect the rendered desktop application

Launch the application using the repository's supported test/smoke path and visually verify:

- the language row is gone and remaining controls are aligned;
- existing icon behavior remains intact;
- keyboard traversal skips no dead/hidden selector and focus remains visible;
- success, ASR warning, and presumed-manual warning states fit the card without truncating critical meaning;
- the main window remains usable at its supported minimum size.

Capture a screenshot when the available fixture can render a representative warning state. If live YouTube state prevents that, use the deterministic view/lifecycle harness and report the exact visual limitation.

### Step 4: Perform a separate final review

Review `git diff` against the approved design and check specifically for:

- any remaining user-controlled language selection;
- any `PATH` fallback or managed invocation without isolation flags;
- both write flags appearing together;
- automatic tags without `-orig` becoming selectable;
- warning strings inferred from filenames instead of `WarningCode`;
- accidental changes to the user's icon work or unrelated files.

Re-run any suite affected by review fixes. Do not report completion unless observed test and UI evidence supports it; list any check that could not be run.
