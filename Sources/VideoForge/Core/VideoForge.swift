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
//  ``CodecPlan``; ``VideoCodec/source`` keeps the source's, depth and alpha
//  included. Both write through an export session — unless the job asks
//  for a bitrate, a quality or a frame rate, which no preset can be told,
//  or redraws ProRes 4444: those take the WRITER road (``Transcoder``),
//  a reader and a writer configured by ``WriterSettings``.
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
        // A retouch follows a landmark track, made before the frames are.
        var options = options
        options.operations = try await tracked(options.operations, source: source, duration: before.duration)
        // The codec first, before anything is touched on disk: it can refuse
        // the job (10-bit into an 8-bit encoder), and it decides the
        // container (ProRes is QuickTime only).
        let codec = try options.export.codec(for: before)
        let container = try options.export.container(for: before, destination: destination)
        try check(destination, overwrites: options.overwrites)
        let passesThrough = CodecPlan.passesThrough(options.export, codec: codec,
                                                    sourceCodec: before.video?.codec,
                                                    sourceAlpha: before.hasAlpha,
                                                    timeOnly: options.isTimeOnly)

        // A bitrate, a quality or a frame rate — which no preset takes — or
        // a ProRes 4444 redraw: the writer road. Everything else below is
        // the export session, exactly as before 0.5.0.
        if CodecPlan.usesWriter(options.export, codec: codec, redraws: !options.isTimeOnly) {
            guard before.hasVideo else { throw VideoForgeError.noVideoTrack(source) }
            try await Transcoder.write(.clip(source, operations: options.operations, size: before.size),
                                       export: options.export, codec: codec,
                                       container: container, to: destination)
            return VideoProcessResult(
                source: source, destination: destination, before: before,
                after: try await describe(destination), passedThrough: false,
                operations: options.operations, seconds: -started.timeIntervalSinceNow)
        }

        // A passthrough speed change with sound: the samples are copied, and
        // only the sound — which a passthrough export would copy unscaled —
        // goes through a time-pitch pass. See Transcoder.
        if passesThrough, CodecPlan.retimesSound(options.operations, keepsAudio: options.export.keepsAudio,
                                                 hasAudio: before.hasAudio) {
            try await Transcoder.write(.clip(source, operations: options.operations, size: before.size),
                                       export: options.export, codec: codec, container: container,
                                       copiesVideo: true, to: destination)
            return VideoProcessResult(
                source: source, destination: destination, before: before,
                after: try await describe(destination), passedThrough: true,
                operations: options.operations, seconds: -started.timeIntervalSinceNow)
        }

        let asset = AVURLAsset(url: source)

        // The time-only steps first, because trimming before redrawing means
        // redrawing far fewer frames.
        let composition = try await Composer.build(
            from: asset, operations: options.operations,
            keepsAudio: options.export.keepsAudio,
            keepsSidecarTracks: options.export.keepsSidecarTracks)
        let subtitles = container.holdsSubtitles
            ? try await detachSparseTracks(from: composition, of: asset, url: source) : []

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
        try await export(composition, carrying: subtitles, to: destination, container: container,
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

        if CodecPlan.usesWriter(export, codec: codec, redraws: false) {
            try await Transcoder.write(.join(sources, size: before.size), export: export, codec: codec,
                                       container: container, to: destination)
        } else {
            let (composition, placements) = try await Composer.concatenate(
                sources.map { AVURLAsset(url: $0) }, keepsAudio: export.keepsAudio)
            // MEASURED: clips of different sizes, exported with no video
            // composition, came out as one track with a sample description
            // per size — ffmpeg could not decode past the first clip. Drawn
            // through a composition, every frame is the first clip's size.
            // Clips turned different ways are drawn too, each turned by its
            // own transform (see Placing).
            var videoComposition: AVVideoComposition?
            if !placements.isEmpty || Set(clips.map(\.size)).count > 1 {
                videoComposition = try await Renderer.build(for: composition, operations: [],
                                                            source: before.size,
                                                            placements: placements).composition
            }
            // Joining re-times the samples, so passthrough is not on offer.
            let subtitles = export.keepsSidecarTracks
                ? try await joinedSubtitles(sources, container: container) : []
            try await Self.export(composition, carrying: subtitles, to: destination, container: container,
                             preset: CodecPlan.preset(for: codec), videoComposition: videoComposition)
        }

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

    // MARK: - Writing

    /// Exports a composition — and when it had subtitle tracks, taken out
    /// by ``detachSparseTracks(from:of:url:)``, copies the export into
    /// `destination` with them written back from their re-timed samples.
    ///
    /// The copy is the remuxer's: every sample of the export, byte for
    /// byte, its edits included — measured on a passthrough trim, the
    /// decoded frames and sound are identical before and after it. It costs
    /// one more pass over the file, and only when there are subtitles.
    static func export(_ composition: AVMutableComposition, carrying sidecars: [Remuxer.MadeTrack],
                       to destination: URL, container: VideoContainer, preset: String,
                       videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil) async throws {
        guard !sidecars.isEmpty else {
            return try await Composer.export(composition, to: destination, container: container,
                                             preset: preset, videoComposition: videoComposition, audioMix: audioMix)
        }
        // Beside the destination, so the copy stays on one volume.
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(container.fileExtension)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try await Composer.export(composition, to: staged, container: container,
                                  preset: preset, videoComposition: videoComposition, audioMix: audioMix)
        let plan = try await Remuxer.plan(AVURLAsset(url: staged), dropping: Remuxer.subtitleTypes)
        _ = try await Remuxer.remux(staged, copying: plan.tracks, associations: plan.associations,
                                    adding: sidecars, to: destination, fileType: container.fileType)
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
