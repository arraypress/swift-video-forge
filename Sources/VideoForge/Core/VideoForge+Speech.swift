//
//  VideoForge+Speech.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

extension VideoForge {

    /// The stretches of a clip where somebody is talking, in seconds.
    ///
    /// - Parameters:
    ///   - url: The clip, or a sound file.
    ///   - detection: How speech is found; see ``SpeechDetection``.
    /// - Returns: The stretches, in order.
    /// - Throws: ``VideoForgeError/noAudioTrack(_:)`` when it is silent.
    public static func speech(in url: URL, detection: SpeechDetection = .both) async throws -> [ClosedRange<Double>] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw VideoForgeError.fileNotFound(url) }
        return try await SpeechScan.run(url, classifies: detection != .energy).speech(detection)
    }
}
