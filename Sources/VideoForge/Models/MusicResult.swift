//
//  MusicResult.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What laying music under a clip did, measured.
public struct MusicResult: Sendable, Codable, Equatable {
    /// The job, as every other job reports it.
    public let result: VideoProcessResult
    /// Where somebody was found talking, in seconds.
    public let speech: [ClosedRange<Double>]
    /// What the level was set against, in LUFS: the speech's loudness, the
    /// clip's, or −16.
    public let reference: Double
    /// The music file's own loudness, in LUFS.
    public let musicLoudness: Double
    /// The gain put on the music to sit it at its level, in dB.
    public let musicGain: Double
    /// The gain on the music while somebody talks, in dB, averaged over
    /// the samples mixed away from every ramp and fade. Nil when nobody did.
    public let musicUnderSpeech: Double?
    /// The same between sentences — the two differ by the duck. Nil when
    /// there was no such stretch.
    public let musicBetween: Double?
    /// The gain put on the whole mix to keep its peak under the ceiling,
    /// in dB — 0, or below.
    public let mixGain: Double
    /// The written sound's integrated loudness, in LUFS, measured by
    /// decoding the file.
    public let loudness: Double?
    /// The written sound's true peak, in dBTP, measured by decoding the file.
    public let truePeak: Double

    /// - Parameters:
    ///   - result: The job's result.
    ///   - speech: Where speech was found.
    ///   - reference: What the level was set against.
    ///   - musicLoudness: The music's own loudness.
    ///   - musicGain: The gain on the music.
    ///   - musicUnderSpeech: The gain on the music under speech.
    ///   - musicBetween: The gain between.
    ///   - mixGain: The gain on the whole mix.
    ///   - loudness: The written loudness.
    ///   - truePeak: The written true peak.
    public init(result: VideoProcessResult, speech: [ClosedRange<Double>], reference: Double,
                musicLoudness: Double, musicGain: Double, musicUnderSpeech: Double?, musicBetween: Double?,
                mixGain: Double, loudness: Double?, truePeak: Double) {
        self.result = result
        self.speech = speech
        self.reference = reference
        self.musicLoudness = musicLoudness
        self.musicGain = musicGain
        self.musicUnderSpeech = musicUnderSpeech
        self.musicBetween = musicBetween
        self.mixGain = mixGain
        self.loudness = loudness
        self.truePeak = truePeak
    }
}
