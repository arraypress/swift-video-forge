//
//  ComposeResult.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

/// What an edit's render did.
public struct ComposeResult: Sendable {
    /// The written file, measured.
    public let result: VideoProcessResult
    /// Where each clip landed on the edit, in seconds.
    public let clips: [ClosedRange<Double>]
    /// The written frame.
    public let size: CGSize
    /// The music and effects pass, when there was one: the speech it ducked
    /// under, the levels, the measured loudness.
    public let soundtrack: SoundtrackResult?
}
