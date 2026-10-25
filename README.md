# Swift Video Forge

Trim, join, resize, crop, turn, re-time and take apart video — offline, on
AVFoundation, with `swift-image-forge` for the still frames.

```swift
import VideoForge

// A trim: instant, and the frames are never decoded.
let result = try await VideoForge.process(clip, to: out, options: .trim(.between(5, 15)))
result.passedThrough   // true — nothing was re-encoded

// A vertical crop for a reel, scaled and cropped in one pass.
try await VideoForge.process(clip, to: reel, options: VideoProcessOptions(
    operations: [.resize(.fill(width: 1080, height: 1920))]))

// A GIF out of the first three seconds.
try await Frames.animate(clip, to: loop, fps: 12, trim: .until(3), maxPixelSize: 480)

// A reaction cam in whichever corner covers no face.
let pip = try await VideoForge.pictureInPicture(talk, overlay: cam, to: out)
pip.placement.faceCoverage   // 0

// Music under the speech, ducked 10 dB while somebody talks.
let scored = try await VideoForge.addMusic(song, to: talk, destination: out2)
scored.loudness              // −18.3, measured on the written file
```

## Two roads, and a writer for what they cannot do

Which one a job takes is the most consequential thing about it, so
``VideoProcessResult/passedThrough`` says whether the frames were left alone.

- **Composition** — trimming, joining, changing speed, dropping a track are
  rearrangements of *time*. An `AVMutableComposition` points at the source's
  samples rather than reading them, so a trim of a two-hour recording is a
  second of work and loses nothing.
- **Render** — cropping, scaling, turning and mirroring have to redraw every
  frame. Built on `AVMutableVideoComposition` with a Core Image handler, written
  by an export session, so audio, subtitle and timed metadata tracks come along
  untouched.

A job that needs both gets both, with the time work first — so the render road
only ever sees the frames that survived the trim. Both write with the codec
`ExportSpec.codec` names (see Codecs below).

**The writer road** (0.5.0) takes over only where an export session cannot be
told what was asked: a **bitrate**, a **quality** or a **frame rate** (no preset
takes any of them), and a **ProRes 4444 redraw** (see Codecs). The same Core
Image composition feeds an `AVAssetReaderVideoCompositionOutput`, and an
`AVAssetWriter` configured by ``WriterSettings`` writes it; sound and sidecar
tracks are copied untouched unless time is rescaled. Every other job takes the
export session exactly as before — measured below.

A narrow **copy** road adds tracks: it reads every sample of every track and
writes it back unchanged beside the new ones. It exists for subtitles, because
the composition road cannot make a subtitle a player will offer.

The writer pieces are public, because swift-censor-kit writes through them too:
``WriterSettings/derive(from:codec:bitRate:quality:frameRate:size:keepsAlpha:processesInRGB:)``
(the source's codec story, bitrate, depth, colour tags and pixel format, as a pure
function) and ``WriterPump`` (feeding several writer inputs on demand, which is
what keeps a writer from deadlocking on an input it has throttled).

## Bitrate, quality and frame rate (0.5)

```swift
// A bitrate (VBR target), or a quality, and a frame rate.
try await VideoForge.process(clip, to: out, options: VideoProcessOptions(
    operations: [.resize(.height(720))],
    export: ExportSpec(codec: .hevc, bitRate: 4_000_000, frameRate: 30)))
```

Up to 0.4.0 `ExportSpec.bitRate`, `quality` and `frameRate` were saved in recipes
and read by nobody. Measured with ffprobe on `testsrc2` clips (12 s 1080p30 for
rates, macOS 27, M-series):

| asked bitrate | H.264 | HEVC 8-bit | HEVC Main 10 | HEVC + alpha |
|---|---|---|---|---|
| 1 Mb/s | 1.27 | 1.90 | 1.31 | 1.73 |
| 2 Mb/s | 1.98 | 2.06 | 2.18 | 2.11 |
| 4 Mb/s | 3.96 | 3.93 | 4.10 | 4.01 |
| 8 Mb/s | 7.33 | 7.83 | 7.94 | 7.92 |
| 16 Mb/s | 12.9 | 14.2 | 15.5 | 14.8 |

A VBR target: within 1–8 % from 2 to 8 Mb/s; below what the picture needs the
encoder floors (HEVC at ~1.9 Mb/s on this pattern), above it the encoder spends
less than asked.

| quality | 0 | 0.25 | 0.5 | 0.75 | 0.9 | 1 |
|---|---|---|---|---|---|---|
| H.264, Mb/s | 1.15 | 1.57 | 4.08 | 11.9 | 22.6 | 36.8 |
| HEVC, Mb/s | 0.46 | 0.78 | 3.20 | 12.0 | 22.5 | 33.7 |
| HEVC Main 10, Mb/s | 1.23 | 2.26 | 7.93 | 20.5 | 40.0 | 52.3 |

A bitrate wins over a quality when both are given. With neither — a frame rate
alone — the source's own rate is asked for, scaled down with a smaller picture,
never below a floor of 0.05 bits a pixel a frame.

**Frame rate** drops or repeats frames; the clip keeps its length and the sound
is copied untouched:

| source → asked | frames | video / audio | last frame | kept |
|---|---|---|---|---|
| 4 s H.264 60 fps + AAC → 30 | 240 → 120 | 4.000 / 4.000 s | 3.967 s | audio MD5-identical, BT.709 tags |
| 4 s HEVC Main 10 HLG 24 fps + AAC → 30 | 96 → 120 | 4.000 / 4.000 s | 3.967 s | 10-bit, BT.2020 / HLG tags |
| 4 s H.264 60 fps → ProRes 422 at 30 | 240 → 120 | 4.000 / 4.000 s | 3.967 s | |
| 2 s HEVC with alpha 30 fps → 24 | 60 → 48 | 2.000 s | 1.958 s | the alpha (255 / 80 read back) |

**Which codec honours what:** H.264, HEVC and HEVC with alpha take a bitrate, a
quality and a frame rate. ProRes takes a frame rate only: its encoders refuse a
bitrate and a quality outright (`canApply` is false), so either one with ProRes
throws `codecTakesNoRate` before anything is written.

**The other command lines did not move.** Twenty `vid` command lines that ask for
none of this — a copied trim, re-encoded trims, `--codec hevc`, resize (tagged,
untagged, 10-bit), crop, rotate, ProRes 422 and 4444 without a redraw, speed with
`--reencode` and muted, grade, two joins, mute, reverse, music, audio — were run
through `vid` 0.7.0 and the 0.8.0 build and compared by decoded frames and audio
(ffmpeg `framemd5`, each side re-run up to 3 times, since VideoToolbox is not
repeatable). 17 matched. The other 3 differ from 0.7.0 no more than 0.7.0 differs
from itself: crop's frames are 53.4 dB PSNR from 0.7.0, exactly as far as two 0.7.0
runs are from each other, and join and `speed --reencode` have identical frames
and an AAC encoder that gave a different stream on each 0.7.0 run. The deliberate
differences are the fixes below: passthrough speed with sound, HLG tags, alpha,
ProRes 4444 redraws, reverse.

Re-run for 0.6.0, against `vid` 0.8.0: 16 of the 20 identical. `rotate` and `grade`
differ from 0.8.0 exactly as much as two 0.8.0 runs differ from each other (69.8 dB
PSNR both; 57.2 dB between 0.8.0 runs, 57.7 dB to 0.6.0), and `speed --reencode` and
the same-size join have identical frames and sound whose AAC differed on every
0.8.0 run (−5 to +20 dB SNR between two 0.8.0 runs; 0.6.0's runs fall inside that).
A subtitled clip trimmed, cropped, sped up and resampled to 24 fps keeps identical
frames and sound too — only its subtitle track changed.

## Codecs

```swift
// HEVC, whatever came in. A trim to the codec the clip already has still
// passes through untouched.
try await VideoForge.process(clip, to: out, options: VideoProcessOptions(
    operations: [.resize(.height(1080))], export: ExportSpec(codec: .hevc)))

// What a spec comes to for a clip: `.source` resolved, the depth rule
// applied, and the container that can hold it.
let codec = try spec.codec(for: info)                          // .hevc
let container = try spec.container(for: info, destination: out) // .mov
```

| `VideoCodec` | written as | depth | containers |
|---|---|---|---|
| `.source` *(default)* | the clip's own: `avc1` → H.264, `hvc1`/`hev1` → HEVC (HEVC with alpha when it carries alpha), ProRes → ProRes; anything else → HEVC if 10-bit, H.264 if not | the source's | the source's |
| `.h264` | H.264 High | 8-bit | mov, mp4, m4v |
| `.hevc` | HEVC Main, or **Main 10** from a 10-bit source | 8 or 10 | mov, mp4, m4v |
| `.hevcAlpha` | HEVC Main with alpha | **8-bit** | mov, mp4, m4v |
| `.proRes422` | ProRes 422 (`apcn`), 4:2:2 | 10-bit | **mov only** |
| `.proRes4444` | ProRes 4444 (`ap4h`), 4:4:4:4 | 12-bit | **mov only** |

The raw values — what JSON, recipes and every error message say — are the names
typed at a command line: `source`, `h264`, `hevc`, `hevc-alpha`, `pro-res422`,
`pro-res4444`. Up to 0.5.0 they were the case names, so a message told a `vid`
user to write `proRes422`.

**10-bit footage is never written by an 8-bit encoder.** Asking for `.h264` or
`.hevcAlpha` with a 10-bit source throws `wouldTruncateDepth` before anything is
written; `.source` keeps 10-bit footage 10-bit, even when the clip's own codec is
one this library cannot write (it becomes HEVC Main 10). A join is deep if any of
its clips is. **ProRes's depth is its own, not the footage's:** it declares 12 bits
(16 with alpha) whatever it was made from — measured on ProRes written by
AVFoundation from 8-bit H.264 and by ffmpeg — so up to 0.4.0 ProRes made from
8-bit footage could never go back to H.264. `.source` still keeps ProRes deep, but
an 8-bit codec asked for by name is allowed from ProRes. ProRes asked into `.mp4` throws `codecNeedsContainer`; ProRes that
merely inherited `.mp4` from its source is written to `.mov`. Every road honours
all of this — the export session, a join, `addAudio`, and `reverse`, which reads a
10-bit source at 10 bits.

**Up to 0.3.1 none of it happened.** `ExportSpec.codec` was read by nobody and
every re-encode used the H.264 preset, so `.hevc` and `.proRes422` wrote H.264,
and a 10-bit HEVC clip came out of a plain resize — no codec asked for — as 8-bit
H.264. Measured on synthetic clips, 0.3.1 → 0.4.0, read back with ffprobe; "levels"
counts the distinct 10-bit luma values along one row of a ramp that holds 256:

| 10-bit HEVC source, then | 0.3.1 | 0.4.0 |
|---|---|---|
| resize, codec left alone | h264 yuv420p, 63 levels | hevc Main 10, 256 levels |
| resize `.hevc` | h264 yuv420p, 63 levels | hevc Main 10, 256 levels |
| resize `.proRes422` | h264 yuv420p | prores yuv422p10le, 261 levels |
| resize `.h264` | h264 yuv420p, 63 levels | refused |
| reverse | h264 yuv420p, 66 levels | hevc Main 10, 253 levels |

Also measured, and now handled:

- **The HEVC-with-alpha preset will not copy a source without alpha** (-11838 /
  -16976) but redraws one happily, so a time-only job written as `.hevcAlpha` goes
  through an empty render.
- **ProRes shifted untagged footage.** Redrawn from an untagged source, ProRes
  frames came out 27–39 codes brighter, tagged SMPTE 170M with no transfer
  function; H.264 and HEVC tag Rec. 709 and kept every value. A redraw of untagged
  footage is now tagged Rec. 709 — the convention for untagged video — and ProRes
  keeps every value.
- **A tagged source lost its tags on a redraw** (fixed in 0.5.0). A video
  composition built over an `AVComposition` — every job, since the time steps
  come first — picks up no colour tags, so a BT.2020 HLG clip was redrawn and
  labelled Rec. 709: HDR relabelled as SDR. The tags are now read off the track.
- **HEVC with alpha lost its alpha to the default codec** (fixed in 0.5.0). It
  is `hvc1` like any HEVC; only the format description's `ContainsAlphaChannel`
  tells them apart, and nothing read it, so `.source` meant plain HEVC and a
  resize wrote no alpha. `TrackInfo.hasAlpha` reads it now, and `.source` keeps it.
- **ProRes 4444 redraws were not full depth** (fixed in 0.5.0). On the 256-level
  ramp a 4444 *redraw* through the export session kept 95 levels (a copy kept all,
  as did ProRes 422 and HEVC redraws). Measured through the writer road, ProRes
  keeps 95–101 levels from every RGB pixel format the compositor can hand it —
  32-bit BGRA, 64-bit half float, 16-bit ARGB, 16-bit Y'CbCrA — and 254–264 from
  10-bit Y'CbCr. So a 4444 redraw now takes the writer road, fed 10-bit 4:4:4
  Y'CbCr: **255 levels**. Only footage that keeps its alpha still goes through
  16-bit Y'CbCrA (no 10-bit Y'CbCr format carries alpha), at the old ~100 levels.

ProRes is the fast, large choice. Three seconds of 4K30 test pattern with AAC, `vid` release build on an M3 Max:

| | H.264 / HEVC | ProRes 422 | ProRes 4444 |
|---|---|---|---|
| re-encode, time only | 1.1 s · 42 MB RSS · 7–8 MB | 0.6 s · 120 MB · 88 MB | 0.6 s · 185 MB · 175–183 MB |
| grade (redraw) | 1.2 s · 70 MB RSS · 6–8 MB | 0.6–0.7 s · 129–144 MB · 92 MB | 0.7–0.8 s · 200 MB · 184–187 MB |

## Subtitle tracks

```swift
import SubtitleKit

let cues = try SubtitleParser.parse(contentsOf: srt)
try await VideoForge.addSubtitles(
    [Subtitles(cues: cues, language: "en", isDefault: true),
     Subtitles(cues: japanese, language: "ja")],
    to: clip, destination: subtitled)

for track in try await VideoForge.subtitles(in: subtitled) {
    print(track.language ?? "?", track.cues.count)
}
```

Written as **`tx3g`** (ffmpeg's `mov_text`) in `.mp4`, `.m4v` or `.mov`; read
back from `tx3g`, QuickTime `text`, `wvtt` and CEA-608 closed captions. Two
earlier attempts at writing subtitles failed, so every route was measured on
macOS 27 before this one was chosen:

| route | result |
|---|---|
| `tx3g` from a hand-built sample entry (2026-09) | file would not reopen (-12848) |
| AVCaption writer, text media (`tx3g`/`text`, .mov and .mp4) | refused, -12780, every combination |
| AVCaption writer, `.subtitle` media | uncatchable exception: unsupported media type |
| AVCaption writer, CEA-608 closed captions | writes — but CJK, Arabic and emoji come back as `█`, line breaks are lost, overlapping cues are cut short |
| `wvtt` samples | writes and reads back, but loading the subtitle menu fails (-12718) and ffmpeg 9 cannot read it in MP4 |
| **`tx3g` with AVFoundation's own sample description** | **reopens, lists in the subtitle menu, ffmpeg decodes every cue exactly** |

The description that works is the one AVFoundation itself reports for a track
ffmpeg wrote, rebuilt from its keys. Then the mux:

- **The composition road loses the menu.** A passthrough export writes every
  track with alternate group 0, and a subtitle outside an alternate group is
  never offered — the legible media-selection group came back empty. The copy
  road puts every subtitle track, old and new, in one writer input group, and
  since 0.6.0 every other job writes its subtitles through it too (below).
- **macOS 26's async writer receivers deadlocked** on a plain H.264 + AAC
  copy, two seconds in, every time. Callback feeding on one serial queue does
  not, and its state sits behind one `Mutex`, so the compiler checks it.
- **Nothing else is touched.** On a 90 s 1080p clip with B-frames the video
  and audio packets were MD5-identical to the source, every timestamp
  identical, 0.6 s warm. Movie metadata and chapter-list associations are
  carried across.

What a `tx3g` track cannot do is hold two cues at once, so overlapping cues
are written as what a viewer sees — stacked, in the order they appeared — and
read back as those pieces. Cues past the video's end are cut at the end. At
most one track is the default; the rest wait in the menu.

### Through a trim, a speed change and a redraw (0.6.0)

Up to 0.5.0 a trim that cut inside a subtitle sample was read three different
ways. An export cannot cut a sample, so it kept the whole sample and wrote an
edit list starting partway into it (`elst` media time 250 for a 0.25 s trim).
AVPlayer honours that edit; ffmpeg's `mov_text` reader ignores it, and
`AVAssetReaderTrackOutput` hands a subtitle track back in *media* time, edit
ignored. Where a cue starts after the trim, read three ways:

| trim | ffmpeg 0.5.0 | `subtitles(in:)` 0.5.0 | AVPlayer 0.5.0 | all three, 0.6.0 |
|---|---|---|---|---|
| `--from 0.25` ("one", 1→2 s) | 0.000 | 1.000 | 0.750 | 0.750 |
| `--from 1.0` ("one", 1→2 s) | 0.000 | 0.000 | 0.000 | 0.000 |
| `--from 2.5` ("three", 3→4 s) | 0.000 | 1.000 | 0.500 | 0.500 |

A trim on a sample boundary (1.0 s) had no partial edit, which is why it alone
agreed. Now subtitle tracks never ride a composition: they are taken out of it,
their samples cut at the edit and re-timed (a speed change scales them), and
written back by the remuxer with a plain edit and in the subtitle group. The
picture and sound go through the export as before and are copied untouched —
decoded frames and audio identical to 0.5.0's on trim, crop, speed and
`--fps`. It also fixed two things on the way: a re-encoding export (crop,
resize, rotate, grade, music, a forced re-encode) **dropped** the subtitle
track, and a passthrough trim left it in alternate group 0, where players hide
it. Reading goes through the track's edits too, so a file trimmed by 0.5.0, or
by anything else that writes such an edit, reads as it plays.

### Timed metadata through a trim (0.7.0)

Timed metadata had the subtitles' fault, MEASURED on a clip with one 0.5 s
boxed sample every half second, linked to its video (`cdsc`):

| job | ffprobe 0.6.0 | ffprobe 0.7.0 | link to the video |
|---|---|---|---|
| trim `--from 0.25` | every sample 0.25 s early (first at −0.5) | first 0.000–0.250, the rest exact | lost → kept |
| trim `--from 1.6` | 0.4 s early | first 0.000–0.400, exact | lost → kept |
| trim 0.25 s on the writer road (`--bitrate`) | 0.25 s early | exact | lost → kept |
| trim `--from 1.0`, speed 2× | exact | exact | lost → kept |

AVPlayer and `AVAssetReaderOutputMetadataAdaptor` were right all along; the
raw `AVAssetReaderTrackOutput` hands metadata back in media time, as it does
subtitles. So metadata tracks now take the subtitles' road: taken out of the
composition, cut and re-timed through its edits, written back with a plain
edit, and linked to the written video again.

### Joins keep their subtitles (0.7.0)

Up to 0.6.0 `join` dropped every subtitle track (it showed only in
`lostTracks`). Each clip's cues are now moved to where that clip starts and
cut at its end — a cue running past its clip stops there — and laid in one
track per language (a clip's second English track joins the others' second);
a clip with no track in a language leaves a gap. The first track any clip
showed by default stays the default. Read back by ffmpeg and by
`subtitles(in:)` alike, on the export and writer roads. The cues are read and
written again as `tx3g`, so styling is not kept; text and timing are.

## Picture-in-picture (0.7.0)

```swift
let done = try await VideoForge.pictureInPicture(talk, overlay: cam, to: out,
    options: PictureInPicture(start: 2, end: 8, roundness: 0.1))
done.placement.corner        // .topLeft
done.placement.rect          // (29, 29, 384, 288), pixels from the top left
done.placement.faceCoverage  // 0: it covers no face it saw
```

`PictureInPicture` holds `start`/`end` (seconds on the main clip), `corner`
(`.auto` by default), `size` (its width as a share of the frame's; a tall
overlay is shrunk to fit), `margin`, `roundness`, `fullFrame` (a cut-away,
scaled to cover and cropped from the centre), `fade` and `mix` (its own sound,
muted by default). The main clip decides the result — frame, length, sound,
subtitles and timed metadata — and the codec plan's rules hold: a 10-bit or
HDR main clip stays 10-bit or HDR, and refuses an 8-bit codec.

**The automatic corner is found by looking.** Nine frames under the overlay's
stretch are searched for faces with swift-image-forge's Vision detector, and
the corner covering the smallest share of any face wins; ties go to the corner
farthest from every face, then bottom right. No threshold: a corner covers
part of a face or it does not.

It is drawn by a custom compositor (`OverlayCompositor`): the Core Image
composition the render road uses hands its handler one source frame, and an
overlay needs two. Each track's frames come as stored, so each is turned
upright by its own transform (a phone's portrait overlay is not laid on its
side). It is written through the export session, or — for a bitrate, a
quality, a frame rate or ProRes 4444 — the writer road and its shared
WriterPump.

MEASURED, blind — the overlay found where the written frame differs from the
main clip, the faces by Vision:

| check | result |
|---|---|
| asked rect `[29,29,384,288]` (720p, `--at 2-8`), from the frame difference | `[29,29,385,289]` |
| first and last frame with the overlay, `--at 2-8` at 30 fps | frames 60 and 239 — 2.000 s, 7.967 s |
| `start: 0.51, end: 1.49` | frames 16–44, exactly |
| face in the bottom-right: corner chosen, faces seen, covered | top left (or bottom left), 9 in 9 frames, 0 |
| Vision on the written frame: a face meeting the overlay | none |
| PSNR outside the overlay, against the source (8-bit H.264) | 36.6 dB — the render road's own redraws: 35.4 |
| 10-bit HLG main: codec, depth, tags | HEVC Main 10, HLG / BT.2020 kept; 226 of a ramp's 256 levels with the overlay in frame, 254 without |
| an SDR overlay's 75% grey (Y′ 720) over HLG | written at Y′ 625 — converted, not pasted as SDR codes |
| overlay sound at `mix: 0.5` | −16.5 dB under the main tone's −10.5, within 1 dB; −50 dB and below when muted |

Three things found on the way: the compositor's sources are half-float RGB
because every Y′CbCr arrangement measured worse (33.3–35.4 dB outside the
overlay) and an untagged clip's Y′CbCr was read with the wrong matrix; Core
Image's colour management stays on because AVFoundation hands each source over
in its own colour space; and a main clip whose picture ends before its sound
gets black frames for the rest, rather than failing the export.

## Music under speech (0.7.0)

```swift
let done = try await VideoForge.addMusic(song, to: talk, destination: out,
    bed: MusicBed(level: -12, duck: 10, loops: true))
done.speech       // [1.50...5.36, 8.56...12.22, 13.92...17.66]
done.loudness     // −18.3 LUFS, measured on the written file
done.truePeak     // −2.6 dBTP
```

Every number is measured, none guessed:

1. **Speech** is found on-device (`SpeechDetection`, below).
2. **The level is set against the speech.** The clip's speech and the music
   are both measured (ITU-R BS.1770: K-weighted, gated), and the music gained
   to sit `level` LU under the voice between sentences — so a loudly mastered
   song and a quiet one land in the same place. With no voice it is set
   against the clip's loudness; with no sound kept, against −16 LUFS.
3. **The duck** is a straight line in decibels: the music starts down
   `attack` before each sentence, so it is all the way down as the first
   word lands, and comes back over `release`. Sentences closer than attack +
   release are one, so it does not bob between them.
4. **The peak.** The mix is made once to find its true peak (4× oversampled)
   and turned down as a whole if it would pass −1.5 dBTP; then made again and
   written. The written file is decoded and measured; a peak over −1 dBTP
   after encoding is written again, quieter by the overshoot.
5. **The picture is copied**, with subtitles and timed metadata — only the
   sound is new. Music shorter than the clip ends (or `loops`, each join an
   equal-power crossfade of up to 1 s); `fadeIn`, `fadeOut` and `start` shape it.

MEASURED on three `say` sentences over a test pattern, the "music" carrying a
9.5 kHz tone the voices leave alone, read by a single-bin DFT in 0.25 s
windows inside the sentences (37) and between them (9); loudness checked
against ffmpeg's `ebur128` filter:

| asked | duck measured on the file | loudness (ffmpeg) | true peak (ffmpeg) |
|---|---|---|---|
| duck 10 | 10.10 dB | −18.3 (−18.2) LUFS | −2.6 (−2.6) dBTP |
| duck 6 | 6.18 dB | −18.2 (−18.2) | −2.4 (−2.4) |
| duck 18, level −6 | 18.05 dB | −18.4 (−18.3) | −2.6 (−2.6) |
| a clip peaking +0.7 dBTP, music at +6 LU | mix turned down 14.3 dB | −12.0 (−12.0) | −1.5 (−1.5) |

Two musics 20 dB apart land within 0.5 dB of each other. Every video frame's
MD5 is the source's (180 of 180). A 19 s clip takes 0.5 s.

### Finding speech

| detection | F1, worst–best | edges | claps and chord swells in the gaps |
|---|---|---|---|
| `energy` — speech-band loudness against the room's quiet | 0.872–0.998 | 8–43 ms | ducked under (precision 0.77) |
| `classifier` — Apple's sound classifier, 0.5 s windows | 0.975–0.986 | 47–83 ms | ignored |
| **`both`** (the default) — energy frames the classifier hears a voice in | **0.987–0.998** | **8–42 ms** | ignored (precision 0.98) |

Six `say` sentences in four voices with gaps of 0.8–3 s, scored every 10 ms
against where each sentence was placed, over digital silence, room noise at
−45 dBFS, noise at −32 dBFS, music at −30 dBFS, and claps and chords in the
gaps. Each threshold was swept, not chosen: the energy margin (3–15 dB; 4.5
kept, within 0.002 F1 of the best and with headroom for uneven noise), the
bridge between words (0.2–0.5 s; 0.5), the classifier's window (its own 3 s
scored 0.81–0.83 — a second of blur either side; 1 s 0.92; 0.5 s 0.98) and how
far past a voice the energy may reach (0–0.25 s; 0.05). A classifier window
speaks for its middle, not its whole length: counting all of it put edges 2.1 s
out.

### Sound effects, in the same mix (0.7.0)

```swift
let done = try await VideoForge.addSounds(
    [SoundCue(file: whoosh, time: 3.2), SoundCue(file: hit, time: 7.5, gain: -3)],
    to: talk, destination: out)
done.sounds[0].level        // −23.1 LUFS: 6 under the speech around it (−17.1)
```

One-shot effects go through the same mixer as the bed — `soundtrack(_:…)` takes
music and effects together and writes them in one pass, the picture copied.
Each effect is levelled against the speech within 3 s of it (its BS.1770
loudness there; with no speech, the clip's sound there; with no sound,
−16 LUFS): its loudest 400 ms — or all of a shorter one — sits `underSpeech`
(6 LU) under it, plus its own `gain` and the shared one. The mix's true peak
is held under −1 dBTP as for music, and each effect's level as mixed is
reported. MEASURED with a 1 kHz tone for the clip and a 1.25 kHz burst for the
effect, read apart on the written file by a single-bin DFT: asked 6 and 3 dB
under, they came out 6.64 and 3.64; the clip's loudness and true peak match
ffmpeg's `ebur128` to 0.1.

## Beauty and background blur (0.7.0)

```swift
// Skin smoothed, under-eyes and teeth lifted a little, nothing reshaped.
try await VideoForge.beautify(talk, to: out, beauty: Beauty(smoothing: 0.5))
// The people sharp, everything behind them soft.
try await VideoForge.process(talk, to: out2, options: VideoProcessOptions(
    operations: [.blurBackground(BackgroundBlur(amount: 0.5))]))
```

`.beauty` smooths skin with swift-video-grade's skin filter — Vision finds
the faces in every frame, a skin-tone key keeps eyes, brows, lips and hair
sharp — and retouches the largest face with
[swift-face-beauty](https://github.com/arraypress/swift-face-beauty), following
its landmarks tracked four times a second (re-timed through any trim or speed
change in the same job). `.blurBackground` finds the people with Vision's
person segmentation — no depth model, nothing to download — and blurs the
rest, up to 4% of the frame's height. Both run in the frame as shot, before
any crop or turn, and both are redraws on the render road.

MEASURED on a synthetic portrait (made by `imagine --fast`; nobody's
likeness) over a fine grain, 720p — texture is a frame less its 5×5 mean:

| check | result |
|---|---|
| smoothing 0.5: cheek texture left | 51% |
| smoothing 1.0: cheek texture left | 12% |
| outside the face, PSNR against the source | 42.77 dB at 0.5 and 42.74 at 1.0 — an untouched redraw: 42.77 |
| background blur 0.5: background texture left | 1.7% |
| … the person's texture left (ProRes) | 98.9% |

Through H.264 the person kept 93%: the encoder's rate control, not the pass —
the same two jobs written as ProRes keep it all. A frame of infinite extent
(where a clip's picture ends before its sound) is passed over rather than
masked, which up to the first build crashed AVFoundation.

## Shots and sound levels (0.8.0)

```swift
let shots = try await Scenes.detect(url)
shots.changes   // [cut at 2.5 (0.41), cut at 7.5 (0.38), dissolve at 12.38 (0.89)]
shots.scenes    // [0..<2.5, 2.5..<7.5, 7.5..<12.38, 12.38..<17]

let levels = try await SoundLevels.measure(url)       // RMS dBFS every 50 ms
levels.silences(below: -45, atLeast: 0.5)             // where the sound itself is quiet
```

No Apple API finds shot changes — probed against the macOS 27 SDK: VideoToolbox's
`sceneChange` is a hint the *caller* passes to HDR metadata, and MediaIntelligence
offers highlights and faces. `Scenes` reads every frame (up to 30 a second) at
256×144 into a colour histogram, and a Vision feature print (revision 2) every
quarter-second:

- **A cut** is a frame whose histogram jumps at least 5× the median jump of the
  second around it, and at least 0.02 — and the change *persists*: every frame of
  the third of a second before differs from every frame of the third after by at
  least half the jump. A flash or a dropped frame comes back; a cut does not.
- **A dissolve** is where the fingerprints half a second either side differ by
  0.7 or more — the smaller of two such pairs a quarter-second apart, so one odd
  frame cannot make one — at the strongest point, away from any cut.

Every number was measured on clips whose changes are known to the frame: 12 hard
cuts between different dishes, 3 cuts to a close-up of the same plate, 4 re-cuts
of one aerial of the same bridge (the weakest cuts: 6.6× their surroundings, 0.027
absolute) and 3 one-second dissolves (0.885 and up); and on a slow pan, a fast
zoom, a 2 s lighting ramp (0.59), a 2-frame flash and a minute of real aerial
footage, which must find nothing (the strongest camera motion: 4.3×). **22 of 22,
nothing false, cuts on the exact frame, dissolves within 0.12 s**; every ratio
from 4 to 6 and dissolve threshold from 0.6 to 0.8 gave the same. The thresholds
were chosen on these clips. A dissolve between two pictures that look alike can be
missed. About 1 ms a frame on Apple silicon (51 s of 960×540 in 1.6 s).

## Measured

Everything here was measured on macOS 27 before the code was written, and two
of the four contradicted the obvious reading.

**Speed drifts on export, but only with audio.** Asking a 3.00s clip for 2×
gave a composition of exactly 1.50s and an exported file of **1.61s**; 0.5×
gave 6.00s against **6.09s**. Video alone was exact either way, which is how
the audio time-pitch pass was identified as the cause. The composition always
knows the right answer, so the export is clamped to its duration — one line,
and the difference between 1.50s and 1.61s.

**`Depth` is not bit depth.** The `Depth` format extension reads **24 for
8-bit H.264 and 24 for 10-bit HEVC Main10 alike**. Keying off it marks every
ordinary clip as deep — and being deep is what forbids re-encoding as H.264.
`BitsPerComponent` is the real signal: present and equal to 10 on 10-bit
footage, and **absent altogether** on 8-bit.

**Holding every frame does not scale.** 90 frames of a *640×360* clip is
**79 MB** as BGRA. The same arithmetic on ten seconds of 4K is roughly ten
gigabytes. Anything that holds a whole run asks ``Frames/memoryCost(size:count:)``
first and refuses with a message saying to trim it, rather than taking the
machine down.

**On real footage.** Four Pexels clips — a 1080×1920 vertical, a 48 MB 4K
UHD, a 1920×1080 with AAC stereo, and a 720p:

| | measured |
|---|---|
| describe (48 MB 4K) | **0.00s** — the container only, nothing decoded |
| trim 1s from 4K | **0.01s**, passthrough, **2530× realtime** |
| 4K → 720 high | 0.28s for two seconds of footage |
| 4K landscape → 1080×1920 reel | 0.29s |
| speed 2× / 0.5× / 4× with AAC stereo | **0.0% off** at every factor — the *file's* length; see below |
| GIF, 2s at 10fps, 400px | 0.36–1.71s |
| reverse a whole 4K clip | refused: 16.8 GB against a 2 GB budget |

**The sound of a passthrough speed change was never re-timed** (fixed in
0.5.0). The file came out the right length, but a passthrough export copies the
sound as it is: at 0.5× it wrote 3.02 s of sound under 6 s of picture, MD5-identical
to the source's, and at 2× the first half of it at normal speed. A speed change
with sound now copies the video samples (frame for frame, MD5-identical) and sends
only the sound through a spectral time-pitch pass: 0.5×, 2× and 4× all come out
with sound exactly as long as the picture, and the job still reports
`passedThrough`.

**Two more found while measuring** (fixed in 0.5.0): `reverse` dropped the
display transform, so a phone clip shot upright (360×640 shown) came back lying
on its side at 640×360; and a join of clips of different sizes, exported with no
video composition, wrote one sample description per size — AVFoundation played
it, ffmpeg could not decode past the first clip. Reversed chunks now carry the
transform, and a mixed-size join is drawn at the first clip's size. `reverse` now
derives its writer settings like every other writer here, which adds the expected
frame rate as an encoder hint: on a 10-bit clip its decoded frames moved from
41.8 to 42.1 dB PSNR against the source.

**Joining clips turned different ways** (fixed in 0.6.0). A composition track
holds one transform, and the join took the first clip's: a phone's portrait clip
after a landscape one lay on its side, and a portrait first clip turned every
landscape clip after it. The rule now: **the join is shown the way its first clip
is, at that clip's size; each clip is turned upright by its own transform and
fitted inside, centred, black around it** — a portrait clip in a landscape join is
pillarboxed, a landscape one in a portrait join letterboxed, nothing cropped or
stretched. Clips that all turn alike and share a shape take the old road
unchanged. Clips of another *shape* were stretched to the first one's before;
they are fitted now. Tested with synthetic four-colour clips carrying identity,
quarter-turn and half-turn transforms, read back corner by corner against what
AVFoundation shows for each clip alone, on the export and the writer road.

**Joining clips with no sound failed** (fixed in 0.6.0): the joined audio track
held nothing but empty edits and the export stopped with "Operation Stopped".

**A reader that never answers** (0.7.1). On macOS 27 an `AVAssetReader` can
block inside `copyNextSampleBuffer` for good (found by swift-caption-kit 0.8.1:
the call waits in `FigSemaphoreWaitRelative` and never returns). Measured here, a
read at a time with a 30 s guard: the compositions this library builds — trim,
speed, trim + speed, join, the sped-up copy — read **0 stalls in 200** each on
static clips, including one made the way caption-kit's was; picture-in-picture,
moving clips, the export-session road, blur and beauty **0 in 50** each.
Compositions with several cuts in one source, which only caption-kit builds,
stalled **3 times in 1,200 reads**. So the pump now has a watchdog: a step blocked
past 30 s ends the job, the stuck reader is left alone (cancelling one mid-read
crashed AVFoundation in caption-kit's probe), a late answer from it can never
finish a file over the retry's, and a cancel no longer waits on it. The writer
road and the remuxer start once more after a stall; a second is an error, never
a hang.

The trim numbers are the argument for the composition road: bounding a 4K clip
takes a hundredth of a second and does not touch a pixel.

**Encoders want even numbers.** Odd dimensions are refused by some encoders and
silently rounded by others, and silent rounding is how a frame-accurate edit
stops lining up. Every size this library produces is even.

## What it does not do

- **Colour and tone.** That is
  [VideoGrade](https://github.com/arraypress/swift-video-grade), a
  `CGImage → CGImage` engine that composes at the same Core Image seam.
- **Animated formats.** [ImageForge](https://github.com/arraypress/swift-image-forge)
  already writes GIF, APNG and animated HEIF with the per-frame delay handling
  they need. This library produces frames and hands them over.
- **Anything with a downloaded model behind it** — captions, censoring, text
  extraction, depth — which are their own tools. What is here uses what the
  OS ships: Vision's faces and people, SoundAnalysis's classifier.

## Requirements

macOS 26+ / iOS 26+, Swift 6.2 (Xcode 26). The tests read one committed
fixture, `Tests/VideoForgeTests/Resources/face.jpg` — a synthetic portrait —
and call `/usr/bin/say` for speech.

## License

MIT — see LICENSE.
