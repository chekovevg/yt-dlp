# YouTube Transcript Tool

Small Windows desktop utility for saving readable text transcripts from YouTube videos.

The tool uses the local `yt-dlp.exe` in this folder. It does not download video files and does not require a YouTube API key or login.

## What It Does

- Opens as a small desktop window.
- Accepts a YouTube video link.
- Saves a `.txt` transcript to a chosen local folder.
- Remembers the save folder, subtitle language, and "also save subtitles" checkbox between launches.
- Can optionally save the original `.vtt` subtitle file next to the `.txt`.

## Requirements

- Windows.
- Windows PowerShell 5 or newer, included with Windows.
- `yt-dlp.exe` next to the scripts in this folder, or installed in `PATH`.
- Internet access.

Python is not required.

## Run

Double-click:

```text
youtube-transcript-tool.cmd
```

If Windows opens a console for a moment, that is normal; the desktop window should appear after it.

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

Run backend smoke tests:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-transcript-tool-tests.ps1
```

Existing subtitle script regression tests:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-download-subs-tests.ps1
```
