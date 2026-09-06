//
//  VideoFlip.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// The axis the frame is mirrored across.
public enum VideoFlip: String, CaseIterable, Sendable, Codable, Hashable {
    /// Left becomes right.
    case horizontal
    /// Top becomes bottom.
    case vertical
}
