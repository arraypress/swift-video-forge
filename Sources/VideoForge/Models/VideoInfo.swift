//
//  VideoInfo.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  What a movie is, read from its container without decoding a frame.
//

import AVFoundation
import CoreGraphics
import Foundation

/// What a movie file contains.
public struct VideoInfo: Sendable, Codable, Equatable, Hashable {
    /// How long it runs, in seconds.
    public let duration: Double
    /// The frame's width, with the track's orientation applied — the
    /// number a person watching it would give.
    public let width: Int
    /// The frame's height, orientation applied.
    public let height: Int
    /// Frames per second.
    public let frameRate: Double
    /// The container it is written in, when it is one this library names.
    public let container: VideoContainer?
    /// The size of the file on disk, in bytes.
    public let byteCount: Int
    /// Every track inside.
    public let tracks: [TrackInfo]
    /// Whether the video track is rotated by its transform — an iPhone clip
    /// held upright is stored on its side with a transform saying so.
    public let isRotated: Bool

    /// - Parameters:
    ///   - duration: How long it runs, in seconds.
    ///   - width: Frame width, orientation applied.
    ///   - height: Frame height, orientation applied.
    ///   - frameRate: Frames per second.
    ///   - container: The container, if named.
    ///   - byteCount: File size in bytes.
    ///   - tracks: Every track inside.
    ///   - isRotated: Whether a transform turns the frame.
    public init(duration: Double, width: Int, height: Int, frameRate: Double,
                container: VideoContainer?, byteCount: Int, tracks: [TrackInfo],
                isRotated: Bool) {
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.container = container
        self.byteCount = byteCount
        self.tracks = tracks
        self.isRotated = isRotated
    }

    /// The video track, if there is one.
    public var video: TrackInfo? { tracks.first { $0.kind == .video } }
    /// The audio track, if there is one.
    public var audio: TrackInfo? { tracks.first { $0.kind == .audio } }
    /// Every subtitle track.
    public var subtitles: [TrackInfo] { tracks.filter { $0.kind == .subtitle } }

    /// Whether there is any sound.
    public var hasAudio: Bool { audio != nil }
    /// Whether there are any pictures.
    public var hasVideo: Bool { video != nil }
    /// Whether the video is stored with more than 8 bits per component, so
    /// "the source's codec" means a deep one.
    public var isDeep: Bool { video?.isDeep ?? false }
    /// Whether the footage itself is deeper than 8 bits, so an 8-bit codec
    /// is refused. ProRes's declared depth is its own, not the footage's.
    public var forbidsEightBit: Bool { video?.forbidsEightBit ?? false }
    /// Whether the video carries an alpha channel.
    public var hasAlpha: Bool { video?.hasAlpha ?? false }

    /// The frame's size.
    public var size: CGSize { CGSize(width: width, height: height) }
    /// Width over height.
    public var aspectRatio: Double { height == 0 ? 0 : Double(width) / Double(height) }
    /// Roughly how many frames there are.
    public var frameCount: Int { Int((duration * frameRate).rounded()) }
    /// The whole file's bitrate, in bits per second.
    public var bitRate: Double { duration == 0 ? 0 : Double(byteCount) * 8 / duration }
}
