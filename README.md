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

## Two roads

Which one a job takes is the most consequential thing about it, so
``VideoProcessResult/passedThrough`` says which one ran.

- **Composition** — trimming, joining, changing speed, dropping a track are
  rearrangements of *time*. An `AVMutableComposition` points at the source's
  samples rather than reading them, so a trim of a two-hour recording is a
  second of work and loses nothing.
- **Render** — cropping, scaling, turning and mirroring have to redraw every
  frame. Built on `AVMutableVideoComposition` with a Core Image handler
  rather than a hand-rolled reader and writer, so audio, subtitle and timed
  metadata tracks come along untouched and the interleave deadlock cannot be
  reintroduced by accident.

A job that needs both gets both, with the time work first — so the render road
only ever sees the frames that survived the trim.

A third, narrow road adds tracks: **copy** reads every sample of every track
and writes it back unchanged beside the new ones. It exists for subtitles,
because the composition road cannot make a subtitle a player will offer.

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
| speed 2× / 0.5× / 4× with AAC stereo | **0.0% off** at every factor |
| GIF, 2s at 10fps, 400px | 0.36–1.71s |
| reverse a whole 4K clip | refused: 16.8 GB against a 2 GB budget |

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
