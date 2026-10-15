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
  road puts every subtitle track, old and new, in one writer input group.
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
- **Anything with a model behind it** — captions, censoring, text extraction —
  which are their own tools.

## Requirements

macOS 26+ / iOS 26+, Swift 6.2 (Xcode 26).

## License

MIT — see LICENSE.
