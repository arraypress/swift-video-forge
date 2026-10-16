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
//  metadata tracks are written from their samples, cut and re-timed by
//  their edits (SubtitleRetiming).
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
        /// One clip over another (Overlaying).
        case overlay(Overlaying.Job)
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
        // A reader stalled inside an edited composition gets one fresh start
        // (see WriterPump's watchdog).
        try await WriterPump.retryingStall(url) {
            let (job, end) = try await makeJob(timeline, export: export, codec: codec,
                                               container: container, copiesVideo: copiesVideo, to: url)
            try await WriterPump.runOnce(job, until: end)
        }
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
        var sidecars: [Remuxer.MadeTrack] = []
        var placements: [ClipPlacement] = []
        var drawn: AVVideoComposition?
        var audioMix: AVAudioMix?
        switch timeline {
        case .clip(let source, let steps, let size):
            (first, operations, shown) = (source, steps, size)
            let asset = AVURLAsset(url: source)
            composition = try await Composer.build(
                from: asset, operations: steps, keepsAudio: export.keepsAudio,
                keepsSidecarTracks: export.keepsSidecarTracks)
            // Subtitles and timed metadata are written from re-timed
            // samples, not read through the composition: the reader hands
            // them back un-cut and in media time (SubtitleRetiming).
            sidecars = container.holdsSubtitles
                ? try await VideoForge.detachSparseTracks(from: composition, of: asset, url: source) : []
        case .join(let sources, let size):
            guard let head = sources.first else {
                throw VideoForgeError.incompatibleClips(reason: "no clips were given")
            }
            (first, operations, shown) = (head, [], size)
            (composition, placements) = try await Composer.concatenate(sources.map { AVURLAsset(url: $0) },
                                                                       keepsAudio: export.keepsAudio)
            sidecars = export.keepsSidecarTracks
                ? try await VideoForge.joinedSubtitles(sources, container: container) : []
        case .overlay(let job):
            (first, operations, shown) = (job.main, [], job.frame)
            let built = try await Overlaying.build(job, export: export, container: container)
            (composition, drawn, audioMix, sidecars) = (built.composition, built.videoComposition,
                                                        built.audioMix, built.sidecars)
        }
        // Time rescaled, sound from several files, or two sounds mixed: the
        // sound is decoded rather than copied.
        let decodesAudio: Bool
        switch timeline {
        case .join: decodesAudio = true
        case .overlay: decodesAudio = audioMix != nil
        case .clip: decodesAudio = operations.contains { if case .speed = $0 { return true } else { return false } }
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
        var videoInput: AVAssetWriterInput?

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
                videoInput = videoInput ?? input
            }
        } else {
            let redrawn = try await redrawnVideo(composition, operations: operations, shown: shown,
                                                placements: placements, drawn: drawn, source: sourceAsset,
                                                export: export, codec: codec,
                                                reader: reader, writer: writer, url: url)
            feeds.append(redrawn)
            videoInput = redrawn.input
        }

        // The sound. Its rate is read off the SOURCE: a composition track
        // sped up twice reports twice the bytes a second.
        var sourceRates: [Double] = []
        for track in try await sourceAsset.loadTracks(withMediaType: .audio) {
            sourceRates.append(Double(try await track.load(.estimatedDataRate)))
        }
        var audioInputs: [AVAssetWriterInput] = []
        let sounds = try await composition.loadTracks(withMediaType: .audio)
        if let audioMix, let lead = sounds.first {
            // Two sounds mixed into one track, by the job's own mix.
            let mixed = AVAssetReaderAudioMixOutput(audioTracks: sounds, audioSettings: AudioRules.decoded)
            mixed.audioMix = audioMix
            var settings = AudioRules.encoded(like: try await lead.load(.formatDescriptions).first,
                                              bitRate: sourceRates.first ?? 0, codec: codec)
            if !writer.canApply(outputSettings: settings, forMediaType: .audio) { settings[AVEncoderBitRateKey] = nil }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(mixed), writer.canAdd(input) {
                reader.add(mixed)
                writer.add(input)
                feeds.append(.copying(from: mixed, to: input))
            }
        }
        for (index, track) in sounds.enumerated() where audioMix == nil {
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

        // Subtitles and timed metadata, from their re-timed samples; the
        // subtitles in one group, as players need them.
        let subtitleInputs = try Remuxer.add(sidecars, to: writer, feeds: &feeds, url: url, video: videoInput)
        writer.addAlternateGroup(subtitleInputs.map(\.input),
                                 defaultInput: subtitleInputs.first(where: \.isDefault)?.input)

        return (WriterJob(reader: reader, writer: writer, feeds: feeds), composition.duration)
    }
    /// The redrawn pictures: the composition's frames through the Core
    /// Image compositor, in the pixel format and settings derived for the
    /// codec, at the frame rate asked for.
    private static func redrawnVideo(_ composition: AVComposition, operations: [VideoOperation],
                                     shown: CGSize, placements: [ClipPlacement], drawn: AVVideoComposition?,
                                     source: AVAsset, export: ExportSpec,
                                     codec: VideoCodec, reader: AVAssetReader, writer: AVAssetWriter,
                                     url: URL) async throws -> WriterFeed {
        guard let sourceTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw VideoForgeError.noVideoTrack(url)
        }
        var format = try await VideoSourceFormat.load(from: sourceTrack)

        let videoComposition: AVVideoComposition
        let renderSize: CGSize
        if let drawn {
            // Built whole by its job, frame rate included.
            (videoComposition, renderSize) = (drawn, drawn.renderSize)
        } else {
            let (built, size) = try await Renderer.build(
                for: composition, operations: operations, source: shown, placements: placements)
            if let fps = export.frameRate {
                // MEASURED: a Core Image composition times its frames by the
                // source track (`sourceTrackIDForFrameTiming`), so a frame
                // duration alone changed nothing — 60 fps in, 240 frames of 60
                // out. Timing by the frame duration is what resamples.
                built.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
                built.frameDuration = WriterRules.frameDuration(fps: fps)
            }
            (videoComposition, renderSize) = (built, size)
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
