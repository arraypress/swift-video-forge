//
//  VideoOperation.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The vocabulary, split by which road an operation has to take.
//
//  Some things can be done by rearranging TIME — trimming, joining,
//  changing speed, dropping a track. Those go through an
//  `AVMutableComposition` and never decode a frame, so they are fast and
//  they do not touch quality.
//
//  Everything else has to redraw every frame — cropping, scaling, turning,
//  grading — and that means a reader, a writer, and the whole quality-parity
//  problem of not turning somebody's 10-bit HDR footage into washed-out
//  8-bit SDR on the way through.
//

import CoreGraphics
import Foundation
import VideoGrade

/// One step of a video pipeline.
public enum VideoOperation: Sendable, Codable, Equatable {
    /// Keep a stretch of the timeline.
    case trim(TrimSpec)
    /// Play faster or slower. 2 is twice as fast, 0.5 is half.
    case speed(Double)
    /// Play the whole thing backwards.
    case reverse
    /// Scale the frame.
    case resize(VideoSize)
    /// Keep part of the frame, in pixels from the top left.
    case crop(x: Int, y: Int, width: Int, height: Int)
    /// Keep the largest rectangle of this shape, from the centre.
    case aspect(width: Int, height: Int)
    /// Turn the frame clockwise by a quarter, half or three-quarter turn.
    case rotate(VideoRotation)
    /// Mirror the frame.
    case flip(VideoFlip)
    /// Drop a track entirely — the usual reason being to mute a clip.
    case remove(TrackKind)
    /// Apply colour and tone: exposure, contrast, curves, a LUT, a film
    /// look — the whole of
    /// [VideoGrade](https://github.com/arraypress/swift-video-grade), which
    /// this library calls rather than reimplements.
    ///
    /// The same `VideoGrade` value that `img grade` applies to a still, so a
    /// shoot's stills and its footage match by construction. Unlike a still,
    /// the animated parts of a look — grain, light leaks, film damage — are
    /// given the frame's own time, so they move rather than sitting still.
    case grade(VideoGrade)
    /// Soften the skin of the faces in frame and retouch the largest one:
    /// see ``Beauty``. Its landmarks are tracked from the clip by
    /// ``VideoForge/process(_:to:options:)``.
    case beauty(Beauty)
    /// Blur what is behind the people in frame: see ``BackgroundBlur``.
    case blurBackground(BackgroundBlur)

    /// Whether this step can be done by rearranging time alone, leaving
    /// every frame exactly as it was.
    ///
    /// The distinction is not cosmetic: a trim of a two-hour recording is a
    /// second of work on the composition road and twenty minutes of
    /// re-encoding on the other one, and the re-encode is also the only
    /// version that loses quality.
    public var isTimeOnly: Bool {
        switch self {
        case .trim, .speed, .remove: return true
        case .reverse, .resize, .crop, .aspect, .rotate, .flip, .grade, .beauty, .blurBackground: return false
        }
    }

    /// Whether the frame's dimensions change, so the writer has to be told
    /// a different size from the source's.
    public var changesGeometry: Bool {
        switch self {
        case .resize, .crop, .aspect, .rotate: return true
        case .trim, .speed, .reverse, .flip, .remove, .grade, .beauty, .blurBackground: return false
        }
    }

    /// A short phrase naming this step, for a log or a report.
    public var summary: String {
        switch self {
        case .trim(let spec): return "trim \(spec.summary)"
        case .speed(let rate): return String(format: "speed %gx", rate)
        case .reverse: return "reverse"
        case .resize(let size): return "resize \(size.summary)"
        case .crop(let x, let y, let w, let h): return "crop \(w)×\(h) at \(x),\(y)"
        case .aspect(let w, let h): return "crop to \(w):\(h)"
        case .rotate(let turn): return "rotate \(turn.rawValue)°"
        case .flip(let axis): return "flip \(axis.rawValue)"
        case .remove(let kind): return "remove \(kind.rawValue)"
        case .grade(let grade):
            return grade.lutURL.map { "grade with \($0.lastPathComponent)" } ?? "grade"
        case .beauty(let beauty): return String(format: "smooth skin %g", beauty.smoothing)
            + (beauty.retouches ? ", retouch" : "")
        case .blurBackground(let blur): return String(format: "blur the background %g", blur.amount)
        }
    }
}
