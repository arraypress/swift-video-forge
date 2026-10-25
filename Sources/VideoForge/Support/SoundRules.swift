//
//  SoundRules.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Sound levels and the quiet stretches in them, as pure functions.
//

import Foundation

enum SoundRules {

    /// The RMS level of `count` samples whose squares sum to `sumOfSquares`,
    /// in dBFS, no lower than ``LevelSeries/floor``.
    static func dbfs(sumOfSquares: Double, count: Int) -> Double {
        guard count > 0, sumOfSquares > 0 else { return LevelSeries.floor }
        return max(LevelSeries.floor, 10 * log10(sumOfSquares / Double(count)))
    }

    /// Runs of steps below `threshold` lasting at least `minimum` seconds.
    static func quiet(_ levels: [Double], step: Double, below threshold: Double, atLeast minimum: Double) -> [Range<Double>] {
        var runs: [Range<Double>] = []
        var start: Int?
        for index in 0...levels.count {
            let isQuiet = index < levels.count && levels[index] < threshold
            if isQuiet, start == nil { start = index }
            if !isQuiet, let first = start {
                let range = (Double(first) * step)..<(Double(index) * step)
                if range.upperBound - range.lowerBound >= minimum - 1e-9 { runs.append(range) }
                start = nil
            }
        }
        return runs
    }
}
