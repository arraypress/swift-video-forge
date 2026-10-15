//
//  SpeechDetection.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  MEASURED (0.7.0) on six `say` sentences, four voices, gaps of 0.8–3 s,
//  scored every 10 ms against where each sentence was placed — over
//  digital silence, room noise at −45 dBFS, noise at −32 dBFS, music at
//  −30 dBFS, and claps and chord swells in the gaps:
//
//    detection    F1 (worst–best)   edges        claps and chords
//    energy       0.872–0.998       8–43 ms      ducked (precision 0.77)
//    classifier   0.975–0.986       47–83 ms     ignored
//    both         0.987–0.998       8–42 ms      ignored (precision 0.98)
//
//  The classifier's own 3 s window scored 0.81–0.83 (its windows blur a
//  sentence's edges by a second); 0.5 s windows every 0.125 s are what it
//  runs at here. `both` is the default.
//

import Foundation

/// How a music bed finds speech to duck under.
public enum SpeechDetection: String, CaseIterable, Sendable, Codable, Hashable {
    /// Loudness over the speech band against the room's quiet: exact edges,
    /// but any loud sound counts.
    case energy
    /// Apple's on-device sound classifier: knows a voice from a door, but
    /// its windows blur the edges.
    case classifier
    /// Energy stretches the classifier agrees are speech.
    case both
}
