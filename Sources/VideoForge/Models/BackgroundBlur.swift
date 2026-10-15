//
//  BackgroundBlur.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A portrait-style blur behind the people in a frame, on-device: Vision's
//  person segmentation finds them, and everything else is blurred. No depth
//  model is needed, so nothing is downloaded.
//

import Foundation

/// How the background behind people is blurred.
public struct BackgroundBlur: Sendable, Codable, Equatable, Hashable {
    /// How strong the blur is, 0–1: 1 is a radius of 4% of the frame's
    /// height (43 px at 1080p).
    public var amount: Double
    /// How carefully people are found: `fast`, `balanced` (the video
    /// default) or `accurate`.
    public var quality: SegmentationQuality

    /// - Parameters:
    ///   - amount: The blur's strength, 0–1.
    ///   - quality: How carefully people are found.
    public init(amount: Double = 0.5, quality: SegmentationQuality = .balanced) {
        self.amount = amount
        self.quality = quality
    }
}
