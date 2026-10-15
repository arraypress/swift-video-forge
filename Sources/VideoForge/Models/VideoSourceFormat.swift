//
//  VideoSourceFormat.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  What a source video track is, as plain values — everything a writer
//  needs to be told so it does not quietly make the footage worse. Plain
//  values so the rules that read it (``WriterSettings``) are pure functions
//  a test can pin with no video in sight.
//

import Foundation

/// A source video track's format, as plain values.
public struct VideoSourceFormat: Sendable, Equatable, Hashable {
    /// The four-character code: `avc1`, `hvc1`, `apcn`, `ap4h`.
    public var codec: String
    /// The stored frame width.
    public var width: Int
    /// The stored frame height.
    public var height: Int
    /// The track's estimated bitrate, in bits per second; 0 when unknown.
    public var dataRate: Double
    /// The track's nominal frame rate; 0 when unknown.
    public var frameRate: Double
    /// `BitsPerComponent` from the format description — present (10) on
    /// 10-bit footage, absent on 8-bit. `Depth` is NOT this: it reads 24
    /// for 8-bit H.264 and 10-bit HEVC alike.
    public var bitsPerComponent: Int?
    /// The colour primaries tag, when the source carries one.
    public var colorPrimaries: String?
    /// The transfer function tag.
    public var transferFunction: String?
    /// The Y'CbCr matrix tag.
    public var yCbCrMatrix: String?
    /// Whether the track carries an alpha channel — HEVC with alpha, or
    /// ProRes 4444 with one.
    public var hasAlpha: Bool

    /// - Parameters:
    ///   - codec: The four-character code.
    ///   - width: Stored frame width.
    ///   - height: Stored frame height.
    ///   - dataRate: Estimated bits per second, 0 when unknown.
    ///   - frameRate: Nominal frames per second, 0 when unknown.
    ///   - bitsPerComponent: Declared bits per component, if any.
    ///   - colorPrimaries: The primaries tag, if any.
    ///   - transferFunction: The transfer function tag, if any.
    ///   - yCbCrMatrix: The matrix tag, if any.
    ///   - hasAlpha: Whether there is an alpha channel.
    public init(codec: String, width: Int, height: Int,
                dataRate: Double = 0, frameRate: Double = 0,
                bitsPerComponent: Int? = nil,
                colorPrimaries: String? = nil, transferFunction: String? = nil,
                yCbCrMatrix: String? = nil, hasAlpha: Bool = false) {
        self.codec = codec
        self.width = width
        self.height = height
        self.dataRate = dataRate
        self.frameRate = frameRate
        self.bitsPerComponent = bitsPerComponent
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.hasAlpha = hasAlpha
    }
}
