//
//  SoundCue.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// A one-shot sound effect at a moment of a clip.
public struct SoundCue: Sendable, Codable, Equatable, Hashable {
    /// The sound file (or a movie, for its sound).
    public var file: URL
    /// When it starts, in seconds on the clip.
    public var time: Double
    /// This cue's own adjustment, in dB, on top of ``SoundEffects/gain``.
    public var gain: Double

    /// - Parameters:
    ///   - file: The sound.
    ///   - time: When it starts, in seconds.
    ///   - gain: Its own adjustment, in dB.
    public init(file: URL, time: Double, gain: Double = 0) {
        self.file = file
        self.time = time
        self.gain = gain
    }
}
