//
//  EditOverlay.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

/// Video shown over an edit's clips: a reaction cam, B-roll, a transparent
/// animation. Its transparency is kept.
public struct EditOverlay: Sendable, Equatable {
    /// The video file.
    public var file: URL
    /// When it appears on the edit, in seconds.
    public var start: Double
    /// When it goes; nil runs it for its own length, or to the edit's end.
    public var end: Double?
    /// Where in its file it starts playing, in seconds.
    public var from: Double
    /// The corner it sits in. ``PictureCorner/auto`` is not offered here:
    /// there is no single clip under it to look at for faces.
    public var corner: PictureCorner
    /// Its place as shares of the frame from the top left (x, y, width,
    /// height); beats the corner. The overlay is fitted inside it, centred.
    public var rect: CGRect?
    /// Its width as a share of the frame's, 0.05–1, for a corner.
    public var size: Double
    /// The gap to the frame's edges, as a share of its shorter side.
    public var margin: Double
    /// Corner rounding, as a share of the overlay's shorter side, 0–0.5.
    public var roundness: Double
    /// Cover the whole frame: a cut-away.
    public var fullFrame: Bool
    /// Seconds to fade in, and out again.
    public var fade: Double
    /// Its own sound's level, 0–2; 0, the default, mutes it.
    public var volume: Double

    /// An overlay.
    ///
    /// - Parameters:
    ///   - file: The video file.
    ///   - start: When it appears, in seconds on the edit.
    ///   - end: When it goes; nil for its own length.
    ///   - from: Where in its file it starts.
    ///   - corner: The corner it sits in.
    ///   - rect: Its place as shares of the frame; beats the corner.
    ///   - size: Its width as a share of the frame's, for a corner.
    ///   - margin: The gap to the edges.
    ///   - roundness: Corner rounding.
    ///   - fullFrame: Cover the whole frame.
    ///   - fade: Seconds to fade in and out.
    ///   - volume: Its own sound's level.
    public init(_ file: URL, start: Double, end: Double? = nil, from: Double = 0, corner: PictureCorner = .bottomRight,
                rect: CGRect? = nil, size: Double = 0.3, margin: Double = 0.04, roundness: Double = 0,
                fullFrame: Bool = false, fade: Double = 0, volume: Double = 0) {
        self.file = file
        self.start = start
        self.end = end
        self.from = from
        self.corner = corner
        self.rect = rect
        self.size = size
        self.margin = margin
        self.roundness = roundness
        self.fullFrame = fullFrame
        self.fade = fade
        self.volume = volume
    }
}
