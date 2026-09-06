//
//  TrackInfo.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import AVFoundation
import CoreGraphics
import Foundation

/// One track inside a movie.
public struct TrackInfo: Sendable, Codable, Equatable, Hashable {
    /// What kind of track it is.
    public let kind: TrackKind
    /// The four-character code of the format inside it — `avc1`, `hvc1`,
    /// `aac `, `tx3g`.
    public let codec: String
    /// How long this track runs, in seconds.
    public let duration: Double
    /// Its estimated bitrate, in bits per second.
    public let bitRate: Double
    /// The frame size, for a video track. Nil otherwise.
    public let width: Int?
    /// The frame height, for a video track.
    public let height: Int?
    /// Frames per second, for a video track.
    public let frameRate: Double?
    /// Bits per component, for a video track. 10 means the source is worth
    /// keeping in HEVC rather than truncating to H.264.
    public let bitDepth: Int?
    /// Channels, for an audio track.
    public let channels: Int?
    /// Samples per second, for an audio track.
    public let sampleRate: Double?
    /// The track's language, when it declares one — the useful part of a
    /// subtitle track.
    public let language: String?

    /// - Parameters:
    ///   - kind: What kind of track it is.
    ///   - codec: The format's four-character code.
    ///   - duration: How long it runs, in seconds.
    ///   - bitRate: Estimated bits per second.
    ///   - width: Frame width, for video.
    ///   - height: Frame height, for video.
    ///   - frameRate: Frames per second, for video.
    ///   - bitDepth: Bits per component, for video.
    ///   - channels: Channel count, for audio.
    ///   - sampleRate: Samples per second, for audio.
    ///   - language: The declared language, if any.
    public init(kind: TrackKind, codec: String, duration: Double, bitRate: Double,
                width: Int? = nil, height: Int? = nil, frameRate: Double? = nil,
                bitDepth: Int? = nil, channels: Int? = nil, sampleRate: Double? = nil,
                language: String? = nil) {
        self.kind = kind
        self.codec = codec
        self.duration = duration
        self.bitRate = bitRate
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.sampleRate = sampleRate
        self.language = language
    }

    /// Whether this track carries more than 8 bits per component, and so
    /// must not be re-encoded as H.264.
    public var isDeep: Bool { (bitDepth ?? 8) >= 10 }

    /// The frame size, for a video track.
    public var size: CGSize? {
        guard let width, let height else { return nil }
        return CGSize(width: width, height: height)
    }
}
