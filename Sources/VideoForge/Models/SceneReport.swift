//
//  SceneReport.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// The shots of a video: where the picture changes, and the stretches in
/// between.
public struct SceneReport: Codable, Equatable, Sendable {
    /// The video's length, in seconds.
    public let duration: Double
    /// How many frames were read (every frame up to 30 a second).
    public let framesRead: Int
    /// Every change, in order.
    public let changes: [SceneChange]

    public init(duration: Double, framesRead: Int, changes: [SceneChange]) {
        self.duration = duration
        self.framesRead = framesRead
        self.changes = changes
    }

    /// The shots, start to end: one more than there are changes.
    public var scenes: [Range<Double>] { SceneCuts.scenes(changes, duration: duration) }
}
