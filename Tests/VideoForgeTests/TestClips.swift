//
//  TestClips.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Synthetic clips whose every frame is identifiable, so a trim can be
//  checked rather than assumed. Nothing here reads a committed fixture: a
//  test that depends on a .mov somebody added in 2019 fails for reasons
//  that have nothing to do with the code.
//
//  The writer feeds through `requestMediaDataWhenReady` even though there
//  is only one input. Feeding a writer from a busy-wait loop is what
//  deadlocks it once there are two — and a test helper that models the
//  wrong shape teaches the wrong shape.
//

import AVFoundation
import CoreGraphics
import Foundation
@testable import VideoForge

enum TestClips {

    /// A clip with a bar marching left to right, so the position of the bar
    /// says which frame you are looking at.
    ///
    /// - Parameters:
    ///   - url: Where to write it.
    ///   - seconds: How long.
    ///   - fps: Frames per second.
    ///   - width: Frame width. Even, as encoders require.
    ///   - height: Frame height.
    ///   - hue: The bar's colour, so two clips can be told apart when joined.
    static func writeVideo(to url: URL, seconds: Double = 2, fps: Int = 30,
                           width: Int = 320, height: Int = 240,
                           hue: CGFloat = 0.05) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let total = Int(Double(fps) * seconds)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var frame = 0
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "test.write")) {
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
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue) {
                        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
                        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                        let x = CGFloat(frame) / CGFloat(max(1, total)) * CGFloat(width - 40)
                        context.setFillColor(CGColor(red: 1, green: hue, blue: 0, alpha: 1))
                        context.fill(CGRect(x: x, y: CGFloat(height) / 3,
                                            width: 40, height: CGFloat(height) / 3))
                    }
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    adaptor.append(pixels, withPresentationTime:
                        CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                    frame += 1
                }
            }
        }
        await writer.finishWriting()
    }

    /// A tone, written through `AVAudioFile` so there is nothing to
    /// interleave and nothing to deadlock.
    static func writeAudio(to url: URL, seconds: Double = 2, hz: Double = 440) throws {
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else {
            return
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44100 * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData?[0][index] = Float(sin(Double(index) * 2 * .pi * hz / 44100) * 0.3)
        }
        try file.write(from: buffer)
    }

    /// A clip with both picture and sound, built by composing two
    /// single-track files rather than feeding one writer two inputs.
    @discardableResult
    static func writeMovie(to url: URL, seconds: Double = 2, fps: Int = 30,
                           width: Int = 320, height: Int = 240,
                           hue: CGFloat = 0.05, hz: Double = 440) async throws -> URL {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let silent = folder.appendingPathComponent("\(stem)-video.mov")
        let tone = folder.appendingPathComponent("\(stem)-audio.caf")
        try await writeVideo(to: silent, seconds: seconds, fps: fps,
                             width: width, height: height, hue: hue)
        try writeAudio(to: tone, seconds: seconds, hz: hz)

        let composition = AVMutableComposition()
        for (asset, type) in [(AVURLAsset(url: silent), AVMediaType.video),
                              (AVURLAsset(url: tone), AVMediaType.audio)] {
            guard let source = try await asset.loadTracks(withMediaType: type).first,
                  let track = composition.addMutableTrack(
                    withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                      of: source, at: .zero)
        }
        try? FileManager.default.removeItem(at: url)
        try await Composer.export(composition, to: url, container: .mov,
                                  preset: AVAssetExportPresetHighestQuality)
        try? FileManager.default.removeItem(at: silent)
        try? FileManager.default.removeItem(at: tone)
        return url
    }

    /// A directory that cleans itself up.
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-forge-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
