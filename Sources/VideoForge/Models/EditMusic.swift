//
//  EditMusic.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// An edit's music bed, ducked under the speech — the clips' and the voice-over's.
public struct EditMusic: Sendable, Equatable {
    /// The music file.
    public var file: URL
    /// How it sits under the speech.
    public var bed: MusicBed

    /// A music bed.
    ///
    /// - Parameters:
    ///   - file: The music file.
    ///   - bed: How it sits under the speech.
    public init(_ file: URL, bed: MusicBed = MusicBed()) {
        self.file = file
        self.bed = bed
    }
}
