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

macOS 15+ / iOS 18+ / tvOS 18+ / visionOS 2+, Swift 6.

## License

MIT — see LICENSE.
