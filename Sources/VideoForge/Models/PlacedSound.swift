//
//  PlacedSound.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One sound effect as it was mixed in, measured.
public struct PlacedSound: Sendable, Codable, Equatable {
    /// The sound file.
    public let file: URL
    /// When it starts, in seconds.
    public let time: Double
    /// How long it plays, in seconds — cut at the clip's end.
    public let seconds: Double
    /// What it was levelled against, in LUFS: the speech within 3 s of it,
    /// the clip's sound there, or −16.
    public let reference: Double
    /// Its loudest 400 ms in the written mix, in LUFS, measured on its
    /// samples at the gain they were mixed with — the mix's own gain
    /// included.
    public let level: Double
    /// The gain put on it, in dB.
    public let gain: Double

    /// - Parameters:
    ///   - file: The sound file.
    ///   - time: When it starts.
    ///   - seconds: How long it plays.
    ///   - reference: What it was levelled against.
    ///   - level: Its loudest 400 ms as mixed.
    ///   - gain: The gain put on it.
    public init(file: URL, time: Double, seconds: Double, reference: Double, level: Double, gain: Double) {
        self.file = file
        self.time = time
        self.seconds = seconds
        self.reference = reference
        self.level = level
        self.gain = gain
    }
}
