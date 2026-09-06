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

/// One step of a video pipeline.
public enum VideoOperation: Sendable, Codable, Equatable, Hashable {
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
        case .reverse, .resize, .crop, .aspect, .rotate, .flip: return false
        }
    }

    /// Whether the frame's dimensions change, so the writer has to be told
    /// a different size from the source's.
    public var changesGeometry: Bool {
        switch self {
        case .resize, .crop, .aspect, .rotate: return true
        case .trim, .speed, .reverse, .flip, .remove: return false
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
        }
    }
}
