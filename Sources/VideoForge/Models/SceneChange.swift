//
//  SceneChange.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// A place where the picture changes to another shot.
public struct SceneChange: Codable, Equatable, Sendable {

    /// How the picture changed.
    public enum Kind: String, Codable, Sendable {
        /// From one frame to the next.
        case cut
        /// Over about a second, one picture fading through the other. The
        /// time is the middle of the dissolve.
        case dissolve
    }

    /// When the new shot starts, in seconds: the first frame of it for a
    /// cut, the middle of the fade for a dissolve.
    public let time: Double
    public let kind: Kind
    /// How different the two pictures are, 0–1: the colour-histogram
    /// distance across a cut, the image fingerprint distance across a
    /// dissolve.
    public let strength: Double

    public init(time: Double, kind: Kind, strength: Double) {
        self.time = time
        self.kind = kind
        self.strength = strength
    }
}
