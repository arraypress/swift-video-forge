//
//  TestClips+Frames.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Clips drawn by a closure, and every frame of a clip read back as RGB —
//  so a picture-in-picture can be measured rather than looked at: where
//  the output differs from the clip underneath is where the overlay is.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
@testable import VideoForge

/// One decoded frame: its time, size and BGRA bytes, top row first.
struct DecodedFrame {
    let time: Double
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// The pixel at `x`, `y` from the top left, as RGB.
    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * width + x) * 4
        return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
    }

    /// As an image, for Vision.
    var image: CGImage? {
        let data = CFDataCreate(nil, bytes, bytes.count)!
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension TestClips {

    /// A clip whose frame `index` is whatever `draw` paints — in a context
    /// counting from the BOTTOM, as Core Graphics does.
    static func writeDrawn(to url: URL, seconds: Double = 2, fps: Int = 30, width: Int = 640, height: Int = 360,
                           draw: @escaping @Sendable (CGContext, Int) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.95],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let total = Int(Double(fps) * seconds)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var frame = 0
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "test.drawn")) {
                while input.isReadyForMoreMediaData {
                    guard frame < total else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard let pool = adaptor.pixelBufferPool else { continue }
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let pixels = buffer else { continue }
                    CVPixelBufferLockBaseAddress(pixels, [])
                    if let context = CGContext(
                        data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                        draw(context, frame)
                    }
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                    frame += 1
                }
            }
        }
        await writer.finishWriting()
    }

    /// A drawn clip with a tone under it, as one movie.
    static func writeDrawnMovie(to url: URL, seconds: Double = 2, fps: Int = 30, width: Int = 640, height: Int = 360,
                                hz: Double = 440, draw: @escaping @Sendable (CGContext, Int) -> Void) async throws {
        let silent = url.deletingPathExtension().appendingPathExtension("picture.mov")
        let tone = url.deletingPathExtension().appendingPathExtension("tone.caf")
        try await writeDrawn(to: silent, seconds: seconds, fps: fps, width: width, height: height, draw: draw)
        try writeAudio(to: tone, seconds: seconds, hz: hz)
        let composition = AVMutableComposition()
        for (asset, type) in [(AVURLAsset(url: silent), AVMediaType.video), (AVURLAsset(url: tone), AVMediaType.audio)] {
            guard let source = try await asset.loadTracks(withMediaType: type).first,
                  let track = composition.addMutableTrack(withMediaType: type,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)),
                                      of: source, at: .zero)
        }
        try? FileManager.default.removeItem(at: url)
        try await Composer.export(composition, to: url, container: .mov, preset: AVAssetExportPresetPassthrough)
        try? FileManager.default.removeItem(at: silent)
        try? FileManager.default.removeItem(at: tone)
    }

    /// The face image the picture-in-picture tests look for: a synthetic
    /// portrait made by `imagine --fast` (SANA Sprint, seed 2128462539),
    /// 256 px — nobody's likeness. Vision finds its face at 0.83.
    static func face() throws -> CGImage {
        guard let url = Bundle.module.url(forResource: "face", withExtension: "jpg", subdirectory: "Resources"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return image
    }

    /// Every frame of a clip, shown upright, as BGRA.
    static func decodedFrames(of url: URL) async throws -> [DecodedFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
        var frames: [DecodedFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                for row in 0..<height {
                    bytes.withUnsafeMutableBytes { target in
                        target.baseAddress!.advanced(by: row * width * 4)
                            .copyMemory(from: base.advanced(by: row * stride), byteCount: width * 4)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            frames.append(DecodedFrame(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                                       width: width, height: height, bytes: bytes))
        }
        return frames.sorted { $0.time < $1.time }
    }

    /// The smallest rectangle, from the top left, holding every pixel
    /// where two frames differ by more than `threshold` in any channel —
    /// nil when none do.
    static func differingRect(_ a: DecodedFrame, _ b: DecodedFrame, threshold: Int = 48) -> CGRect? {
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
        for y in 0..<min(a.height, b.height) {
            for x in 0..<min(a.width, b.width) {
                let p = a.rgb(x, y), q = b.rgb(x, y)
                if max(abs(p.r - q.r), abs(p.g - q.g), abs(p.b - q.b)) > threshold {
                    (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
