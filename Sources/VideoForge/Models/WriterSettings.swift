//
//  WriterSettings.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  What a video writer is told, derived from what the source is and what
//  was asked for. The shape only; the rules live in ``WriterRules`` and
//  are reached through ``WriterSettings/derive(from:codec:bitRate:quality:frameRate:size:keepsAlpha:processesInRGB:)``.
//
//  Moved here from swift-censor-kit (2.3.1), which derived the same story
//  for its redraw-and-write road: the defaults it replaced (H.264, 8-bit,
//  a writer-chosen bitrate, no colour tags) turned iPhone HDR into
//  washed-out SDR at a fraction of the source rate. One copy, for both.
//

import CoreVideo
import Foundation

/// The derived video-writer configuration.
public struct WriterSettings: Sendable, Equatable, Hashable {
    /// The concrete codec to write — never ``VideoCodec/source``.
    public var codec: VideoCodec
    /// The encoded frame width: even, as encoders require.
    public var width: Int
    /// The encoded frame height: even.
    public var height: Int
    /// HEVC Main 10 for deep footage written as HEVC; nil lets the encoder
    /// choose.
    public var profileLevel: String?
    /// The average bitrate asked of the encoder; nil for ProRes, which
    /// decides its own, and when a quality is asked for instead.
    public var averageBitRate: Int?
    /// The encoder quality, 0…1, when one was asked for and no bitrate was.
    public var quality: Double?
    /// The frame rate the encoder should expect, rounded.
    public var expectedFrameRate: Int?
    /// Copied from the source as a complete set or not at all — the writer
    /// rejects a partial colour-properties dictionary.
    public var colorPrimaries: String?
    /// The transfer function tag.
    public var transferFunction: String?
    /// The Y'CbCr matrix tag.
    public var yCbCrMatrix: String?
    /// The pixel format frames are handed to the writer in.
    public var pixelFormat: OSType

    /// - Parameters: Every field, as described on the properties.
    public init(codec: VideoCodec, width: Int, height: Int, profileLevel: String? = nil,
                averageBitRate: Int? = nil, quality: Double? = nil, expectedFrameRate: Int? = nil,
                colorPrimaries: String? = nil, transferFunction: String? = nil,
                yCbCrMatrix: String? = nil, pixelFormat: OSType) {
        self.codec = codec
        self.width = width
        self.height = height
        self.profileLevel = profileLevel
        self.averageBitRate = averageBitRate
        self.quality = quality
        self.expectedFrameRate = expectedFrameRate
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.pixelFormat = pixelFormat
    }

    /// Whether all three colour tags survive to the writer.
    public var hasColorProperties: Bool {
        colorPrimaries != nil && transferFunction != nil && yCbCrMatrix != nil
    }
}
