//
//  SubtitleTrack.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation
import SubtitleKit

/// A subtitle or closed-caption track read out of a movie.
public struct SubtitleTrack: Sendable, Codable, Equatable, Hashable {
    /// The track's ID inside the file.
    public let trackID: Int
    /// The declared language — the BCP 47 tag when there is one, else the
    /// ISO 639-2 code; nil when undetermined.
    public let language: String?
    /// The format's four-character code: `tx3g`, `wvtt`, `c608`, `text`.
    public let codec: String
    /// Whether it is closed captions (CEA-608) rather than subtitles.
    public let isClosedCaption: Bool
    /// Whether players show it without being asked.
    public let isEnabled: Bool
    /// Whether this library can read its text. False for a format it does
    /// not know, whose cues are then empty.
    public let isReadable: Bool
    /// The cues, in order.
    public let cues: [SubtitleCue]

    /// - Parameters:
    ///   - trackID: The track's ID.
    ///   - language: The declared language.
    ///   - codec: The format's code.
    ///   - isClosedCaption: Whether it is CEA-608.
    ///   - isEnabled: Whether it shows by default.
    ///   - isReadable: Whether its text could be read.
    ///   - cues: The cues.
    public init(trackID: Int, language: String?, codec: String, isClosedCaption: Bool,
                isEnabled: Bool, isReadable: Bool, cues: [SubtitleCue]) {
        self.trackID = trackID
        self.language = language
        self.codec = codec
        self.isClosedCaption = isClosedCaption
        self.isEnabled = isEnabled
        self.isReadable = isReadable
        self.cues = cues
    }
}
