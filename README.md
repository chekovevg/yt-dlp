# YouTube Transcript Tool

Small Windows utility with desktop and command-line modes for saving readable text transcripts from YouTube videos.

The bundled `yt-dlp.exe` next to the scripts is used first. The desktop app can also fall back to `yt-dlp.exe` from `PATH`. The tool does not download video files and does not require a YouTube API key or login.

## What It Does

- Provides a small desktop window and a script-friendly command-line mode.
- Queues up to six YouTube video links and processes them sequentially.
- Saves each `.txt` transcript to the selected root folder or one project subfolder.
- Creates and reuses one-level project folders from the desktop app.
- Remains usable while `yt-dlp` is running in the background.
- Continues later queue items when one video fails and allows the failed item to be retried.
- Cancels the active background worker and its `yt-dlp` child process when the desktop window is closed.
- Remembers the root save folder and shared subtitle language between launches.
- Copies a completed transcript, or the root folder path, to the clipboard.

## Requirements

- Windows.
- Windows PowerShell 5 or newer, included with Windows.
- The bundled `yt-dlp.exe` next to the scripts. The desktop app can alternatively use one installed in `PATH`.
- Internet access.

Python is not required.

## Install On Windows

1. Download the repository ZIP from GitHub and extract it, or download the `youtube-transcript-tool-windows` artifact from a successful GitHub Actions run.
2. Open the extracted `YouTubeTranscriptTool` folder when using the packaged artifact.
3. Double-click `install.cmd`.
4. Launch `YouTube Transcript Tool` from the Start Menu or desktop shortcut.

Installation is for the current Windows user, does not require administrator rights, and copies the application to:

```text
%LOCALAPPDATA%\Programs\YouTubeTranscriptTool
```

Running `install.cmd` again safely updates the known application files without deleting unrelated files or user settings.

To remove the application, use `Uninstall YouTube Transcript Tool` in the Start Menu or run the installed `uninstall.cmd`. Settings are preserved by default. To remove them too, run:

```powershell
uninstall.cmd -RemoveSettings
```

## Portable Use

The application can also run without installation. Double-click:

```text
youtube-transcript-tool.cmd
```

If Windows opens a console for a moment, that is normal; the desktop window should appear after it.

## Run From The Command Line

Pass a YouTube URL to the console launcher:

```powershell
.\download-subs.cmd "https://www.youtube.com/watch?v=VIDEO_ID"
```

Examples:

```powershell
# Prefer English and choose an output folder.
.\download-subs.cmd "https://www.youtube.com/watch?v=VIDEO_ID" -Prefer en -OutputDir "D:\Transcripts"

# Show the video's available subtitle tracks without downloading them.
.\download-subs.cmd -List "https://www.youtube.com/watch?v=VIDEO_ID"

# Request explicit yt-dlp language expressions.
.\download-subs.cmd "https://www.youtube.com/watch?v=VIDEO_ID" -Langs "ru.*,en.*"
```

The default command downloads subtitles into an isolated temporary folder, converts the selected current-run subtitle to text, and then removes only that temporary folder.

- `-KeepSubs` saves the transcript and also copies the selected subtitle from the current run into the output folder.
- `-NoClean` skips text conversion and copies all subtitle files produced by the current run into the output folder. It does not expose or reuse the temporary working folder.
- `-Srt` requests SRT instead of VTT.
- `-CleanTranscript` enables the optional transcript-specific text normalization.
- `-CleanOnly` converts an existing VTT or SRT file beside the scripts without deleting that source file.

## File Safety

The tool does not delete or overwrite existing `.txt`, `.vtt`, or `.srt` files. It atomically locks one shared stem, writes complete artifacts in an operation-specific staging area, and publishes them with no-overwrite renames, so simultaneous desktop and command-line saves use distinct suffixes such as `-2` and `-3`. If conversion is cancelled or the desktop worker is terminated, operation-specific staging/download files and identity-matching partial publication are removed without touching pre-existing data.

## Create A Portable Desktop Shortcut

Installed copies already create desktop and Start Menu shortcuts. For portable use, run this once from PowerShell in the extracted tool folder:

```powershell
cd D:\Tools\yt-dlp
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\create-desktop-shortcut.ps1
```

After that, use the desktop shortcut named:

```text
YouTube Transcript Tool
```

## How To Use

1. Open the desktop shortcut.
2. Choose the root save folder and one shared subtitle language.
3. Paste a YouTube link into the first video card.
4. Optionally select a project. `Без проекта` saves directly in the root folder.
5. Use `Создать проект…` to create a project folder under the selected root.
6. Use `+ Добавить видео` to add up to six cards. Empty cards are ignored.
7. Click `Сохранить видео`. Filled cards are processed from top to bottom.
8. If one video fails, later cards continue. Correct the failed card and click `Повторить`.
9. Use `Скопировать текст` on a completed card to copy its transcript.
10. Use the footer actions to open the root folder or copy its path.

The desktop app saves only readable `.txt` transcripts. The command-line `-KeepSubs` option remains available when the original subtitle file is needed.

## Output Files

Transcript files are saved in the selected root folder. When a project is selected, they are saved in that immediate project subfolder instead.

File names use:

```text
YYYY-MM-DD_video-title_videoid_language.txt
```

Example:

```text
2026-05-30_video-title_abc123_de.txt
```

The desktop app does not create matching `.vtt` files.

## Settings

Settings are stored here:

```text
%APPDATA%\YouTubeTranscriptTool\settings.json
```

The desktop app uses:

- output folder;
- selected language.

Older settings files can retain a compatibility `KeepSubtitles` field, but the desktop app ignores it and writes it as `false`.

## Errors

Each affected video card shows a message for:

- invalid YouTube link;
- unavailable/private video;
- no subtitles;
- selected language unavailable;
- missing `yt-dlp.exe`;
- network/rate-limit problems;
- no write access to the selected folder;
- file write errors.

If the selected language is unavailable, the error includes the available subtitle language tags.
An error in one card does not stop the remaining queue.

## YouTube Subtitle Limitations

YouTube subtitles are often imperfect. Auto-generated captions can contain recognition mistakes, broken names, and bad punctuation. Auto-translated subtitles are usually worse than original-language captions.

For publishing-quality text, use original-language subtitles as a draft and edit the result manually.

## Update yt-dlp

Updates are manual; the app does not update in the background and does not provide an update button. From PowerShell in the tool folder, install the current stable release and then check the bundled version:

```powershell
.\yt-dlp.exe -U
.\yt-dlp.exe --version
```

## Smoke Test Checklist

1. Run `youtube-transcript-tool.cmd`.
2. Choose an output folder you can write to and create one project.
3. Add six cards, then remove and re-add one card.
4. Confirm the inline clear button removes only its URL.
5. Fill at least two cards, leave one card empty, and assign different projects.
6. Choose a shared language and click `Сохранить видео`.
7. Confirm filled cards run top-to-bottom and the empty card is ignored.
8. Confirm every successful card creates one `.txt` in the expected folder.
9. Confirm `Скопировать текст`, `Открыть папку`, and `Скопировать путь` work.
10. Include one failing link and confirm later cards continue and `Повторить` appears.

## Developer Checks

Run every regression suite from the tool folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-model-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-view-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-smoke-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-job-lifecycle-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-install-tests.ps1
```

The checks cover project and queue planning, adaptive view construction, desktop launch/responding behavior, non-blocking background-job shutdown, the shared transcript core, the command-line interface, two-process atomic file-collision safety, temporary-directory cleanup, per-user installation, safe uninstall, and package contents.

Build the distributable Windows ZIP with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-package.ps1
```

The default output is `dist\youtube-transcript-tool-windows.zip`.
