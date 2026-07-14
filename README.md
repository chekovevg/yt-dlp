# YouTube Transcript Tool

Small Windows utility with desktop and command-line modes for saving readable text transcripts from YouTube videos.

The bundled `yt-dlp.exe` next to the scripts is used first. The desktop app can also fall back to `yt-dlp.exe` from `PATH`. The tool does not download video files and does not require a YouTube API key or login.

## What It Does

- Provides a small desktop window and a script-friendly command-line mode.
- Accepts a YouTube video link.
- Saves a `.txt` transcript to a chosen local folder.
- Remains usable while `yt-dlp` is running in the background.
- Cancels the active background worker and its `yt-dlp` child process when the desktop window is closed.
- Remembers the save folder, subtitle language, and "also save subtitles" checkbox between launches.
- Can optionally save the original `.vtt` subtitle file next to the `.txt`.

## Requirements

- Windows.
- Windows PowerShell 5 or newer, included with Windows.
- The bundled `yt-dlp.exe` next to the scripts. The desktop app can alternatively use one installed in `PATH`.
- Internet access.

Python is not required.

## Run The Desktop App

Double-click:

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

## Create A Desktop Shortcut

Run this once from PowerShell:

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
2. Paste a YouTube link into `YouTube link`.
3. Choose the save folder.
4. Choose subtitle language:
   - `auto`: try `ru`, then `en`, then `de`, then any available language.
   - `ru`: require Russian subtitles.
   - `en`: require English subtitles.
   - `de`: require German subtitles.
5. Optionally enable `Also save original subtitles when available`.
6. Click `Save text`.

When the transcript is saved, the app shows the file path and enables `Open folder`.

## Output Files

Transcript files are saved in the selected folder.

File names use:

```text
YYYY-MM-DD_video-title_videoid_language.txt
```

Example:

```text
2026-05-30_video-title_abc123_de.txt
```

If subtitle saving is enabled, a matching `.vtt` file is also saved.

## Settings

Settings are stored here:

```text
%APPDATA%\YouTubeTranscriptTool\settings.json
```

The file stores only:

- output folder;
- selected language;
- whether original subtitles should be saved.

## Errors

The app shows user-friendly messages for:

- invalid YouTube link;
- unavailable/private video;
- no subtitles;
- selected language unavailable;
- missing `yt-dlp.exe`;
- network/rate-limit problems;
- no write access to the selected folder;
- file write errors.

If the selected language is unavailable, the error includes the available subtitle language tags.

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
2. Paste a public YouTube video URL.
3. Choose `auto`.
4. Choose an output folder you can write to.
5. Click `Save text`.
6. Confirm the status reaches `Done`.
7. Confirm a `.txt` file appears in the selected folder.
8. Click `Open folder`.
9. Repeat with `ru`, `en`, or `de` on a video that has that language.
10. Try a language that is unavailable and confirm the error lists available languages.

## Developer Checks

Run every regression suite from the tool folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-smoke-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-job-lifecycle-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
```

The checks cover desktop launch/responding behavior, non-blocking background-job shutdown, the shared transcript core, the command-line interface, two-process atomic file-collision safety, and temporary-directory cleanup.
