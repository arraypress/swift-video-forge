//
//  LevelSeries.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// How loud a sound is over time: the RMS level of each step, in dBFS.
public struct LevelSeries: Codable, Equatable, Sendable {
    /// Seconds per value.
    public let step: Double
    /// Each step's RMS level in dBFS, from 0 (full scale) down to
    /// ``LevelSeries/floor`` for digital silence.
    public let dbfs: [Double]

    /// The lowest level a step can have: digital silence reads as this
    /// rather than minus infinity, which JSON cannot carry.
    public static let floor = -120.0

    public init(step: Double, dbfs: [Double]) {
        self.step = step
        self.dbfs = dbfs
    }

    /// The sound's length, in seconds.
    public var duration: Double { Double(dbfs.count) * step }

    /// The stretches quieter than `threshold` for at least `minimum`
    /// seconds — silence from the sound itself, whether or not anybody is
    /// talking.
    ///
    /// - Parameters:
    ///   - threshold: dBFS. -45 is quiet room tone; music or a fan under a
    ///     pause keeps it from counting.
    ///   - minimum: The shortest stretch to report, in seconds.
    public func silences(below threshold: Double = -45, atLeast minimum: Double = 0.5) -> [Range<Double>] {
        SoundRules.quiet(dbfs, step: step, below: threshold, atLeast: minimum)
    }
}
