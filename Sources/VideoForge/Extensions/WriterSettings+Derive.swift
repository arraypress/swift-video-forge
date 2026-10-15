//
//  WriterSettings+Derive.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The doors onto ``WriterRules``: deriving settings, and the dictionaries
//  AVFoundation takes them as.
//

import CoreGraphics
import Foundation

public extension WriterSettings {

    /// Derives the writer's settings from the source and what was asked.
    ///
    /// With nothing asked, the result matches the source: its colour tags,
    /// its frame rate, and a bitrate never below its own — HEVC Main 10 when
    /// the source is deep and the codec is HEVC.
    ///
    /// - Parameters:
    ///   - source: The source track's format.
    ///   - codec: The concrete codec to write — never ``VideoCodec/source``.
    ///   - bitRate: Bits per second asked for, if any. Wins over a quality.
    ///   - quality: Encoder quality 0…1, if asked.
    ///   - frameRate: The frame rate written, if it changes.
    ///   - size: The written frame size, if it differs from the source's.
    ///   - keepsAlpha: Whether frames carry an alpha channel to the writer.
    ///   - processesInRGB: Whether the caller works on frames in RGB — the
    ///     frames are then 32-bit BGRA, or 10-bit ARGB for deep footage.
    /// - Returns: The settings.
    static func derive(from source: VideoSourceFormat, codec: VideoCodec,
                       bitRate: Int? = nil, quality: Double? = nil, frameRate: Double? = nil,
                       size: CGSize? = nil, keepsAlpha: Bool = false,
                       processesInRGB: Bool = false) -> WriterSettings {
        WriterRules.derive(from: source, codec: codec, bitRate: bitRate, quality: quality,
                           frameRate: frameRate, size: size, keepsAlpha: keepsAlpha,
                           processesInRGB: processesInRGB)
    }

    /// The settings as `AVAssetWriterInput` output settings.
    var videoOutputSettings: [String: Any] { WriterRules.outputSettings(self) }

    /// The pixel-buffer attributes frames are read and made in.
    var pixelBufferAttributes: [String: Any] { WriterRules.pixelBufferAttributes(self) }
}
