//
//  MusicBed.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Music under a clip's own sound, ducked while somebody talks. Every
//  default is meant to be right without anybody listening: the level is
//  set against the clip's measured speech, not as a fixed gain, so a
//  loudly mastered song and a quiet one sit the same distance under the
//  voice.
//

import Foundation

/// How music is laid under a clip.
///
/// ```swift
/// // The defaults: 12 LU under the voice, 10 dB further under while it talks.
/// let bed = MusicBed()
/// // Louder between sentences, looped to the clip's length.
/// let busy = MusicBed(level: -8, duck: 14, loops: true)
/// ```
public struct MusicBed: Sendable, Codable, Equatable, Hashable {
    /// The music's loudness between sentences, in LU against the clip's
    /// speech: −12 sits it twelve under the voice. A clip with no voice is
    /// measured by its own loudness; one with no sound kept, against
    /// −16 LUFS — so −12 writes the music at −28 LUFS, and 0 at −16.
    public var level: Double
    /// How far the music drops while somebody talks, in dB.
    public var duck: Double
    /// How long the music takes to drop, in seconds — it finishes dropping
    /// as the speech starts, not after.
    public var attack: Double
    /// How long it takes to come back up after the speech, in seconds.
    public var release: Double
    /// Repeat music shorter than the clip, each join crossfaded.
    public var loops: Bool
    /// Seconds to fade the music in from where it starts.
    public var fadeIn: Double
    /// Seconds to fade it out before it ends.
    public var fadeOut: Double
    /// When the music comes in, in seconds on the clip.
    public var start: Double
    /// Keep the clip's own sound under the music. Off replaces it, and
    /// there is nothing to duck under.
    public var keepsClipAudio: Bool
    /// How speech is found.
    public var detection: SpeechDetection

    /// - Parameters:
    ///   - level: The music's loudness between sentences, in LU against the speech.
    ///   - duck: How far it drops under speech, in dB.
    ///   - attack: Seconds to drop.
    ///   - release: Seconds to come back up.
    ///   - loops: Repeat it to the clip's length.
    ///   - fadeIn: Seconds to fade in.
    ///   - fadeOut: Seconds to fade out.
    ///   - start: When it comes in, in seconds.
    ///   - keepsClipAudio: Keep the clip's own sound.
    ///   - detection: How speech is found.
    public init(level: Double = -12, duck: Double = 10, attack: Double = 0.15, release: Double = 0.5,
                loops: Bool = false, fadeIn: Double = 1, fadeOut: Double = 2, start: Double = 0,
                keepsClipAudio: Bool = true, detection: SpeechDetection = .both) {
        self.level = level
        self.duck = duck
        self.attack = attack
        self.release = release
        self.loops = loops
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.start = start
        self.keepsClipAudio = keepsClipAudio
        self.detection = detection
    }
}
