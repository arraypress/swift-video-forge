//
//  SoundtrackResult.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What laying music and sound effects into a clip did, measured.
public struct SoundtrackResult: Sendable, Codable, Equatable {
    /// The job, as every other job reports it.
    public let result: VideoProcessResult
    /// Where somebody was found talking, in seconds.
    public let speech: [ClosedRange<Double>]
    /// The music bed, when there was one.
    public let music: MusicResult?
    /// Each sound effect, as mixed.
    public let sounds: [PlacedSound]
    /// The gain on the whole mix to keep its peak under the ceiling, in dB.
    public let mixGain: Double
    /// The written sound's integrated loudness, LUFS, measured by decoding
    /// the file.
    public let loudness: Double?
    /// The written sound's true peak, dBTP, measured by decoding the file.
    public let truePeak: Double

    /// - Parameters:
    ///   - result: The job's result.
    ///   - speech: Where speech was found.
    ///   - music: The music bed's report.
    ///   - sounds: Each effect as mixed.
    ///   - mixGain: The gain on the whole mix.
    ///   - loudness: The written loudness.
    ///   - truePeak: The written true peak.
    public init(result: VideoProcessResult, speech: [ClosedRange<Double>], music: MusicResult?,
                sounds: [PlacedSound], mixGain: Double, loudness: Double?, truePeak: Double) {
        self.result = result
        self.speech = speech
        self.music = music
        self.sounds = sounds
        self.mixGain = mixGain
        self.loudness = loudness
        self.truePeak = truePeak
    }
}
