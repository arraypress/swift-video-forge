//
//  ComposeInstruction.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import AVFoundation
import Foundation

/// One stretch of the edit: which clip is on screen and which overlays.
final class ComposeInstruction: NSObject, AVVideoCompositionInstructionProtocol, Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let plan: ComposePlan
    /// The clip on screen, by index into the plan's clips.
    let clip: Int?
    /// The overlays on screen anywhere in this stretch.
    let overlays: [Int]

    init(timeRange: CMTimeRange, plan: ComposePlan, clip: Int?, overlays: [Int]) {
        self.timeRange = timeRange
        self.plan = plan
        self.clip = clip
        self.overlays = overlays
    }

    var requiredSourceTrackIDs: [NSValue]? {
        ((clip == nil ? [] : [plan.mainTrack]) + overlays.map { plan.overlays[$0].track }).map { NSNumber(value: $0) }
    }
}
