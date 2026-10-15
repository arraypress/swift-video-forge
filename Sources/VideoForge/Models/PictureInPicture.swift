//
//  PictureInPicture.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A second clip shown over the first: a reaction cam in a corner, or a
//  cut-away of B-roll covering the whole frame. Every default is meant to
//  be right without anybody looking — the corner is found by looking for
//  faces, not picked.
//

import Foundation

/// How one clip is shown over another.
///
/// ```swift
/// // A reaction cam in whichever corner keeps clear of faces, from 2 s.
/// let pip = PictureInPicture(start: 2)
/// // B-roll over the whole frame from 4 to 7 s, faded in and out.
/// let cutaway = PictureInPicture(start: 4, end: 7, fullFrame: true, fade: 0.3)
/// ```
public struct PictureInPicture: Sendable, Codable, Equatable, Hashable {
    /// When the overlay appears on the main clip's timeline, in seconds.
    public var start: Double
    /// When it goes. Nil runs the overlay to its own end, or the main
    /// clip's, whichever is first; an end past the overlay's own length is
    /// cut to it.
    public var end: Double?
    /// The corner it sits in; ``PictureCorner/auto`` finds the one that
    /// covers no face. Ignored by ``fullFrame``.
    public var corner: PictureCorner
    /// Its width as a share of the frame's, 0.05–1. Shrunk, keeping its
    /// shape, when a tall overlay would not fit the frame's height.
    public var size: Double
    /// The gap to the frame's edges, as a share of the frame's shorter side.
    public var margin: Double
    /// Corner rounding, as a share of the overlay's shorter side, 0–0.5:
    /// 0.5 makes a square overlay a circle.
    public var roundness: Double
    /// Cover the whole frame — a cut-away — scaled to fill and cropped from
    /// the centre, rather than sit in a corner.
    public var fullFrame: Bool
    /// Seconds to fade in, and out again. 0 cuts.
    public var fade: Double
    /// How loud the overlay's own sound plays under the main clip's, 0–1.
    /// 0, the default, mutes it — B-roll is usually silent.
    public var mix: Double

    /// - Parameters:
    ///   - start: When it appears, in seconds.
    ///   - end: When it goes; nil for the overlay's own end.
    ///   - corner: Where it sits.
    ///   - size: Its width as a share of the frame's.
    ///   - margin: The gap to the edges, as a share of the shorter side.
    ///   - roundness: Corner rounding, as a share of its shorter side.
    ///   - fullFrame: Cover the whole frame instead.
    ///   - fade: Seconds to fade in and out.
    ///   - mix: Its sound's level under the main clip's, 0–1.
    public init(start: Double = 0, end: Double? = nil, corner: PictureCorner = .auto,
                size: Double = 0.3, margin: Double = 0.04, roundness: Double = 0,
                fullFrame: Bool = false, fade: Double = 0, mix: Double = 0) {
        self.start = start
        self.end = end
        self.corner = corner
        self.size = size
        self.margin = margin
        self.roundness = roundness
        self.fullFrame = fullFrame
        self.fade = fade
        self.mix = mix
    }
}
