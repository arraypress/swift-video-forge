//
//  WriterRules.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The rules that turn a source and a request into writer settings, as
//  pure functions over plain values, so each is pinned by a test with no
//  video in sight.
//
//  MEASURED on macOS 27 (M-series), through AVAssetWriter:
//
//  · H.264 and HEVC honour `AVVideoAverageBitRateKey` and `AVVideoQualityKey`;
//    HEVC with alpha honours both too. ProRes refuses both — `canApply`
//    says no to a compression dictionary holding either — so a bitrate or a
//    quality with ProRes is refused before anything is written.
//  · The bitrate is a VBR target: 2–8 Mb/s on 12 s of 1080p30 came back
//    within 1–4 %; at 1 Mb/s HEVC floored near 1.9 Mb/s, and above what the
//    picture needs the encoder spends less than asked.
//  · Pixel format matters for ProRes and only for ProRes. A 10-bit ramp of
//    256 levels, redrawn by the Core Image compositor and written as ProRes
//    4444, kept 95–101 levels from ANY RGB format (BGRA, 64-bit half float,
//    16-bit ARGB, 4444 Y'CbCrA 16) — that is the 4444 redraw bug — and
//    254–264 from 10-bit Y'CbCr (`x420`, `x422`, `x444`). HEVC kept every
//    level from every format tried. So ProRes is fed 10-bit Y'CbCr; only
//    an alpha channel, which no 10-bit Y'CbCr format carries, falls back
//    to 16-bit Y'CbCrA.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The writer-settings rules.
enum WriterRules {

    /// Bits per second below which no derived rate goes.
    static let minimumBitRate = 1_000_000
    /// Bits per pixel per frame for the resolution floor.
    static let floorBitsPerPixel = 0.05

    /// Derives the writer's settings.
    ///
    /// Rules, each load-bearing:
    /// - The codec is the caller's, already resolved (see ``CodecPlan``).
    /// - HEVC from footage of more than 8 bits is HEVC Main 10.
    /// - A bitrate asked for is the bitrate written. A quality asked for (and
    ///   no bitrate) goes to the encoder as a quality. Otherwise the source's
    ///   own rate — scaled down with the picture when it shrinks — or a
    ///   resolution floor, whichever is higher: matching quality needs
    ///   matching budget. ProRes takes neither; it decides its own.
    /// - Colour tags are copied only as a complete set.
    ///
    /// - Parameters:
    ///   - source: The source track.
    ///   - codec: The concrete codec to write.
    ///   - bitRate: Bits per second asked for, if any.
    ///   - quality: Quality 0…1 asked for, if any.
    ///   - frameRate: The frame rate written, if it changes.
    ///   - size: The written frame size, if it differs from the source's.
    ///   - keepsAlpha: Whether frames carry an alpha channel to the writer.
    ///   - processesInRGB: Whether the caller works on frames in RGB (Vision,
    ///     drawing) rather than handing them straight to an encoder.
    /// - Returns: The settings.
    static func derive(from source: VideoSourceFormat, codec: VideoCodec,
                       bitRate: Int?, quality: Double?, frameRate: Double?,
                       size: CGSize?, keepsAlpha: Bool, processesInRGB: Bool) -> WriterSettings {
        let deep = (source.bitsPerComponent ?? 8) >= 10
        let width = Int((size?.width ?? CGFloat(source.width)) / 2) * 2
        let height = Int((size?.height ?? CGFloat(source.height)) / 2) * 2
        let sourceFPS = source.frameRate > 0 ? source.frameRate : 0
        let fps = frameRate ?? (sourceFPS > 0 ? sourceFPS : 30)

        var rate: Int?
        var asked: Double?
        if !codec.isIntraFrame {
            if let bitRate {
                rate = bitRate
            } else if let quality {
                asked = min(1, max(0, quality))
            } else {
                rate = parityBitRate(source: source, width: width, height: height, fps: fps,
                                     resized: size != nil)
            }
        }

        let complete = source.colorPrimaries != nil && source.transferFunction != nil
            && source.yCbCrMatrix != nil
        let expected = frameRate ?? (sourceFPS > 0 ? sourceFPS : nil)
        return WriterSettings(
            codec: codec, width: width, height: height,
            profileLevel: codec == .hevc && deep ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : nil,
            averageBitRate: rate, quality: asked,
            expectedFrameRate: expected.map { Int($0.rounded()) },
            colorPrimaries: complete ? source.colorPrimaries : nil,
            transferFunction: complete ? source.transferFunction : nil,
            yCbCrMatrix: complete ? source.yCbCrMatrix : nil,
            pixelFormat: pixelFormat(codec: codec, deep: deep, keepsAlpha: keepsAlpha,
                                     processesInRGB: processesInRGB))
    }

    /// The source's rate — scaled with the picture when a resize shrinks
    /// it — never below a resolution floor or ``minimumBitRate``.
    static func parityBitRate(source: VideoSourceFormat, width: Int, height: Int, fps: Double,
                              resized: Bool) -> Int {
        let sourcePixels = Double(max(1, source.width * source.height))
        let pixels = Double(width * height)
        let scaled = resized ? source.dataRate * min(1, pixels / sourcePixels) : source.dataRate
        let floor = pixels * fps * floorBitsPerPixel
        return Int(max(scaled, max(floor, Double(minimumBitRate))))
    }

    /// The pixel format frames reach the writer in. See the measurements at
    /// the top of this file.
    static func pixelFormat(codec: VideoCodec, deep: Bool, keepsAlpha: Bool,
                            processesInRGB: Bool) -> OSType {
        if processesInRGB {
            return deep ? kCVPixelFormatType_ARGB2101010LEPacked : kCVPixelFormatType_32BGRA
        }
        switch codec {
        case .hevcAlpha:
            return kCVPixelFormatType_32BGRA
        case .proRes4444:
            return keepsAlpha ? kCVPixelFormatType_4444AYpCbCr16 : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        case .proRes422:
            return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .hevc where deep:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        default:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    /// The `AVAssetWriterInput` output settings the settings describe.
    ///
    /// ProRes gets no compression dictionary at all: it refuses a bitrate
    /// and a quality, and has nothing else worth saying.
    static func outputSettings(_ settings: WriterSettings) -> [String: Any] {
        var output: [String: Any] = [
            AVVideoCodecKey: settings.codec.codecType ?? .h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
        ]
        if !settings.codec.isIntraFrame {
            var compression: [String: Any] = [:]
            if let rate = settings.averageBitRate { compression[AVVideoAverageBitRateKey] = rate }
            if let quality = settings.quality { compression[AVVideoQualityKey] = quality }
            // Under the compression properties, not at the top level, where
            // it throws an Objective-C exception.
            if let profile = settings.profileLevel { compression[AVVideoProfileLevelKey] = profile }
            if let fps = settings.expectedFrameRate { compression[AVVideoExpectedSourceFrameRateKey] = fps }
            if !compression.isEmpty { output[AVVideoCompressionPropertiesKey] = compression }
        }
        if let primaries = settings.colorPrimaries, let transfer = settings.transferFunction,
           let matrix = settings.yCbCrMatrix {
            output[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix,
            ]
        }
        return output
    }

    /// The pixel-buffer attributes frames are made or read in.
    static func pixelBufferAttributes(_ settings: WriterSettings) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: settings.pixelFormat,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
        ]
    }

    /// One frame's duration at a rate, exactly where it can be: whole rates
    /// as 1/n, the NTSC rates (29.97, 59.94, 23.976) as 1001/n000, anything
    /// else to a 600 000 timescale.
    ///
    /// - Parameter fps: Frames per second; above 0.
    /// - Returns: The frame duration.
    static func frameDuration(fps: Double) -> CMTime {
        let whole = fps.rounded()
        if abs(fps - whole) < 0.0005 { return CMTime(value: 1, timescale: CMTimeScale(whole)) }
        let ntsc = (fps * 1.001).rounded()
        if abs(fps * 1.001 - ntsc) < 0.001 { return CMTime(value: 1001, timescale: CMTimeScale(ntsc * 1000)) }
        return CMTime(value: CMTimeValue((600_000 / fps).rounded()), timescale: 600_000)
    }
}
