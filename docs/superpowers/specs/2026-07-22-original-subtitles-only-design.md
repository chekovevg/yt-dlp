# Original-Only Subtitle Selection Design

## Goal

The desktop and command-line applications must save subtitles in the video's
original spoken language. They must never silently select a YouTube
machine-translated caption track because of a saved or explicit language
preference.

The tool may still use YouTube's automatic speech recognition when no suitable
creator-provided subtitle track exists. Because automatic speech recognition
can be wrong about numbers, names, and addresses, every such result must carry
a visible warning.

## Scope

This behavior applies to both supported online entry points:

- the WinForms desktop application; and
- `download-subs.cmd` / `download-subs.ps1`.

Local `-CleanOnly` conversion does not select a YouTube track and therefore
does not need to prove the source language of a user-provided file.

The desktop language selector and the command-line `-Prefer` and `-Langs`
language-selection parameters will be removed. Existing saved desktop
`Language` values are ignored during settings migration and cannot affect new
downloads.

## Subtitle Source Model

The metadata returned by `yt-dlp` exposes two relevant collections:

- `subtitles`: creator-provided/manual subtitle tracks;
- `automatic_captions`: YouTube automatic speech recognition plus its
  machine-translated variants.

An eligible track must expose a VTT or SRT-compatible format. Service tracks
such as `live_chat` remain excluded.

Within `automatic_captions`, a language tag ending in `-orig` is treated as an
original automatic speech-recognition track. Other automatic-caption language
tags are treated as possible machine translations and are never eligible for
selection.

## Original-Language Evidence

The selector normalizes base and regional language tags before comparing them.
For example, `en-orig`, `en`, `en-US`, and an English audio-language value all
share the base language `en`.

Evidence for the original spoken language is evaluated from:

1. eligible automatic-caption tags ending in `-orig`;
2. an unambiguous video-level language value returned by `yt-dlp`; and
3. unambiguous audio-stream language metadata returned by `yt-dlp`.

If the available evidence conflicts or identifies multiple original languages,
the selector reports an ambiguity instead of guessing.

## Selection Rules

The same resolver is used by the GUI and CLI.

1. If one original language is confirmed, select a creator-provided/manual
   track matching it.
2. If no matching manual track exists, select the matching `*-orig` automatic
   caption track.
3. If no original language is confirmed and exactly one eligible manual track
   exists, treat it as the presumed original.
4. If no original language is confirmed and multiple manual tracks exist,
   report an ambiguity rather than choosing one.
5. If only non-`*-orig` automatic-caption tracks exist, report that only
   translated subtitles are available.
6. If no eligible tracks exist, report that the video has no subtitles.

A failure while downloading the selected original track must retain the
existing network, rate-limit, unavailable-video, and filesystem diagnostics.
Retry may target the same original track, but the application must never fall
back to a translated track.

## Source Preference and User Feedback

When both sources are available on the confirmed original language, a manual
track wins over automatic speech recognition.

The selection result carries a source classification and warning classification
instead of making the UI infer them from a filename:

- confirmed manual original: no warning;
- presumed manual original: warn that the source language could not be
  independently confirmed;
- original automatic speech recognition: warn that numbers, names, addresses,
  and other details may contain recognition errors.

The desktop displays the warning on the completed video card without changing
the transcript body. The CLI emits the equivalent warning to the warning
stream after successfully saving the transcript. A warning is a successful
result and must not prevent later queue items from running.

The saved filename uses the actual selected language rather than an old user
preference.

## Desktop and Settings Changes

The desktop window no longer displays a subtitle-language label or combo box.
Queue items do not carry a user-selected language. The settings reader accepts
older files containing `Language`, ignores that field, and preserves the output
directory and other supported settings. Newly written settings omit the
language field.

## Command-Line Changes

Online CLI downloads use the shared original-only resolver and invoke exactly
one subtitle source flag for the selected track: `--write-subs` for a manual
track or `--write-auto-subs` for an original automatic track.

The public `-Prefer` and `-Langs` parameters and their language fallback plan
are removed. `-List` remains available for diagnostics. `-CleanOnly` continues
to convert an explicitly supplied/local subtitle workflow without claiming to
identify its original language.

## Error Cases

The user-facing result distinguishes at least these conditions:

- no subtitle tracks;
- only translated automatic captions;
- multiple manual tracks with no trustworthy original-language evidence;
- conflicting or multiple original-language evidence;
- original track selected but download failed;
- normal invalid-link, unavailable-video, rate-limit, network, and filesystem
  failures.

Diagnostics may list compact language tags, but must not include unbounded raw
`yt-dlp` output.

## Verification

Regression tests will cover:

- English manual subtitles winning over a Russian automatic translation;
- an English `en-orig` automatic track winning over all translated automatic
  tracks, regardless of a legacy saved `ru` setting;
- a matching manual track winning over a same-language `*-orig` track;
- an original automatic track succeeding with the accuracy warning;
- one manual track without language evidence succeeding with the
  unconfirmed-language warning;
- multiple manual tracks without language evidence failing as ambiguous;
- translated automatic tracks without an original failing without a download
  attempt;
- `live_chat` and unusable formats remaining excluded;
- rate limiting on an original track not causing translation fallback;
- actual selected language being used in the filename;
- removal and migration of GUI language settings;
- removal of CLI language overrides and use of one source flag; and
- unchanged queue continuation, cleanup, and no-overwrite behavior.

The relevant model, view, core, CLI, lifecycle, installer/package, and smoke
test suites must pass. The final diff will be reviewed separately against this
design and the user request.
