//
//  TrimSpec.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Which stretch of the timeline to keep. Times are seconds, because that
//  is what a person reads off a player; `CMTime` is an implementation
//  detail this type exists to keep out of a caller's way.
//

import AVFoundation
import Foundation

/// A stretch of a movie's timeline.
public struct TrimSpec: Sendable, Codable, Equatable, Hashable {
    /// Where to start, in seconds from the beginning.
    public var start: Double
    /// How long to keep, in seconds. Nil runs to the end.
    public var duration: Double?

    /// - Parameters:
    ///   - start: Seconds from the beginning. Negative is treated as zero.
    ///   - duration: Seconds to keep, or nil for everything after `start`.
    public init(start: Double = 0, duration: Double? = nil) {
        self.start = max(0, start)
        self.duration = duration.map { max(0, $0) }
    }

    /// From here to the end.
    public static func from(_ seconds: Double) -> TrimSpec {
        TrimSpec(start: seconds)
    }

    /// From the beginning up to here.
    public static func until(_ seconds: Double) -> TrimSpec {
        TrimSpec(start: 0, duration: seconds)
    }

    /// Between two points on the timeline.
    public static func between(_ start: Double, _ end: Double) -> TrimSpec {
        TrimSpec(start: start, duration: max(0, end - start))
    }

    /// The time range this describes within a movie of a given length.
    ///
    /// Clamped to what is actually there, so asking for ten seconds of a
    /// three-second clip gives three rather than an error — the intent is
    /// unambiguous and refusing it helps nobody.
    ///
    /// - Parameter total: The movie's own duration.
    /// - Returns: The range to keep.
    public func range(in total: CMTime) -> CMTimeRange {
        let scale: CMTimeScale = 600
        let begin = CMTime(seconds: min(start, total.seconds), preferredTimescale: scale)
        let remaining = CMTimeSubtract(total, begin)
        guard let duration else { return CMTimeRange(start: begin, duration: remaining) }
        let wanted = CMTime(seconds: duration, preferredTimescale: scale)
        return CMTimeRange(start: begin, duration: CMTimeMinimum(wanted, remaining))
    }

    /// A short phrase for a report.
    public var summary: String {
        guard let duration else { return String(format: "from %gs", start) }
        return String(format: "%gs for %gs", start, duration)
    }
}
