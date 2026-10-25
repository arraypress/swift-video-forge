//
//  SoundLevels.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  How loud a clip's sound is, step by step — the whole band, not the
//  speech band SpeechScan listens to, so music and room tone count.
//

import Foundation

/// Measures loudness over time.
public enum SoundLevels {

    /// The RMS level of every `step` seconds of `url`'s first sound track,
    /// mixed to one channel.
    ///
    /// - Parameters:
    ///   - url: A movie or a sound file.
    ///   - step: Seconds per value.
    /// - Throws: ``VideoForgeError/noAudioTrack(_:)``,
    ///   ``VideoForgeError/unreadable(_:reason:)``.
    public static func measure(_ url: URL, step: Double = 0.05) async throws -> LevelSeries {
        let stream = try await PCMStream(url, rate: 16_000, channels: 1)
        let length = max(1, Int((stream.sampleRate * step).rounded()))
        var levels: [Double] = []
        var sum = 0.0
        var count = 0
        while let chunk = stream.next() {
            for sample in chunk {
                sum += Double(sample * sample)
                count += 1
                if count == length {
                    levels.append(SoundRules.dbfs(sumOfSquares: sum, count: count))
                    sum = 0
                    count = 0
                }
            }
        }
        if stream.failed { throw VideoForgeError.unreadable(url, reason: "its sound stopped decoding partway") }
        if count > length / 2 { levels.append(SoundRules.dbfs(sumOfSquares: sum, count: count)) }
        return LevelSeries(step: Double(length) / stream.sampleRate, dbfs: levels)
    }
}
