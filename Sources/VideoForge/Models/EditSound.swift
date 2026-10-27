//
//  EditSound.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Sound laid onto an edit at a time — a voice-over. The music ducks under it.
public struct EditSound: Sendable, Equatable {
    /// The sound file, or a movie with sound.
    public var file: URL
    /// When it starts, in seconds on the edit.
    public var start: Double
    /// Where in the file it starts.
    public var from: Double
    /// Where in the file it ends; nil for the file's end.
    public var to: Double?
    /// Its level, 0–2.
    public var volume: Double

    /// A sound.
    ///
    /// - Parameters:
    ///   - file: The sound file.
    ///   - start: When it starts on the edit.
    ///   - from: Where in the file it starts.
    ///   - to: Where in the file it ends; nil for its end.
    ///   - volume: Its level, 0–2.
    public init(_ file: URL, start: Double, from: Double = 0, to: Double? = nil, volume: Double = 1) {
        self.file = file
        self.start = start
        self.from = from
        self.to = to
        self.volume = volume
    }
}
