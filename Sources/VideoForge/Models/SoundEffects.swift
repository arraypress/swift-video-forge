//
//  SoundEffects.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  How one-shot sound effects sit in a clip. Like the music bed, every cue
//  is levelled against the speech around it, measured — not given a fixed
//  gain — so a whoosh lands the same distance under a quiet talker as under
//  a loud one.
//

import Foundation

/// How sound effects are levelled.
public struct SoundEffects: Sendable, Codable, Equatable, Hashable {
    /// How far under the speech around it each cue sits, in LU: its loudest
    /// 400 ms against the speech within 3 s of it. A clip with no speech
    /// there is measured by its sound there; one with none, against −16 LUFS.
    public var underSpeech: Double
    /// An adjustment for every cue, in dB.
    public var gain: Double
    /// How speech is found.
    public var detection: SpeechDetection

    /// - Parameters:
    ///   - underSpeech: How far under the speech each cue sits, in LU.
    ///   - gain: An adjustment for every cue, in dB.
    ///   - detection: How speech is found.
    public init(underSpeech: Double = 6, gain: Double = 0, detection: SpeechDetection = .both) {
        self.underSpeech = underSpeech
        self.gain = gain
        self.detection = detection
    }
}
