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

## Managed `yt-dlp` Boundary

Every application-managed `yt-dlp` invocation, including version checks,
metadata probes, diagnostic listing, and subtitle downloads, starts with:

```text
--ignore-config
--no-plugin-dirs
```

This prevents portable, user, and system configuration files or external
extractor plugins from adding language selectors, output templates, write
flags, aliases, or alternate YouTube extraction behavior. The application does
not support an app-owned config file or plugins, so there is no exception to
this isolation rule.

Production runs use the bundled `yt-dlp.exe` beside the application files and
do not fall back to an arbitrary executable from `PATH`. An explicitly injected
path remains available only to automated tests.

The bundled and minimum supported stable version for this change is
`2026.07.04`. A newer stable binary placed beside the application is allowed so
that documented manual updates remain possible, but the application validates
both its date-like version and the metadata shape described below. An older
version or incompatible metadata produces `UnsupportedYtDlpContract`, not a
misleading no-subtitles result.

A compatible metadata object contains `subtitles` and `automatic_captions`
properties whose values are null or language-track maps, plus a `formats`
array. Every present language-track map value must be an array of format
objects. Missing properties or incompatible value types fail contract
validation before subtitle availability is classified.

## Subtitle Source Model

The JSON returned by `yt-dlp --dump-single-json` exposes two relevant maps:

- `$.subtitles`: creator-provided/manual subtitle tracks;
- `$.automatic_captions`: YouTube automatic speech recognition plus its
  machine-translated variants.

Each map property name is a raw language-track tag, and its value is the format
list for that track. A track is eligible only when at least one format entry:

- has a normalized `ext` equal to `vtt` or `srt`;
- has a non-empty absolute HTTP(S) `url`; and
- does not use a service-specific protocol.

`live_chat` and other service tracks are always ineligible. Direct VTT is
preferred over direct SRT. Arbitrary `best` fallback to `json3`, `srv*`, TTML,
or an unknown future representation is forbidden. The initial implementation
makes one download invocation with the explicit preference `vtt/srt`; it does
not retry a different language or source after a representation failure.

Within `$.automatic_captions`, a raw tag ending in `-orig` is treated as an
original automatic speech-recognition track. `yt-dlp` may expose the same
original track again without `-orig` for compatibility. Every automatic tag
without `-orig` is untrusted and ineligible, regardless of its display name or
whether it happens to duplicate the original.

The metadata probe does not request translated-subtitle expansion. If an
otherwise supported response contains only untrusted automatic tags, the tool
reports that no verified original track is available; it does not claim to
know whether every such tag is a translation.

## Original-Language Evidence

The resolver maintains three distinct values:

- `RawTrackTag`: the exact property name from `$.subtitles` or
  `$.automatic_captions`, such as `en-US-orig`;
- `CanonicalLanguageTag`: the normalized language tag with one terminal
  `-orig` removed, such as `en-US`;
- `BaseLanguage`: the lowercase primary subtag used only for comparison, such
  as `en`.

`RawTrackTag` is passed to `yt-dlp --sub-langs`,
`CanonicalLanguageTag` is written to the filename and returned to consumers,
and `BaseLanguage` is never used as a download selector. `_` separators are
normalized to `-`; primary subtags are lowercase, script subtags title case,
and region subtags uppercase. Empty or malformed tags and `und`, `mul`, and
`zxx` are not language evidence.

Original-language evidence uses these exact JSON paths and tiers:

1. `$.automatic_captions.<RawTrackTag>` entries whose raw tag ends in `-orig`;
2. audio-bearing `$.formats[]` entries whose `language_preference` is `10`,
   using that entry's `language`;
3. only when tiers 1-2 are absent, audio-bearing `$.formats[]` entries whose
   `language_preference` is `5` (default audio);
4. only when tiers 1-3 are absent, non-descriptive audio-bearing
   `$.formats[]` languages, and only if they reduce to one base language.

An audio-bearing format has an `acodec` value other than empty or `none`.
Entries with `language_preference = -10` are descriptive audio and do not
participate. Multiple codecs or player-client responses with the same
canonical language are deduplicated before evaluating ambiguity.

`$.formats[].format_note` and a top-level `$.language` are not evidence: the
former is presentation text and the latter does not reliably identify original
YouTube audio. Caption and format evidence may share an upstream YouTube signal,
so agreement does not increase confidence; disagreement is still treated as a
contract ambiguity.

If the available evidence conflicts or identifies multiple original languages,
the selector reports an ambiguity instead of guessing.

## Selection Rules

The same resolver is used by the GUI and CLI.

When one evidence base language is confirmed, matching tracks are resolved in
this deterministic order. Each stage stops on ambiguity instead of falling
through to a lower-quality source:

1. Among manual tracks whose canonical tag exactly matches the strongest
   evidence tag, select one, continue if there are none, or report ambiguity if
   there are multiple.
2. Among remaining manual tracks with the confirmed base language, select one,
   continue if there are none, or report ambiguity if there are multiple.
3. Apply the same exact-match rule to `*-orig` automatic tracks.
4. Apply the same unique-base rule to remaining `*-orig` automatic tracks.
5. If no stage selects a track, no verified original subtitles are available.

Manual tracks therefore remain preferred, but a regional or script variant is
never chosen lexicographically. For example, evidence `en` with manual `en-US`
and `en-GB` is ambiguous, while evidence `en-US` selects manual `en-US`
exactly. Multiple format entries under one raw map property are representations
of one track, not multiple language candidates.

When no original-language evidence exists:

1. exactly one eligible manual track is accepted as the presumed original;
2. multiple eligible manual tracks are ambiguous;
3. untrusted automatic tracks without `-orig` are never selected; and
4. if no eligible manual or `*-orig` track exists, no verified original
   subtitles are available.

A failure while downloading the selected original track must retain the
existing network, rate-limit, unavailable-video, and filesystem diagnostics.
Retry may target the same `RawTrackTag` and source only. The application must
never fall back to another language or to an untrusted automatic track.

## Source Preference and User Feedback

When both sources are available on the confirmed original language, a manual
track wins over automatic speech recognition.

The selection result is a domain object containing at least `RawTrackTag`,
`CanonicalLanguageTag`, `BaseLanguage`, `SourceKind`, `Confidence`, and
`WarningCode`. The UI and CLI do not infer source or quality from a filename:

- confirmed manual original: no warning;
- presumed manual original: warn that the source language could not be
  independently confirmed;
- original automatic speech recognition: warn that numbers, names, addresses,
  and other details may contain recognition errors.

The desktop displays the warning permanently on the completed video card,
without changing the transcript body and without relying on color alone. The
CLI emits the equivalent warning to the PowerShell warning stream after
successfully saving the transcript. A warning is a successful result and must
not prevent later queue items from running.

Russian desktop warning text:

- automatic original: `Автоматически распознанные субтитры. Имена, числа,
  адреса и другие детали могут содержать ошибки распознавания.`;
- presumed manual: `Язык не удалось независимо подтвердить. Сохранён
  единственный доступный авторский трек.`

The saved filename uses `CanonicalLanguageTag`, never `RawTrackTag` or an old
user preference. Thus `en-US-orig` is downloaded by that exact raw tag but is
saved with `en-US` in the filename.

## Desktop and Settings Changes

The desktop window no longer displays a subtitle-language label or combo box.
Queue items do not carry a user-selected language. The settings reader accepts
older files containing `Language`, ignores that field, and preserves the output
directory and other supported settings. Newly written settings omit the
language field.

## Command-Line Changes

Online GUI and CLI downloads use the shared original-only resolver. After the
managed prefix, a download invocation contains:

```text
--skip-download
--no-playlist
--extractor-args youtube:skip=translated_subs
--sub-langs <one exact RawTrackTag>
--sub-format vtt/srt
--write-subs | --write-auto-subs
```

Exactly one literal raw tag and exactly one source flag are passed.
`--write-subs` is used for a manual track; `--write-auto-subs` is used for an
original automatic track. The internal `--sub-langs` argument remains required
even though the public PowerShell `-Langs` parameter is removed.

The public `-Prefer` and `-Langs` parameters and their language fallback plan
are removed from selection behavior. For compatibility, explicitly supplying
either old parameter produces a bounded actionable error and a nonzero exit:
`-Prefer and -Langs are no longer supported. Online downloads always use the
video's original language.` They are never silently ignored.

`-List` remains non-downloading diagnostics, uses the isolated metadata probe,
and classifies returned tracks as manual, automatic original, untrusted
automatic, or excluded service track. `-CleanOnly` continues to convert a local
subtitle workflow without claiming to identify its original language; without
the old preference it selects the newest eligible local file, with a
deterministic full-name tie-break.

The isolated metadata probe is exactly:

```text
--ignore-config
--no-plugin-dirs
--skip-download
--dump-single-json
--no-warnings
--no-playlist
<URL>
```

It does not enable either subtitle write flag and does not ask the extractor to
expand translated subtitles. Diagnostic listing renders the returned JSON and
does not invoke raw `yt-dlp --list-subs`.

## Error Cases

The user-facing result distinguishes at least these conditions:

- no subtitle tracks;
- no verified original track, with only untrusted automatic tracks ignored;
- multiple manual tracks with no trustworthy original-language evidence;
- multiple same-base regional or script tracks without an exact evidence match;
- conflicting or multiple original-language evidence;
- an older `yt-dlp` version or unsupported metadata contract;
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
- direct VTT winning over direct SRT, with no arbitrary-format fallback;
- rate limiting on an original track not causing translation fallback;
- `en-US-orig` using the raw tag for download and `en-US` in the filename;
- exact and same-base matching, including ambiguity for `en-US` plus `en-GB`
  when evidence is only `en`;
- original audio at `$.formats[].language_preference = 10` winning over default
  or dubbed audio, and descriptive audio at `-10` being ignored;
- repeated codecs and player responses for one language being deduplicated;
- empty, malformed, `und`, `mul`, and `zxx` tags being ignored as evidence;
- external config files and plugin directories being disabled on every managed
  invocation;
- one literal `--sub-langs` value, one source flag, and
  `youtube:skip=translated_subs` on every download;
- the bundled `2026.07.04` version being accepted, an older version being
  rejected, and an incompatible metadata shape producing
  `UnsupportedYtDlpContract`;
- removal and migration of GUI language settings;
- old CLI language overrides failing clearly, `-List` remaining
  non-downloading, and warning results retaining exit code zero;
- unchanged queue continuation, cleanup, and no-overwrite behavior.

The relevant model, view, core, CLI, lifecycle, installer/package, and smoke
test suites must pass. The final diff will be reviewed separately against this
design and the user request.

## Contract References

The implementation contract was checked against the bundled stable
`yt-dlp 2026.07.04` (`997fa1408`) and the official project documentation:

- configuration and plugin isolation:
  <https://github.com/yt-dlp/yt-dlp/blob/master/README.md>;
- bundled extractor implementation:
  <https://github.com/yt-dlp/yt-dlp/blob/997fa1408/yt_dlp/extractor/youtube/_video.py>;
- current YouTube extractor arguments, including `skip=translated_subs`:
  <https://github.com/yt-dlp/yt-dlp/blob/master/README.md#youtube>.
