//
//  VideoProcessResult.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  What happened, including which road it took — because the difference
//  between rearranging time and redrawing every frame is the difference
//  between a second and twenty minutes, and between lossless and not.
//

import Foundation

/// The outcome of one video job.
public struct VideoProcessResult: Sendable, Codable, Equatable, Hashable {
    /// Where the movie came from.
    public let source: URL
    /// Where it was written.
    public let destination: URL
    /// What the source was.
    public let before: VideoInfo
    /// What the output is.
    public let after: VideoInfo
    /// Whether the frames were left untouched — the composition road.
    public let passedThrough: Bool
    /// The operations applied, in order.
    public let operations: [VideoOperation]
    /// How long the job took, in seconds.
    public let seconds: Double

    /// - Parameters:
    ///   - source: Where the movie came from.
    ///   - destination: Where it was written.
    ///   - before: What the source was.
    ///   - after: What the output is.
    ///   - passedThrough: Whether the frames were left untouched.
    ///   - operations: The operations applied.
    ///   - seconds: How long the job took.
    public init(source: URL, destination: URL, before: VideoInfo, after: VideoInfo,
                passedThrough: Bool, operations: [VideoOperation], seconds: Double) {
        self.source = source
        self.destination = destination
        self.before = before
        self.after = after
        self.passedThrough = passedThrough
        self.operations = operations
        self.seconds = seconds
    }

    /// Bytes saved. Negative when the output grew.
    public var bytesSaved: Int { before.byteCount - after.byteCount }

    /// The share of the original size saved, from 0 to 1.
    public var savingsRatio: Double {
        before.byteCount == 0 ? 0 : Double(bytesSaved) / Double(before.byteCount)
    }

    /// How many times faster than real time the job ran.
    public var speed: Double { seconds == 0 ? 0 : before.duration / seconds }

    /// Whether a track the source had is missing from the output.
    ///
    /// Worth checking rather than trusting: dropping the audio, or a
    /// subtitle track, is the kind of loss nobody notices until later.
    public var lostTracks: [TrackKind] {
        let kept = Set(after.tracks.map(\.kind))
        return Array(Set(before.tracks.map(\.kind)).subtracting(kept)).sorted { $0.rawValue < $1.rawValue }
    }
}
