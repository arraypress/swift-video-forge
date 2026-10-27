//
//  ComposePlan.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import CoreMedia
import Foundation

/// What every frame of an edit needs, worked out once.
struct ComposePlan: Sendable {

    /// One clip on the main track.
    struct Clip: Sendable {
        let range: ClosedRange<Double>
        let transform: CGAffineTransform
        /// Where its upright picture goes, from the top left.
        let rect: CGRect
        let fit: EditFit
        let fadeIn: Double
        let fadeOut: Double
    }

    /// One overlay on its own track.
    struct Overlay: Sendable {
        let track: CMPersistentTrackID
        let transform: CGAffineTransform
        let window: ClosedRange<Double>
        let rect: CGRect
        let radius: CGFloat
        let fade: Double
    }

    let mainTrack: CMPersistentTrackID
    let clips: [Clip]
    let overlays: [Overlay]
    let drawings: [EditDrawing]
    let frame: CGSize
    let frameDuration: Double
    let primaries: String
    let transfer: String
    let matrix: String
}
