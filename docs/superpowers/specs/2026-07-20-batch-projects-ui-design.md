# Batch Video Queue and Project Folders Design

**Date:** 2026-07-20
**Status:** Approved for implementation
**Product:** YouTube Transcript Tool for Windows

## Goal

Extend the single-video desktop workflow into a small sequential queue that can process up to six YouTube videos. Each video can target the root output directory or one named project folder immediately below it. Keep the interface Russian, remove the optional `.vtt` output from the GUI, and make completed transcript text easy to copy.

## Confirmed Product Decisions

- The queue contains one to six video cards.
- Empty added cards are ignored. At least one non-empty URL is required.
- Filled cards run sequentially from top to bottom.
- A failure marks only that card and does not stop later cards.
- A failed card can be retried after the active queue finishes.
- Subtitle language is shared by the entire queue.
- The GUI always saves only the final `.txt`; it no longer exposes the `.vtt` checkbox.
- Each successful card exposes `Скопировать текст`.
- Global footer actions expose `Открыть папку` and `Скопировать путь` for the root output directory.
- No visible cancel button is required. Closing the window keeps the existing safe cancellation behavior.

## Window and Layout

The window becomes resizable with a sensible minimum size around 720×520. A vertically scrolling card list prevents six videos from forcing the window beyond the screen.

The top settings area contains:

1. `Папка сохранения`, the root directory used both for root output and project discovery.
2. `Выбрать…`, which changes that root.
3. A shared `Язык субтитров` selector with human-readable Russian labels mapped internally to `auto`, `ru`, `en`, and `de`.

The videos section contains an `+ Добавить видео` button and a `N из 6` counter. The add button disables at six cards.

Each card contains:

- a stable card number in current visual order;
- a URL input with an inline `×` action whose accessible name and tooltip are `Очистить ссылку`;
- a project selector to the right, defaulting to `Без проекта`;
- a `Создать проект…` action associated with that card;
- a separate `Удалить строку` action for cards after the first, visually distinct from URL clearing;
- a status/result row;
- `Скопировать текст` after success;
- an error message and `Повторить` after failure.

The footer contains the primary action `Сохранить N видео`, plus root-level `Открыть папку` and `Скопировать путь`.

## Project Model

A project is one immediate child directory of the selected root output directory. Nested projects are out of scope. Existing immediate child directories are listed in every project selector, except internal transient directories whose names start with `.youtube-transcript-operation-`.

`Без проекта` maps to the root output directory. A named project maps to `Join-Path <root> <project>` only after canonical-path validation confirms it remains inside the root.

`Создать проект…` opens an owned modal dialog with a text input, `OK`, and `Отмена`. Project names:

- are trimmed;
- must be a single directory name, not a path;
- cannot be empty, `.` or `..`;
- cannot contain Windows-invalid filename characters or end in a dot or space;
- cannot use a reserved Windows device name;
- are limited to 80 characters.

Successful creation refreshes every card selector and selects the new project in the originating card. An existing name produces an inline dialog error and leaves the dialog open so the user can select that project from the selector instead. Changing the root directory refreshes all selector lists and resets selections that do not exist under the new root to `Без проекта`.

## Queue Architecture and Data Flow

The existing worker remains responsible for exactly one video. The GUI adds a queue coordinator above it rather than changing transcript download semantics.

At queue start the GUI snapshots all non-empty cards in visual order. Each snapshot contains card identity, trimmed URL, resolved output directory, shared language, and a new operation ID. Inputs, project controls, add/remove actions, root selection, and the shared language selector are disabled until the queue is idle again.

For each snapshot:

1. mark its card active;
2. start the existing single-video background worker with `KeepSubtitles=0`;
3. route worker status messages to that card;
4. store `TextPath` and mark the card successful, or store the user-facing error and mark it failed;
5. continue with the next snapshot regardless of success or failure.

After the final snapshot, inputs are re-enabled and a global summary reports completed and failed counts. Retry starts a one-item queue for that failed card, using its current URL and current project selection after the batch is idle.

Closing the form during processing invokes the existing identity-safe job cleanup for the currently active worker. Cards that already completed remain saved; queued cards that did not start are abandoned without filesystem changes.

## Result and Clipboard Actions

`Скопировать текст` reads the successful card's saved UTF-8 text file and places its contents on the Windows clipboard. The card status changes briefly to `Текст скопирован`. A read or clipboard failure is shown on that card without changing the saved-file success state.

`Открыть папку` opens the selected root output directory. `Скопировать путь` copies the root directory path as text and gives visible status feedback. These footer actions never point to an individual project.

## Error Handling

- No non-empty URL: keep the queue idle and focus the first URL field with an inline message.
- Invalid YouTube URL, unavailable video, missing subtitles, language mismatch, network failure, and filesystem failure: reuse existing user-facing error mapping on the affected card.
- Invalid project name: keep the modal open with a specific validation message.
- Project creation failure: show the filesystem error in the modal without changing any selector.
- Project directory removed after selection: resolve at queue start, reset that card to `Без проекта`, and ask the user to start again rather than silently redirect output.
- Root directory invalid or unwritable: reject queue start before any video begins.

## Accessibility and Interaction

- Give every editable control and action an explicit accessible name.
- Use a predictable card-by-card tab order.
- Set the primary queue action as the form's Enter action when focus is not inside the project-name modal.
- Tooltips explain the URL clear and row removal actions.
- Status and error meaning is conveyed in text, never color alone.
- Card layout uses auto-sizing containers instead of fixed coordinates so Russian text remains visible at common Windows DPI scales.

## Code Boundaries

Keep transcript downloading and publication in `transcript-tool.psm1`. Add small pure helpers there or in a dedicated GUI model module for:

- project-name validation and project directory resolution;
- project discovery;
- building an immutable batch plan from card values;
- queue summary calculation.

Keep WinForms control construction, card rendering, queue coordination, and clipboard actions in `transcript-tool-gui.ps1`. Reuse `transcript-job-lifecycle.ps1` for current-worker cleanup. Do not introduce parallel downloads.

## Testing

Follow red-green-refactor for each behavior.

Automated tests cover:

- valid and invalid project names, including traversal and reserved names;
- discovery of immediate project directories and exclusion of transient directories;
- canonical project output resolution within the root;
- one-to-six-card batch planning, ignored empty cards, order preservation, and per-card output directories;
- continuation after an item failure and retry planning;
- GUI launch and control availability;
- regression of the existing transcript, lifecycle, installer, and packaging suites.

Manual verification covers:

- adding, clearing, and removing cards;
- six-card scrolling and resizing;
- project creation and selector refresh;
- a mixed success/failure queue;
- copying transcript text and the root path;
- Russian text at 100%, 125%, 150%, and 200% scaling where available.

## Out of Scope

- Parallel downloads.
- More than six queued videos.
- Nested project folders.
- Reordering cards by drag and drop.
- Queue persistence across application restarts.
- Visible cancellation controls.
- Saving `.vtt` from the desktop GUI.
