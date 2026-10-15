//
//  ClipPlacement.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import CoreMedia
import Foundation

/// Where one clip of a join sits in the joined timeline, and how it is
/// stored — so it can be turned upright on its own rather than with the
/// first clip's turn.
public struct ClipPlacement: Sendable, Equatable {
    /// The clip's stretch of the joined timeline.
    public var range: CMTimeRange
    /// The clip's own `preferredTransform`: how its stored frames are
    /// turned to be shown. A phone's portrait clip is stored sideways with
    /// a quarter turn here.
    public var transform: CGAffineTransform

    public init(range: CMTimeRange, transform: CGAffineTransform) {
        self.range = range
        self.transform = transform
    }
}
