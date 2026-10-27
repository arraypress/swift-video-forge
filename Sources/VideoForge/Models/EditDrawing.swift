//
//  EditDrawing.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

/// Something drawn over an edit's picture between two times: a full-frame
/// image with transparency, asked for at every frame it shows on. A closure,
/// so titles and captions can come from any library.
public struct EditDrawing: Sendable {
    /// When it appears, in seconds on the edit.
    public var start: Double
    /// When it goes.
    public var end: Double
    /// The picture at a time on the edit, as big as the frame it is given;
    /// nil draws nothing at that frame. Called from the compositor's
    /// threads, possibly at once — guard any state it keeps.
    public var draw: @Sendable (_ time: Double, _ frame: CGSize) -> CGImage?

    /// A drawing.
    ///
    /// - Parameters:
    ///   - start: When it appears, in seconds on the edit.
    ///   - end: When it goes.
    ///   - draw: The picture at a time, for a frame of a size.
    public init(start: Double, end: Double, draw: @escaping @Sendable (_ time: Double, _ frame: CGSize) -> CGImage?) {
        self.start = start
        self.end = end
        self.draw = draw
    }
}
