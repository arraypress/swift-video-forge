//
//  SoundEffects+Checks.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension SoundEffects {

    /// What is wrong with these settings, as a phrase — nil when nothing is.
    var problem: String? { CueRules.problem(with: self) }
}
