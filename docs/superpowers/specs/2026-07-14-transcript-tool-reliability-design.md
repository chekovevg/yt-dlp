# YouTube Transcript Tool Reliability Design

## Goal

Make both the desktop window and the command-line interface reliably save YouTube transcripts without deleting pre-existing user files, while keeping Windows PowerShell 5.1 compatibility and the current visible desktop layout.

## Scope

- Keep `youtube-transcript-tool.cmd` and the WinForms desktop window.
- Keep `download-subs.cmd` and the existing command-line parameters.
- Use `transcript-tool.psm1` as the single implementation for native process execution, subtitle selection, subtitle conversion, and safe file handling.
- Update the bundled official `yt-dlp.exe` from `2026.03.17` to the current stable release and verify its SHA-256 checksum against the official release manifest.
- Add regression coverage for every reproduced defect before changing production behavior.

## Architecture

`transcript-tool.psm1` becomes the shared core. It owns invocation of `yt-dlp`, metadata parsing, language selection, temporary workspace management, subtitle parsing, output naming, and error translation. The GUI and CLI remain responsible only for collecting arguments, displaying status or console output, and opening the resulting file or folder.

The CLI will preserve its public switches, but download operations will use a unique temporary directory. Only files created inside that directory may be deleted automatically. `-CleanOnly` will read an existing subtitle file without deleting it. This removes the current possibility of treating unrelated files in the tool directory as a fresh download.

For online CLI runs, normal conversion writes the transcript to `-OutputDir`. `-KeepSubs` additionally copies the selected subtitle into `-OutputDir`. `-NoClean` skips text conversion and copies every subtitle produced by the current run into `-OutputDir`; it never exposes or reuses the temporary workspace.

The GUI keeps its current controls and wording. The save operation runs outside the WinForms UI thread, returns status updates through the form thread, disables duplicate submissions while active, and restores the controls after success or failure. Closing the form only closes the worker start gate and captures a cleanup ticket; process-group termination, process discovery, resource disposal, and job removal run after the WinForms message loop exits.

## Native Process Execution

A single internal helper will execute `yt-dlp` with stdout and stderr captured separately. stderr output will not become a terminating PowerShell error merely because `$ErrorActionPreference` is `Stop`. The helper returns exit code, stdout, and stderr; callers classify failures only after the process has exited.

Successful commands may emit warnings without failing. Failed commands retain the existing user-facing categories for invalid links, unavailable/private videos, network problems, rate limiting, and missing subtitles. Rate limiting is classified before generic HTTP/network failures. Unexpected metadata and subtitle-download failures include a diagnostic tail bounded to approximately 2,000 characters.

## Subtitle Selection

Missing manual subtitles and missing automatic captions are normal empty collections. Selection must support videos that contain only one source type.

Explicit `ru`, `en`, and `de` preferences will match exact tags and regional variants such as `en-AU`, `de-AT`, and `ru-RU`. Auto mode keeps the existing language priority `ru`, then `en`, then `de`, then another real subtitle language. Service tracks such as `live_chat` are excluded. A fallback tag is eligible only when it exposes a subtitle format that can be converted to VTT or SRT.

## Subtitle Parsing

The converter parses VTT/SRT structure with state rather than filtering every line through one broad regular expression. `WEBVTT`, `Kind:`, and `Language:` are recognized as technical headers only during the document-header phase, never after cue parsing begins. It will:

- skip complete `NOTE`, `STYLE`, and `REGION` blocks;
- skip cue identifiers and timestamp lines;
- preserve numeric speech such as `2026`;
- remove inline markup and decode HTML entities;
- collapse adjacent duplicate caption text;
- keep the existing readable paragraph formatting;
- reject an empty transcript instead of saving an empty text file.

## File Safety

Every online download uses a GUID-named temporary directory and an explicit output template. Cleanup is limited to that directory. Existing `.vtt`, `.srt`, and `.txt` files outside it are never deleted or overwritten.

Before converting or copying output, the shared core atomically acquires a per-candidate `FileMode.CreateNew` lock configured with `DeleteOnClose`. Existing targets or a live lock advance the complete artifact set to the next numeric stem (`-2`, `-3`, and so on). Every text/review/subtitle artifact is written completely into an operation-GUID staging directory on the same output volume. A manifest records each target and the staging file's stable Windows volume/file-index identity before atomic no-replace renames publish any artifact; a commit marker is written only after every rename succeeds. Normal failure, hard worker termination, and interrupted multi-artifact publication therefore leave either no final set or one complete final set. Deferred GUI cleanup removes a partially published target only through an identity-validated file handle, then removes the exact operation staging and download workspaces. `DeleteOnClose` removes the interprocess lock when a worker is killed. Existing data is never deleted by path alone or overwritten. The same rule applies to `-CleanOnly`, `-NoClean`, normal CLI downloads, and GUI-core saves.

## Interfaces

The GUI layout and labels remain unchanged. Its observable changes are responsiveness during network work, reliable error messages, and correct completion status.

The CLI retains `-List`, `-CleanOnly`, `-NoClean`, `-KeepSubs`, `-Srt`, `-CleanTranscript`, `-Prefer`, `-OutputDir`, and `-Langs`. Existing transcript-specific normalization remains opt-in behind `-CleanTranscript`; general transcript conversion uses the shared parser.

`-Langs` remains an explicit override and is passed to `yt-dlp` without restricting it to `ru`, `en`, or `de`. Automatic language ordering is used only when `-Langs` is empty.

## Testing

The module regression suite will cover:

- successful `yt-dlp` output accompanied by stderr warnings;
- non-zero native exit codes and user-friendly error translation;
- automatic-only and manual-only videos;
- regional language tags;
- exclusion of `live_chat`;
- structured VTT blocks, numeric captions, duplicate captions, and empty output;
- VTT/SRT cue text beginning exactly with `WEBVTT`, `Kind:`, or `Language:`;
- end-to-end saving with a fake `yt-dlp` executable;
- atomic two-process `-2`/`-3` output claims across transcript, review, and subtitle artifacts;
- deterministic hard cancellation immediately after the first multi-artifact publish, including durable-manifest assertions, identity-safe rollback, same-path substitution preservation, committed-set retention, and complete process/workspace cleanup;
- exact public result shapes, callback-output suppression, bounded diagnostics, and temporary workspace cleanup;
- restoration of whitespace cleanup immediately inside brackets.

The CLI suite will cover:

- preservation of existing subtitle files in `-CleanOnly` mode;
- isolation from unrelated subtitle files;
- operation when launched from a working directory different from the script directory;
- preservation of existing switches and language ordering;
- `-NoClean`, `-KeepSubs`, `-Srt`, and explicit `-Langs` behavior under output collisions;
- diagnostics for complete download failure and downloaded-despite-error results.

Final verification includes both test suites, PowerShell parser validation, checksum validation for `yt-dlp.exe`, a real public YouTube transcript download to a temporary directory, and a GUI launch smoke test.

## Repository Hygiene

Add a `.gitignore` for generated transcripts, temporary subtitle files, and local Lazyweb artifacts. Source scripts, tests, documentation, launchers, and the intentionally bundled `yt-dlp.exe` remain versioned.

## Non-Goals

- No visual redesign of the desktop window.
- No migration away from Windows PowerShell 5.1.
- No automatic background updater or new update button.
- No change to the existing transcript-specific normalization rules beyond making their execution safe and opt-in.
