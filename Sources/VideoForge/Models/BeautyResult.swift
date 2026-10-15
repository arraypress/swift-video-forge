//
//  BeautyResult.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What a beauty pass did.
public struct BeautyResult: Sendable, Codable, Equatable {
    /// The job, as every other job reports it.
    public let result: VideoProcessResult
    /// How many samples of the clip — four a second — a face was tracked
    /// in for the retouch.
    public let faceSamples: Int

    /// - Parameters:
    ///   - result: The job's result.
    ///   - faceSamples: Samples a face was tracked in.
    public init(result: VideoProcessResult, faceSamples: Int) {
        self.result = result
        self.faceSamples = faceSamples
    }
}
