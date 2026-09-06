//
//  TrackKind.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import AVFoundation
import Foundation

/// A kind of track inside a movie.
public enum TrackKind: String, CaseIterable, Sendable, Codable, Hashable {
    /// The pictures.
    case video
    /// The sound.
    case audio
    /// Subtitles and closed captions — anything meant to be read.
    case subtitle
    /// Timed metadata. An iPhone clip carries orientation and more here,
    /// which is why it is passed through rather than dropped.
    case metadata

    /// The AVFoundation media type this names.
    public var mediaType: AVMediaType {
        switch self {
        case .video: return .video
        case .audio: return .audio
        case .subtitle: return .subtitle
        case .metadata: return .metadata
        }
    }

    /// The kind an AVFoundation media type names, if it is one of these.
    public static func of(_ mediaType: AVMediaType) -> TrackKind? {
        allCases.first { $0.mediaType == mediaType }
    }
}
