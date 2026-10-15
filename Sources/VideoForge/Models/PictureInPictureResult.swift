//
//  PictureInPictureResult.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What a picture-in-picture job did.
public struct PictureInPictureResult: Sendable, Codable, Equatable {
    /// The job, as every other job reports it.
    public let result: VideoProcessResult
    /// Where the overlay went and why.
    public let placement: OverlayPlacement

    /// - Parameters:
    ///   - result: The job's result.
    ///   - placement: Where the overlay went.
    public init(result: VideoProcessResult, placement: OverlayPlacement) {
        self.result = result
        self.placement = placement
    }
}
