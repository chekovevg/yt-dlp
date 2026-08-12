# Result Context Menu Design

## Goal

Replace persistent result-file buttons with a compact context menu on each successfully processed video card.

## Evidence and decision

- User-supplied reference: the Codex file context menu with `Copy path`, `Copy file contents`, and `Open in Explorer`.
- Assumption: these are secondary actions that belong to one completed transcript, not to the root output folder.
- Evidence gap: Lazyweb MCP tools are not available in this session, so no external interaction references are claimed.

The adopted pattern is a standard Windows `ContextMenuStrip`. It keeps the queue visually quiet while preserving native right-click, Menu-key, and `Shift+F10` behavior.

## Interaction

After a card completes successfully, right-clicking anywhere on that card opens three actions in this order:

1. `Скопировать путь` copies the full transcript file path.
2. `Скопировать содержимое файла` reads the UTF-8 transcript and copies it to the clipboard.
3. `Показать в проводнике` opens Explorer with the transcript file selected.

The menu is unavailable before a transcript exists, while processing, and after the URL is changed. The success message ends with a short right-click hint so the hidden actions remain discoverable.

## UI changes

- Remove the per-card `Скопировать текст` button.
- Remove the footer `Открыть папку` and `Скопировать путь` buttons.
- Keep `Сохранить видео` as the only footer action.
- Keep `Повторить` visible on failed cards because retry is a primary recovery action, not a file action.
- Attach the same context menu to the card background, layout surfaces, heading, and status. Keep native right-click behavior on editable inputs and buttons.

## Error handling

- Copy/open actions first require a successful card and an existing result file.
- Clipboard and Explorer failures are reported in the card status without changing its successful state.
- If the result file has disappeared, the menu action reports a localized missing-file error.

## Accessibility

- Use a native context menu so keyboard invocation works without a custom shortcut.
- Give every menu item a localized accessible name.
- Add an accessible description to successful cards explaining that result actions are available from the context menu.

## Verification

- View tests verify the three items, ordering, availability rules, whole-card attachment, and removal of persistent buttons.
- Smoke tests verify the two footer file buttons are absent from the live window.
- Existing model, lifecycle, transcript, CLI, installer, and package tests remain green.
