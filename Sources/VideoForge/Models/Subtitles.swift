//
//  Subtitles.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation
import SubtitleKit

/// One subtitle track to put into a movie: its cues and their language.
public struct Subtitles: Sendable, Equatable, Hashable {
    /// The cues, in any order; overlapping cues are shown stacked.
    public var cues: [SubtitleCue]
    /// The language — `en`, `eng`, `pt-BR`, `zh-Hant`. Written as both an
    /// ISO 639-2 code and, when it says more, a BCP 47 tag.
    public var language: String
    /// Whether players should show this track without being asked. At most
    /// one track in a movie can be.
    public var isDefault: Bool

    /// - Parameters:
    ///   - cues: The cues.
    ///   - language: The language they are in.
    ///   - isDefault: Whether it is on by default.
    public init(cues: [SubtitleCue], language: String, isDefault: Bool = false) {
        self.cues = cues
        self.language = language
        self.isDefault = isDefault
    }
}
