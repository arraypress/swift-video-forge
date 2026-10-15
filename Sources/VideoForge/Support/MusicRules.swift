//
//  MusicRules.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// The music bed's settings rules.
enum MusicRules {

    /// What is wrong with a music bed's settings, if anything.
    static func problem(with bed: MusicBed) -> String? {
        if !(-60...20).contains(bed.level) { return "the music's level is −60 to 20 LU against the speech" }
        if !(0...60).contains(bed.duck) { return "the duck is 0 to 60 dB" }
        if !(0...5).contains(bed.attack) { return "the attack is 0 to 5 seconds" }
        if !(0...10).contains(bed.release) { return "the release is 0 to 10 seconds" }
        if !(bed.fadeIn >= 0) || !(bed.fadeOut >= 0) { return "a fade cannot be negative" }
        if !(bed.start >= 0) { return "the music's start cannot be negative" }
        return nil
    }
}
