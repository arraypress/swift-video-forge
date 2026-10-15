//
//  OverlayPlacement.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

/// Where an overlay was put, and what was seen to decide it.
public struct OverlayPlacement: Sendable, Codable, Equatable, Hashable {
    /// The corner it sits in; nil when it covers the frame.
    public let corner: PictureCorner?
    /// Its rectangle in the written frame, in pixels from the top left.
    public let rect: CGRect
    /// When it appears and goes, in seconds on the written timeline.
    public let start: Double
    /// When it goes.
    public let end: Double
    /// How many frames under the overlay were looked at for faces — 0 when
    /// the corner was given rather than found.
    public let framesScanned: Int
    /// How many faces were seen across those frames.
    public let facesSeen: Int
    /// The largest share of any seen face the overlay covers, 0–1. 0 means
    /// it covers none of them.
    public let faceCoverage: Double

    /// - Parameters:
    ///   - corner: The corner, or nil for the whole frame.
    ///   - rect: The rectangle, in pixels from the top left.
    ///   - start: When it appears.
    ///   - end: When it goes.
    ///   - framesScanned: Frames looked at for faces.
    ///   - facesSeen: Faces seen across them.
    ///   - faceCoverage: The largest share of a face it covers.
    public init(corner: PictureCorner?, rect: CGRect, start: Double, end: Double,
                framesScanned: Int, facesSeen: Int, faceCoverage: Double) {
        self.corner = corner
        self.rect = rect
        self.start = start
        self.end = end
        self.framesScanned = framesScanned
        self.facesSeen = facesSeen
        self.faceCoverage = faceCoverage
    }
}
