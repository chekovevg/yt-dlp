# Save Text Button Design

## Goal

Rename the desktop application's primary queue action so it describes the result the user receives, rather than implying that the video itself is downloaded.

## User-facing behavior

- The idle/default button label is `Сохранить текст`.
- When one or more video links are ready, the dynamic label is `Сохранить текст ({0})`, for example `Сохранить текст (2)`.
- The action, keyboard behavior, queue processing, and generated files remain unchanged.

## Scope

- Update the Russian UI resource strings used by the primary action.
- Update README instructions that mention the old label.
- Add or update a GUI test that verifies both the default and counted labels.
- Do not rename internal control or resource identifiers; they are implementation details and changing them would add risk without improving the interface.

## Verification

- Run the GUI view and smoke tests.
- Run the relevant GUI behavior test for the dynamic count.
- Render and inspect the desktop window to confirm the new text fits at the minimum supported width.
