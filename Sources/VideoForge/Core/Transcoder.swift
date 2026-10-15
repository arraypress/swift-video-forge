//
//  Transcoder.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The WRITER road: a reader and a writer, for what an export session
//  cannot be told. The presets take a codec and nothing else — no bitrate,
//  no quality, no frame rate — so up to 0.4.0 `ExportSpec.bitRate`,
//  `quality` and `frameRate` were saved in recipes and read by nobody.
//
//  The frames come through the same Core Image composition the render road
//  uses (``Renderer``), read by an `AVAssetReaderVideoCompositionOutput` in
//  the pixel format ``WriterRules`` picks, and written with
//  ``WriterSettings``. A frame rate is the composition's frame duration:
//  frames are dropped or repeated to meet it, so the picture keeps its
//  length and stays in step with the sound.
//
//  Sound is copied sample for sample when time is not rescaled. A speed
//  change, or a join of clips whose sound may not agree, decodes the sound
//  through a spectral time-pitch pass and encodes it again: AAC, or 32-bit
//  float PCM beside ProRes, as its presets write. Subtitle and timed
//  metadata tracks are copied, re-timed by the reader with the edits.
//
//  The same road carries a PASSTHROUGH speed change with sound: the video
//  samples are copied (frame for frame, MD5-identical) and only the sound
//  is re-timed. MEASURED: up to 0.4.0 a passthrough export of a sped-up
//  composition copied the sound untouched — `speed --rate 0.5` wrote 3.02 s
//  of sound under 6 s of picture, byte-identical to the source's, and
//  `--rate 2` kept the first half of it at normal speed.
//
//  The feeding is ``WriterPump``'s, which is why there is no deadlock here
//  to reintroduce.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Writes jobs through a reader and a writer.
enum Transcoder {

    /// What to write.
    enum Timeline: Sendable {
        /// One clip, with its operations; `size` is its frame as shown.
        case clip(URL, operations: [VideoOperation], size: CGSize)
        /// Clips end to end; `size` is the first one's frame as shown.
        case join([URL], size: CGSize)
    }

    /// Writes a timeline.
    ///
    /// - Parameters:
    ///   - timeline: The clip and its operations, or the clips to join.
    ///   - export: How to write it.
    ///   - codec: The concrete codec.
    ///   - container: The container.
    ///   - copiesVideo: Copy the video samples rather than redraw them — a
    ///     time-only job whose only need of a writer is re-timed sound.
    ///   - url: Where to write.
    /// - Throws: ``VideoForgeError``, or `CancellationError`.
    static func write(_ timeline: Timeline, export: ExportSpec, codec: VideoCodec,
                      container: VideoContainer, copiesVideo: Bool = false, to url: URL) async throws {
        let (job, end) = try await makeJob(timeline, export: export, codec: codec,
                                           container: container, copiesVideo: copiesVideo, to: url)
        try await WriterPump.run(job, until: end)
    }

    /// Builds the composition, the reader, the writer and the feeds — all
    /// here, so the job can be handed to the pump whole.
    private static func makeJob(_ timeline: Timeline, export: ExportSpec, codec: VideoCodec,
                                container: VideoContainer, copiesVideo: Bool,
                                to url: URL) async throws -> sending (WriterJob, CMTime) {
        let first: URL
        let operations: [VideoOperation]
        let shown: CGSize
        let composition: AVMutableComposition
        switch timeline {
        case .clip(let source, let steps, let size):
            (first, operations, shown) = (source, steps, size)
            composition = try await Composer.build(
                from: AVURLAsset(url: source), operations: steps, keepsAudio: export.keepsAudio,
                keepsSidecarTracks: export.keepsSidecarTracks)
        case .join(let sources, let size):
            guard let head = sources.first else {
                throw VideoForgeError.incompatibleClips(reason: "no clips were given")
            }
            (first, operations, shown) = (head, [], size)
            composition = try await Composer.concatenate(sources.map { AVURLAsset(url: $0) },
                                                         keepsAudio: export.keepsAudio)
        }
        // Time rescaled, or sound from several files: the sound is decoded
        // rather than copied.
        let decodesAudio: Bool
        if case .join = timeline { decodesAudio = true } else {
            decodesAudio = operations.contains { if case .speed = $0 { return true } else { return false } }
        }

        let sourceAsset = AVURLAsset(url: first)
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: composition)
            writer = try AVAssetWriter(outputURL: url, fileType: container.fileType)
        } catch {
            throw VideoForgeError.writeFailed(url, reason: error.localizedDescription)
        }
        writer.metadata = (try? await sourceAsset.load(.metadata)) ?? []
        var feeds: [WriterFeed] = []

        // The pictures.
        if copiesVideo {
            for track in try await composition.loadTracks(withMediaType: .video) {
                let (descriptions, transform) = try await track.load(.formatDescriptions, .preferredTransform)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                               sourceFormatHint: descriptions.first)
                input.expectsMediaDataInRealTime = false
                input.transform = transform
                guard reader.canAdd(output), writer.canAdd(input) else {
                    throw VideoForgeError.writeFailed(url, reason: "the video could not be copied")
                }
                reader.add(output)
                writer.add(input)
                feeds.append(.copying(from: output, to: input))
            }
        } else {
            feeds.append(try await redrawnVideo(composition, operations: operations, shown: shown,
                                                source: sourceAsset, export: export, codec: codec,
                                                reader: reader, writer: writer, url: url))
        }

        // The sound. Its rate is read off the SOURCE: a composition track
        // sped up twice reports twice the bytes a second.
        var sourceRates: [Double] = []
        for track in try await sourceAsset.loadTracks(withMediaType: .audio) {
            sourceRates.append(Double(try await track.load(.estimatedDataRate)))
        }
        var audioInputs: [AVAssetWriterInput] = []
        for (index, track) in try await composition.loadTracks(withMediaType: .audio).enumerated() {
            let description = try await track.load(.formatDescriptions).first
            let rate = index < sourceRates.count ? sourceRates[index] : (sourceRates.first ?? 0)
            let output: AVAssetReaderOutput
            let input: AVAssetWriterInput
            if decodesAudio {
                let mix = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: AudioRules.decoded)
                mix.audioTimePitchAlgorithm = .spectral
                output = mix
                var settings = AudioRules.encoded(like: description, bitRate: rate, codec: codec)
                // A rate the encoder will not take raises an exception Swift
                // cannot catch; without one it still writes.
                if !writer.canApply(outputSettings: settings, forMediaType: .audio) {
                    settings[AVEncoderBitRateKey] = nil
                }
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            } else {
                output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: description)
            }
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { continue }
            reader.add(output)
            writer.add(input)
            feeds.append(.copying(from: output, to: input))
            audioInputs.append(input)
        }
        if audioInputs.count > 1 { writer.addAlternateGroup(audioInputs, defaultInput: audioInputs[0]) }

        // Subtitles and timed metadata, copied as they are — the reader
        // re-times a scaled edit's samples, as it does the video's. A track
        // the writer will not take is left out and shows in `lostTracks`.
        var subtitleInputs: [AVAssetWriterInput] = []
        do {
            for kind in [TrackKind.subtitle, .metadata] {
                for track in try await composition.loadTracks(withMediaType: kind.mediaType) {
                    let (descriptions, language, enabled) = try await track.load(
                        .formatDescriptions, .languageCode, .isEnabled)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    let input = AVAssetWriterInput(mediaType: kind.mediaType, outputSettings: nil,
                                                   sourceFormatHint: descriptions.first)
                    input.expectsMediaDataInRealTime = false
                    if let language, language != "und" { input.languageCode = language }
                    input.marksOutputTrackAsEnabled = enabled
                    guard reader.canAdd(output), writer.canAdd(input) else { continue }
                    reader.add(output)
                    writer.add(input)
                    feeds.append(.copying(from: output, to: input))
                    if kind == .subtitle { subtitleInputs.append(input) }
                }
            }
        }
        writer.addAlternateGroup(subtitleInputs, defaultInput: nil)

        return (WriterJob(reader: reader, writer: writer, feeds: feeds), composition.duration)
    }
    /// The redrawn pictures: the composition's frames through the Core
    /// Image compositor, in the pixel format and settings derived for the
    /// codec, at the frame rate asked for.
    private static func redrawnVideo(_ composition: AVComposition, operations: [VideoOperation],
                                     shown: CGSize, source: AVAsset, export: ExportSpec,
                                     codec: VideoCodec, reader: AVAssetReader, writer: AVAssetWriter,
                                     url: URL) async throws -> WriterFeed {
        guard let sourceTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw VideoForgeError.noVideoTrack(url)
        }
        var format = try await VideoSourceFormat.load(from: sourceTrack)

        let (videoComposition, renderSize) = try await Renderer.build(
            for: composition, operations: operations, source: shown)
        if let fps = export.frameRate {
            // MEASURED: a Core Image composition times its frames by the
            // source track (`sourceTrackIDForFrameTiming`), so a frame
            // duration alone changed nothing — 60 fps in, 240 frames of 60
            // out. Timing by the frame duration is what resamples.
            videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
            videoComposition.frameDuration = WriterRules.frameDuration(fps: fps)
        }
        // The composition's tags: the source's own, or Rec. 709 said
        // outright for an untagged source (see Renderer).
        if let primaries = videoComposition.colorPrimaries,
           let transfer = videoComposition.colorTransferFunction,
           let matrix = videoComposition.colorYCbCrMatrix {
            (format.colorPrimaries, format.transferFunction, format.yCbCrMatrix) = (primaries, transfer, matrix)
        }
        let settings = WriterSettings.derive(
            from: format, codec: codec, bitRate: export.bitRate, quality: export.quality,
            frameRate: export.frameRate, size: renderSize,
            keepsAlpha: format.hasAlpha && codec.keepsAlpha)

        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: settings.pixelFormat])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        let outputSettings = settings.videoOutputSettings
        // Settings the writer would reject raise an exception Swift cannot
        // catch, so they are checked first.
        guard reader.canAdd(output),
              writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
            throw VideoForgeError.writeFailed(
                url, reason: "the writer will not take \(codec.rawValue) at \(settings.width)×\(settings.height) with these settings")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        reader.add(output)
        writer.add(input)
        return .copying(from: output, to: input)
    }
}
