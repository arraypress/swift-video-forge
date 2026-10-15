//
//  Reverser.swift
//  VideoForge
//
//  Created by David Sherlock @ ArrayPress
//
//  Playing a clip backwards, which is the one operation that cannot stream.
//  Every other verb reads a frame, writes a frame, and forgets it; this one
//  needs the LAST frame first, so something has to be held.
//
//  MEASURED: 90 frames of a 640×360 clip is 79 MB as BGRA. The same
//  arithmetic on ten seconds of 4K is roughly ten gigabytes, and on a
//  minute of it, sixty. Holding the whole clip is therefore not an
//  implementation detail to get right later — it is the design.
//
//  So the clip is reversed in CHUNKS sized to a memory budget: each chunk's
//  frames are held, written backwards, and released, and the chunks
//  themselves are joined in reverse order. Reversing the chunks AND their
//  order is what makes the result a true reverse rather than a shuffle of
//  forward-playing segments — the failure mode of every naive
//  implementation.
//
//  Audio is reversed separately, through a file rather than a second writer
//  input, because feeding one writer two inputs is what deadlocks it.
//
//  Depth: frames were once read as 8-bit BGRA and written as H.264 whatever
//  the source, so a 10-bit clip came back 8-bit. A deep source is now read
//  as 10-bit 4:2:0 (three bytes a pixel, under the four the budget assumes)
//  and written as HEVC Main 10 — or whichever deep codec was asked for.
//

import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Plays a clip backwards.
public enum Reverser {

    /// Reverses a movie.
    ///
    /// - Parameters:
    ///   - source: The movie to reverse.
    ///   - destination: Where to write.
    ///   - keepsAudio: Reverse the sound as well. A reversed clip with
    ///     forward audio is worse than a silent one.
    ///   - codec: The codec to write; ``VideoCodec/source`` keeps the
    ///     source's, depth included.
    ///   - budget: The most memory to hold in frames at once. The clip is
    ///     divided into chunks that fit.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What the result is.
    /// - Throws: ``VideoForgeError``.
    @discardableResult
    public static func reverse(_ source: URL, to destination: URL,
                               keepsAudio: Bool = true,
                               codec: VideoCodec = .source,
                               budget: Int = Frames.defaultMemoryBudget,
                               overwrites: Bool = false) async throws -> VideoInfo {
        let info = try await Probe.describe(source)
        guard let track = info.video else { throw VideoForgeError.noVideoTrack(source) }
        guard info.duration > 0 else { throw VideoForgeError.emptyRange("a clip of no length") }
        let export = ExportSpec(codec: codec)
        let writes = try export.codec(for: info)
        let container = try export.container(for: info, destination: destination)
        try VideoForge.check(destination, overwrites: overwrites)

        let asset = AVURLAsset(url: source)
        let chunks = plan(info: info, budget: budget)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-forge-reverse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Last chunk first, and each one's frames backwards inside it.
        var pieces: [URL] = []
        for (index, range) in chunks.enumerated().reversed() {
            let piece = workspace.appendingPathComponent("chunk-\(index).mov")
            try await reverseChunk(asset, range: range, track: track, codec: writes,
                                   deep: info.isDeep, to: piece)
            pieces.append(piece)
        }
        guard !pieces.isEmpty else { throw VideoForgeError.emptyRange("the clip") }

        let composition = try await Composer.concatenate(
            pieces.map { AVURLAsset(url: $0) }, keepsAudio: false)

        if keepsAudio, info.hasAudio,
           let reversedAudio = try? await reverseAudio(asset, into: workspace) {
            try add(reversedAudio, to: composition)
        }

        try await Composer.export(composition, to: destination, container: container,
                                  preset: CodecPlan.preset(for: writes))
        return try await Probe.describe(destination)
    }

    /// How to divide a clip so each piece's frames fit in the budget.
    ///
    /// - Parameters:
    ///   - info: What the clip is.
    ///   - budget: Bytes allowed at once.
    /// - Returns: The time ranges, in forward order.
    static func plan(info: VideoInfo, budget: Int) -> [CMTimeRange] {
        let perFrame = max(1, info.width * info.height * 4)
        let framesAtOnce = max(1, budget / perFrame)
        let rate = info.frameRate > 0 ? info.frameRate : 30
        let chunkSeconds = max(0.1, Double(framesAtOnce) / rate)

        var ranges: [CMTimeRange] = []
        var start = 0.0
        while start < info.duration {
            let length = min(chunkSeconds, info.duration - start)
            ranges.append(CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                      duration: CMTime(seconds: length, preferredTimescale: 600)))
            start += length
        }
        return ranges
    }

    /// Reads one chunk's frames and writes them backwards.
    ///
    /// - Parameters:
    ///   - asset: The source.
    ///   - range: The chunk.
    ///   - track: The source's video track, described.
    ///   - codec: The concrete codec to write.
    ///   - deep: Whether the source is 10-bit, so the frames are read and
    ///     written at 10 bits rather than squeezed through 8-bit BGRA.
    ///   - url: Where the chunk goes.
    static func reverseChunk(_ asset: AVAsset, range: CMTimeRange, track: TrackInfo,
                             codec: VideoCodec, deep: Bool, to url: URL) async throws {
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoForgeError.noVideoTrack(url)
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let format = deep ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let output = AVAssetReaderTrackOutput(track: source, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw VideoForgeError.unreadable(url, reason: reader.error?.localizedDescription ?? "could not read")
        }

        var images: [CVPixelBuffer] = []
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            images.append(buffer)
            times.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        guard !images.isEmpty else { throw VideoForgeError.emptyRange("a chunk") }

        // The frames come out backwards; the timestamps stay in forward order,
        // so the chunk plays for exactly as long as it did.
        let offsets = times.map { CMTimeSubtract($0, range.start) }
        let colour = try await colourProperties(of: source)
        try await write(images.reversed(), at: offsets, size: track.size ?? .zero,
                        codec: codec, deep: deep, bitRate: Int(track.bitRate),
                        colour: colour, to: url)
    }

    /// The source's colour tags, as writer settings, so an HLG or PQ clip
    /// is not written back untagged and played as if it were Rec. 709.
    static func colourProperties(of track: AVAssetTrack) async throws -> [String: String]? {
        guard let description = try await track.load(.formatDescriptions).first else { return nil }
        let tag = { (key: CFString) in
            CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
        }
        guard let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = tag(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = tag(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix]
    }

    /// Writes frames to a file, one writer input, nothing to interleave.
    ///
    /// - Parameters:
    ///   - frames: The pictures, in the order to write them.
    ///   - times: Their presentation times.
    ///   - size: The frame size.
    ///   - codec: The concrete codec.
    ///   - deep: Whether the frames are 10-bit, which asks HEVC for Main 10.
    ///   - bitRate: The source's rate, honoured by the inter-frame codecs.
    ///   - colour: Colour tags to carry, if the source had them.
    ///   - url: Where to write.
    static func write(_ frames: [CVPixelBuffer], at times: [CMTime], size: CGSize,
                      codec: VideoCodec, deep: Bool, bitRate: Int,
                      colour: [String: String]?, to url: URL) async throws {
        let width = Int(size.width), height = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.codecType ?? .h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ]
        var compression: [String: Any] = [:]
        if bitRate > 0, !codec.isIntraFrame { compression[AVVideoAverageBitRateKey] = bitRate }
        // Under the compression properties, not at the top level, where it
        // throws an Objective-C exception.
        if deep, codec == .hevc {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        if !compression.isEmpty { settings[AVVideoCompressionPropertiesKey] = compression }
        // Settings the writer would reject raise an exception Swift cannot
        // catch, so the colour tags are offered only when they apply.
        if let colour {
            var tagged = settings
            tagged[AVVideoColorPropertiesKey] = colour
            if writer.canApply(outputSettings: tagged, forMediaType: .video) { settings = tagged }
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw VideoForgeError.writeFailed(url, reason: "the writer will not take \(codec.rawValue) at \(width)×\(height)")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoForgeError.writeFailed(url, reason: writer.error?.localizedDescription ?? "refused")
        }
        writer.startSession(atSourceTime: .zero)

        let ordered = Array(frames)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var index = 0
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "video-forge.reverse")) {
                while input.isReadyForMoreMediaData {
                    guard index < ordered.count else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    adaptor.append(ordered[index], withPresentationTime: times[index])
                    index += 1
                }
            }
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw VideoForgeError.writeFailed(url, reason: writer.error?.localizedDescription ?? "failed")
        }
    }

    /// Reverses the sound into a file of its own.
    ///
    /// Through `AVAudioFile` rather than a second writer input: one writer
    /// with two inputs is the shape that deadlocks.
    static func reverseAudio(_ asset: AVAsset, into workspace: URL) async throws -> URL {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw VideoForgeError.noAudioTrack(workspace)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw VideoForgeError.unreadable(workspace, reason: "the audio would not read")
        }

        var samples: [Float] = []
        var channels = 1
        var rate = 44100.0
        while let sample = output.copyNextSampleBuffer() {
            if let description = CMSampleBufferGetFormatDescription(sample),
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                channels = Int(basic.pointee.mChannelsPerFrame)
                rate = basic.pointee.mSampleRate
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: length / 4))
            }
        }
        guard !samples.isEmpty else { throw VideoForgeError.noAudioTrack(workspace) }

        // Reverse by FRAME, not by sample: reversing interleaved stereo
        // sample by sample swaps the two channels as well as the time.
        let frames = samples.count / max(1, channels)
        var reversed = [Float](repeating: 0, count: samples.count)
        for frame in 0..<frames {
            let from = (frames - 1 - frame) * channels
            let to = frame * channels
            for channel in 0..<channels { reversed[to + channel] = samples[from + channel] }
        }

        let url = workspace.appendingPathComponent("audio.caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                         channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)) else {
            throw VideoForgeError.writeFailed(url, reason: "could not make an audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            for frame in 0..<frames {
                buffer.floatChannelData?[channel][frame] = reversed[frame * channels + channel]
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// Lays a soundtrack under a composition.
    static func add(_ audio: URL, to composition: AVMutableComposition) throws {
        let asset = AVURLAsset(url: audio)
        guard let source = asset.tracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        let take = CMTimeMinimum(asset.duration, composition.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: take), of: source, at: .zero)
    }
}
