//
//  ExportSpec.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  How the movie is written. The defaults all say "like the source", which
//  is the only setting that cannot quietly make somebody's footage worse.
//

import Foundation

/// How a movie is written out.
public struct ExportSpec: Sendable, Codable, Equatable, Hashable {
    /// The container to write. Nil keeps the source's.
    public var container: VideoContainer?
    /// The codec to write. `.source` re-uses the source's, which is the
    /// only choice that cannot lose depth.
    public var codec: VideoCodec
    /// Bits per second for the video. Nil derives it from the source, never
    /// below what the source itself used.
    public var bitRate: Int?
    /// An encoder quality from 0 to 1, for H.264 and HEVC. Nil leaves the
    /// rate to ``bitRate`` or to the source; ignored when ``bitRate`` is set.
    /// ProRes takes neither and refuses both.
    public var quality: Double?
    /// Frames per second. Nil keeps the source's. Frames are dropped or
    /// repeated to meet it; the duration and the sound are unchanged.
    public var frameRate: Double?
    /// Whether to keep the audio.
    public var keepsAudio: Bool
    /// Whether to carry subtitle and timed-metadata tracks through. On by
    /// default: an iPhone clip's metadata track is worth keeping, and a
    /// subtitle track thrown away silently is a bug report.
    public var keepsSidecarTracks: Bool
    /// Prefer rearranging time over redrawing frames wherever the
    /// operations allow it. On by default, because a passthrough trim is
    /// both instant and lossless.
    public var prefersPassthrough: Bool

    /// - Parameters:
    ///   - container: The container to write, or nil to keep the source's.
    ///   - codec: The codec to write.
    ///   - bitRate: Bits per second, or nil to derive from the source.
    ///   - quality: An encoder quality from 0 to 1, or nil.
    ///   - frameRate: Frames per second, or nil to keep the source's.
    ///   - keepsAudio: Whether to keep the sound.
    ///   - keepsSidecarTracks: Whether to carry subtitles and metadata through.
    ///   - prefersPassthrough: Whether to avoid re-encoding where possible.
    public init(container: VideoContainer? = nil,
                codec: VideoCodec = .source,
                bitRate: Int? = nil,
                quality: Double? = nil,
                frameRate: Double? = nil,
                keepsAudio: Bool = true,
                keepsSidecarTracks: Bool = true,
                prefersPassthrough: Bool = true) {
        self.container = container
        self.codec = codec
        self.bitRate = bitRate
        self.quality = quality.map { min(1, max(0, $0)) }
        self.frameRate = frameRate
        self.keepsAudio = keepsAudio
        self.keepsSidecarTracks = keepsSidecarTracks
        self.prefersPassthrough = prefersPassthrough
    }

    /// Whether this asks for something only an encoder can be told — a
    /// bitrate, a quality or a frame rate — which no export preset takes.
    public var asksForEncoding: Bool { bitRate != nil || quality != nil || frameRate != nil }

    /// Write this container, keeping everything else.
    public static func container(_ container: VideoContainer) -> ExportSpec {
        ExportSpec(container: container)
    }

    /// Aim for a bitrate.
    public static func bitRate(_ bitsPerSecond: Int) -> ExportSpec {
        ExportSpec(bitRate: bitsPerSecond)
    }

    /// Drop the sound.
    public static let mute = ExportSpec(keepsAudio: false)
}
