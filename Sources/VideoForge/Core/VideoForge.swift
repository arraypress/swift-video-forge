//
//  VideoForge.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The front door. Two roads run underneath, and which one a job takes is
//  the most consequential thing about it:
//
//  · The COMPOSITION road rearranges time — trim, join, speed, drop a
//    track — without decoding a frame. Instant, and lossless.
//  · The RENDER road redraws every frame — crop, scale, turn, reverse —
//    and has to be told how, or it turns 10-bit HDR into 8-bit SDR.
//
//  Both write with the codec ``ExportSpec/codec`` names, resolved by
//  ``CodecPlan``; ``VideoCodec/source`` keeps the source's, depth included.
//
//  ``VideoProcessResult/passedThrough`` says which one ran, because a
//  caller deserves to know whether their footage was re-encoded.
//

import AVFoundation
import Foundation

/// Reads, transforms and writes video.
///
/// ```swift
/// // A trim: instant, and the frames are untouched.
/// let result = try await VideoForge.process(clip, to: out,
///     options: .trim(.between(5, 15)))
/// result.passedThrough   // true
///
/// // Sound on its own.
/// try await VideoForge.extractAudio(from: clip, to: track)
/// ```
public enum VideoForge {

    // MARK: - Describing

    /// What a movie file contains, read without decoding a frame.
    ///
    /// - Parameter url: The file to describe.
    /// - Returns: Its duration, frame size, rate and every track.
    /// - Throws: Any ``VideoForgeError``.
    public static func describe(_ url: URL) async throws -> VideoInfo {
        try await Probe.describe(url)
    }

    // MARK: - Processing

    /// Runs one video job and writes the result.
    ///
    /// - Parameters:
    ///   - source: The movie to read.
    ///   - destination: Where to write.
    ///   - options: What to do and how to write it.
    /// - Returns: What happened, including which road it took.
    /// - Throws: Any ``VideoForgeError``.
    @discardableResult
    public static func process(_ source: URL, to destination: URL,
                               options: VideoProcessOptions) async throws -> VideoProcessResult {
        let started = Date()
        let before = try await describe(source)
        // The codec first, before anything is touched on disk: it can refuse
        // the job (10-bit into an 8-bit encoder), and it decides the
        // container (ProRes is QuickTime only).
        let codec = try options.export.codec(for: before)
        let container = try options.export.container(for: before, destination: destination)
        try check(destination, overwrites: options.overwrites)
        let passesThrough = CodecPlan.passesThrough(options.export, codec: codec,
                                                    sourceCodec: before.video?.codec,
                                                    timeOnly: options.isTimeOnly)
        let asset = AVURLAsset(url: source)

        // The time-only steps first, because trimming before redrawing means
        // redrawing far fewer frames.
        let composition = try await Composer.build(
            from: asset, operations: options.operations,
            keepsAudio: options.export.keepsAudio,
            keepsSidecarTracks: options.export.keepsSidecarTracks)

        // MEASURED: the HEVC-with-alpha preset will not COPY a source that
        // has no alpha (-11838), but redraws one without complaint — so a
        // time-only job written as hevcAlpha goes through an empty render.
        var videoComposition: AVVideoComposition?
        if !options.isTimeOnly || (!passesThrough && codec == .hevcAlpha) {
            guard before.hasVideo else { throw VideoForgeError.noVideoTrack(source) }
            videoComposition = try await Renderer.build(
                for: composition, operations: options.operations, source: before.size).composition
        }

        let preset = passesThrough ? AVAssetExportPresetPassthrough : CodecPlan.preset(for: codec)
        try await Composer.export(composition, to: destination, container: container,
                                  preset: preset, videoComposition: videoComposition)

        return VideoProcessResult(
            source: source, destination: destination, before: before,
            after: try await describe(destination),
            passedThrough: passesThrough,
            operations: options.operations,
            seconds: -started.timeIntervalSinceNow)
    }

    /// Joins movies end to end.
    ///
    /// - Parameters:
    ///   - sources: The clips, in order.
    ///   - destination: Where to write.
    ///   - export: How to write it.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What happened.
    /// - Throws: Any ``VideoForgeError``.
    @discardableResult
    public static func join(_ sources: [URL], to destination: URL,
                            export: ExportSpec = ExportSpec(),
                            overwrites: Bool = false) async throws -> VideoProcessResult {
        let started = Date()
        guard let first = sources.first else {
            throw VideoForgeError.incompatibleClips(reason: "no clips were given")
        }
        var clips: [VideoInfo] = []
        for source in sources { clips.append(try await describe(source)) }
        let before = clips[0]
        // Deep if ANY clip is deep: a 10-bit clip in the middle of 8-bit
        // ones still must not be written by an 8-bit encoder.
        let codec = try export.codec(forClips: clips)
        let container = try CodecPlan.container(explicit: export.container, destination: destination,
                                                inherited: before.container, codec: codec)
        try check(destination, overwrites: overwrites)

        let composition = try await Composer.concatenate(
            sources.map { AVURLAsset(url: $0) }, keepsAudio: export.keepsAudio)
        // Joining re-times the samples, so passthrough is not on offer.
        try await Composer.export(composition, to: destination, container: container,
                                  preset: CodecPlan.preset(for: codec))

        return VideoProcessResult(
            source: first, destination: destination, before: before,
            after: try await describe(destination), passedThrough: false,
            operations: [], seconds: -started.timeIntervalSinceNow)
    }

    /// Plays a movie backwards.
    ///
    /// Reversing cannot stream — the last frame is needed first — so the
    /// clip is divided into chunks that fit a memory budget, each chunk's
    /// frames written backwards, and the chunks joined in reverse order.
    ///
    /// - Parameters:
    ///   - source: The movie to reverse.
    ///   - destination: Where to write.
    ///   - keepsAudio: Reverse the sound too. A reversed picture with
    ///     forward sound is worse than a silent one.
    ///   - codec: The codec to write; the source's own by default, and a
    ///     10-bit source is read and written at 10 bits.
    ///   - budget: The most memory to hold in frames at once.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What happened.
    /// - Throws: Any ``VideoForgeError``.
    @discardableResult
    public static func reverse(_ source: URL, to destination: URL,
                               keepsAudio: Bool = true,
                               codec: VideoCodec = .source,
                               budget: Int = Frames.defaultMemoryBudget,
                               overwrites: Bool = false) async throws -> VideoProcessResult {
        let started = Date()
        let before = try await describe(source)
        let after = try await Reverser.reverse(source, to: destination, keepsAudio: keepsAudio,
                                               codec: codec, budget: budget, overwrites: overwrites)
        return VideoProcessResult(source: source, destination: destination, before: before,
                                  after: after, passedThrough: false, operations: [.reverse],
                                  seconds: -started.timeIntervalSinceNow)
    }

    // MARK: - Audio

    /// Writes a movie's sound out on its own.
    ///
    /// - Parameters:
    ///   - source: The movie to read.
    ///   - destination: Where to write. Its extension picks the container.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What was written.
    /// - Throws: ``VideoForgeError/noAudioTrack(_:)`` when there is none.
    @discardableResult
    public static func extractAudio(from source: URL, to destination: URL,
                                    overwrites: Bool = false) async throws -> VideoInfo {
        try check(destination, overwrites: overwrites)
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw VideoForgeError.noAudioTrack(source)
        }
        let container = VideoContainer.named(fileExtension: destination.pathExtension) ?? .m4a
        let preset = container == .m4a
            ? AVAssetExportPresetAppleM4A
            : AVAssetExportPresetPassthrough

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoForgeError.exportFailed(reason: "no exporter for \(container.rawValue)")
        }
        do {
            try await session.export(to: destination, as: container.fileType)
        } catch {
            throw VideoForgeError.exportFailed(reason: error.localizedDescription)
        }
        return try await describe(destination)
    }

    /// Puts a soundtrack under a movie, replacing whatever it had.
    ///
    /// The music is trimmed to the movie's length; a movie longer than its
    /// music keeps playing in silence rather than being cut short, because
    /// the picture is what somebody came for.
    ///
    /// - Parameters:
    ///   - source: The movie.
    ///   - music: The audio to lay under it.
    ///   - destination: Where to write.
    ///   - keepsOriginalAudio: Keep the movie's own sound as well.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What happened.
    /// - Throws: Any ``VideoForgeError``.
    @discardableResult
    public static func addAudio(to source: URL, music: URL, destination: URL,
                                keepsOriginalAudio: Bool = false,
                                overwrites: Bool = false) async throws -> VideoProcessResult {
        let started = Date()
        let before = try await describe(source)
        // The picture is re-encoded in its own codec — a 10-bit clip under
        // new music stays 10-bit.
        let export = ExportSpec()
        let codec = try export.codec(for: before)
        let container = try export.container(for: before, destination: destination)
        try check(destination, overwrites: overwrites)

        let asset = AVURLAsset(url: source)
        let musicAsset = AVURLAsset(url: music)
        guard let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first else {
            throw VideoForgeError.noAudioTrack(music)
        }

        let composition = try await Composer.build(
            from: asset, operations: [], keepsAudio: keepsOriginalAudio,
            keepsSidecarTracks: true)

        if let added = composition.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
            let musicDuration = try await musicAsset.load(.duration)
            let take = CMTimeMinimum(musicDuration, composition.duration)
            try added.insertTimeRange(CMTimeRange(start: .zero, duration: take),
                                      of: musicTrack, at: .zero)
        }

        try await Composer.export(composition, to: destination, container: container,
                                  preset: CodecPlan.preset(for: codec))

        return VideoProcessResult(
            source: source, destination: destination, before: before,
            after: try await describe(destination), passedThrough: false,
            operations: [], seconds: -started.timeIntervalSinceNow)
    }

    // MARK: - Guards

    /// Makes room for a result: creates the folder it goes in, and refuses
    /// to replace a file unless asked.
    ///
    /// The folder matters. `AVAssetExportSession` does not create one, and
    /// reports a missing parent as "Cannot create file" — which reads like a
    /// permissions problem rather than a directory that is simply not there.
    /// `img` has always created it, and two sibling tools disagreeing about
    /// whether `--out ./new` works is worse than either behaviour.
    ///
    /// - Parameters:
    ///   - url: Where the result would go.
    ///   - overwrites: Whether replacing is allowed.
    /// - Throws: ``VideoForgeError/destinationExists(_:)``.
    static func check(_ url: URL, overwrites: Bool) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard overwrites else { throw VideoForgeError.destinationExists(url) }
        try? FileManager.default.removeItem(at: url)
    }
}
