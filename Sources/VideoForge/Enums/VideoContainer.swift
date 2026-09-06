//
//  VideoContainer.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import AVFoundation
import Foundation

/// The file a movie is written into.
public enum VideoContainer: String, CaseIterable, Sendable, Codable, Hashable {
    /// QuickTime. Holds anything AVFoundation writes, including ProRes.
    case mov
    /// MPEG-4. The one to hand to somebody else.
    case mp4
    /// Apple's MPEG-4 flavour, for video.
    case m4v
    /// Audio only, AAC in MPEG-4.
    case m4a
    /// Audio only, uncompressed.
    case wav
    /// Audio only, Apple's uncompressed container.
    case caf
    /// Audio only, AIFF.
    case aiff

    /// The AVFoundation file type.
    public var fileType: AVFileType {
        switch self {
        case .mov: return .mov
        case .mp4: return .mp4
        case .m4v: return .m4v
        case .m4a: return .m4a
        case .wav: return .wav
        case .caf: return .caf
        case .aiff: return .aiff
        }
    }

    /// The extension to give the file, without the dot.
    public var fileExtension: String { rawValue }

    /// Whether this container holds pictures at all.
    public var holdsVideo: Bool {
        switch self {
        case .mov, .mp4, .m4v: return true
        case .m4a, .wav, .caf, .aiff: return false
        }
    }

    /// Whether this container can hold a subtitle track.
    ///
    /// QuickTime and MPEG-4 both can; the audio-only containers cannot.
    public var holdsSubtitles: Bool { holdsVideo }

    /// The container a file extension names.
    public static func named(fileExtension: String) -> VideoContainer? {
        let ext = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch ext {
        case "qt": return .mov
        case "aif", "aiff", "aifc": return .aiff
        default: return allCases.first { $0.rawValue == ext }
        }
    }
}
