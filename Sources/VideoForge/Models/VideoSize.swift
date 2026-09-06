//
//  VideoSize.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A target frame size. Encoders care about even numbers in a way nothing
//  else does — H.264 and HEVC both work in macroblocks, and an odd width
//  is either refused or quietly rounded — so every size this produces is
//  even.
//

import CoreGraphics
import Foundation

/// How big the frame should be.
public struct VideoSize: Sendable, Codable, Equatable, Hashable {
    /// The target box's width in pixels.
    public var width: Int
    /// The target box's height in pixels.
    public var height: Int
    /// Fit inside the box rather than filling it. Filling crops the
    /// overflow from the centre.
    public var fits: Bool
    /// Whether a smaller frame may be enlarged to reach the box.
    public var allowsUpscaling: Bool

    /// - Parameters:
    ///   - width: Target width in pixels.
    ///   - height: Target height in pixels.
    ///   - fits: Fit inside the box; false fills and crops.
    ///   - allowsUpscaling: Whether the frame may be enlarged.
    public init(width: Int, height: Int, fits: Bool = true, allowsUpscaling: Bool = false) {
        self.width = max(2, width)
        self.height = max(2, height)
        self.fits = fits
        self.allowsUpscaling = allowsUpscaling
    }

    /// No side longer than this.
    public static func longestSide(_ pixels: Int) -> VideoSize {
        VideoSize(width: pixels, height: pixels, fits: true)
    }

    /// The common delivery heights, as boxes wide enough for any aspect.
    public static func height(_ pixels: Int) -> VideoSize {
        VideoSize(width: pixels * 4, height: pixels, fits: true)
    }

    /// Cover this box exactly, cropping the overflow — what a vertical
    /// reel or a square post needs.
    public static func fill(width: Int, height: Int) -> VideoSize {
        VideoSize(width: width, height: height, fits: false, allowsUpscaling: true)
    }

    /// The size a source ends up at.
    ///
    /// - Parameter source: The frame's current size.
    /// - Returns: The size to write, both sides even.
    public func resolved(from source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 2, height: 2) }
        let box = CGSize(width: CGFloat(width), height: CGFloat(height))
        let byWidth = box.width / source.width
        let byHeight = box.height / source.height
        var scale = fits ? min(byWidth, byHeight) : max(byWidth, byHeight)
        if !allowsUpscaling { scale = min(scale, 1) }

        if fits {
            return Self.even(CGSize(width: source.width * scale, height: source.height * scale))
        }
        // Filling means the box itself, with the overflow cropped away.
        return Self.even(box)
    }

    /// Rounds a size to even numbers, never below two.
    ///
    /// Encoders work in macroblocks; an odd dimension is refused by some
    /// and silently rounded by others, and a run that is silently rounded
    /// produces footage a frame-accurate edit will not line up with.
    public static func even(_ size: CGSize) -> CGSize {
        func round(_ value: CGFloat) -> CGFloat {
            max(2, (value / 2).rounded() * 2)
        }
        return CGSize(width: round(size.width), height: round(size.height))
    }

    /// A short phrase for a report.
    public var summary: String { "\(width)×\(height)\(fits ? "" : " fill")" }
}
