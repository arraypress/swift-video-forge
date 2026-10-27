//
//  EditClip.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

/// One clip on an edit's main track. Clips play end to end.
public struct EditClip: Sendable, Equatable {
    /// The video file.
    public var file: URL
    /// Where in the file it starts, in seconds.
    public var from: Double
    /// Where it ends; nil for the file's end.
    public var to: Double?
    /// How it fills a frame of another shape.
    public var fit: EditFit
    /// The point kept in view when ``EditFit/fill`` crops, as shares of the
    /// clip's frame from the top left: (0.5, 0.5) is the centre.
    public var focus: CGPoint
    /// Its own sound's level, 0–2; 0 mutes it.
    public var volume: Double
    /// Seconds to fade up from black at its start.
    public var fadeIn: Double
    /// Seconds to fade down to black at its end.
    public var fadeOut: Double

    /// A clip.
    ///
    /// - Parameters:
    ///   - file: The video file.
    ///   - from: Where in the file it starts, in seconds.
    ///   - to: Where it ends; nil for the file's end.
    ///   - fit: How it fills a frame of another shape.
    ///   - focus: The point kept in view when fill crops, as shares from the top left.
    ///   - volume: Its own sound's level, 0–2.
    ///   - fadeIn: Seconds to fade up from black.
    ///   - fadeOut: Seconds to fade down to black.
    public init(_ file: URL, from: Double = 0, to: Double? = nil, fit: EditFit = .fill,
                focus: CGPoint = CGPoint(x: 0.5, y: 0.5), volume: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.file = file
        self.from = from
        self.to = to
        self.fit = fit
        self.focus = focus
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }
}
