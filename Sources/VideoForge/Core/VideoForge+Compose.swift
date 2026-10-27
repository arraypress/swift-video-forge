//
//  VideoForge+Compose.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A whole edit in one render. The picture is drawn and encoded ONCE —
//  clips, overlays, titles and captions together — through the writer road.
//  With music or sound effects, that first file keeps its sound as float
//  PCM, and the soundtrack pass (VideoForge+Music) mixes the bed and the
//  effects into it, ducked under the clips' speech and the voice-over,
//  COPYING the picture: one picture encode and one sound encode either way.
//

import AVFoundation
import CoreGraphics
import Foundation

/// What an edit's render did.
public struct ComposeResult: Sendable {
    public let result: VideoProcessResult
    /// Where each clip landed on the edit, in seconds.
    public let clips: [ClosedRange<Double>]
    /// The written frame.
    public let size: CGSize
    /// The music and effects pass, when there was one: the speech it ducked
    /// under, the levels, the measured loudness.
    public let soundtrack: SoundtrackResult?
}

extension VideoForge {

    /// Every problem with an edit, each named by its place (`clips[2].to`);
    /// empty when it can be rendered. Opens the files to learn their
    /// lengths, decodes nothing.
    public static func problems(in edit: EditTimeline) async -> [String] {
        do {
            _ = try await prepare(edit)
            return []
        } catch let EditProblems.found(problems) {
            return problems
        } catch {
            return [(error as? VideoForgeError)?.errorDescription ?? error.localizedDescription]
        }
    }

    /// Renders an edit.
    ///
    /// ```swift
    /// var edit = EditTimeline(clips: [EditClip(hook, to: 2.5), EditClip(demo, from: 10, to: 18)])
    /// edit.size = CGSize(width: 1080, height: 1920)
    /// edit.music = EditMusic(song)
    /// let done = try await VideoForge.compose(edit, to: out)
    /// done.clips        // [0...2.5, 2.5...10.5]
    /// ```
    ///
    /// - Parameters:
    ///   - edit: The edit.
    ///   - destination: Where to write.
    ///   - export: How to write it; the codec is resolved against the first clip.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Throws: ``VideoForgeError/invalidOptions(_:)`` listing every problem
    ///   with the edit, one a line, or any other ``VideoForgeError``.
    @discardableResult
    public static func compose(_ edit: EditTimeline, to destination: URL, export: ExportSpec = ExportSpec(),
                               overwrites: Bool = false) async throws -> ComposeResult {
        let started = Date()
        let (job, first) = try await prepared(edit)
        var export = export
        if let fps = edit.frameRate { export.frameRate = fps }
        let codec = try export.codec(for: first)
        let container = try export.container(for: first, destination: destination)
        try check(destination, overwrites: overwrites)
        let ranges = EditRules.clipRanges(edit.clips, lengths: job.lengths.clips)

        var soundtrack: SoundtrackResult?
        if edit.music != nil || !edit.sounds.isEmpty {
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("vid-compose-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: staged) }
            try await Transcoder.write(.compose(job), export: export, codec: codec,
                                       container: .mov, pcmAudio: true, to: staged)
            soundtrack = try await self.soundtrack(staged, destination: destination, music: edit.music?.file,
                                                   bed: edit.music?.bed ?? MusicBed(), sounds: edit.sounds,
                                                   effects: edit.effects, overwrites: true)
            _ = container
        } else {
            try await Transcoder.write(.compose(job), export: export, codec: codec, container: container, to: destination)
        }
        let result = VideoProcessResult(source: edit.clips[0].file, destination: destination, before: first,
                                        after: try await describe(destination), passedThrough: false,
                                        operations: [], seconds: -started.timeIntervalSinceNow)
        return ComposeResult(result: result, clips: ranges, size: job.frame, soundtrack: soundtrack)
    }

    /// Frames of an edit at times on it, drawn exactly as the render draws
    /// them — for a contact sheet to check an edit before rendering it.
    ///
    /// - Parameters:
    ///   - edit: The edit.
    ///   - times: Seconds on the edit.
    ///   - width: The stills' width; their height keeps the frame's shape.
    /// - Returns: One still per time, in order.
    public static func composeFrames(_ edit: EditTimeline, at times: [Double], width: Int = 540) async throws -> [CGImage] {
        let (job, _) = try await prepared(edit)
        let built = try await Composing.build(job, keepsAudio: false, frameRate: edit.frameRate)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let height = Int((Double(width) * job.frame.height / max(1, job.frame.width)).rounded())
        generator.maximumSize = CGSize(width: width, height: height)
        let total = built.clipRanges.last?.upperBound ?? 0
        var stills: [CGImage] = []
        for time in times {
            let at = Composing.time(max(0, min(time, total - 0.001)))
            stills.append(try await generator.image(at: at).image)
        }
        return stills
    }

    // MARK: - Checking

    /// Problems found checking an edit.
    enum EditProblems: Error { case found([String]) }

    /// The checked job and the first clip's description.
    static func prepared(_ edit: EditTimeline) async throws -> (Composing.Job, VideoInfo) {
        do { return try await prepare(edit) } catch let EditProblems.found(problems) {
            throw VideoForgeError.invalidOptions(problems.joined(separator: "\n"))
        }
    }

    private static func prepare(_ edit: EditTimeline) async throws -> (Composing.Job, VideoInfo) {
        var missing: [String] = []
        func exists(_ url: URL, _ place: String) -> Bool {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            missing.append("\(place).file: \(url.path) was not found")
            return false
        }
        var clipInfos: [VideoInfo?] = []
        for (index, clip) in edit.clips.enumerated() {
            clipInfos.append(exists(clip.file, "clips[\(index)]") ? try? await describe(clip.file) : nil)
        }
        var overlayLengths: [Double] = []
        for (index, overlay) in edit.overlays.enumerated() {
            overlayLengths.append(exists(overlay.file, "overlays[\(index)]") ? (try? await describe(overlay.file))?.duration ?? 0 : 0)
        }
        var voiceLengths: [Double] = []
        for (index, voice) in edit.voices.enumerated() {
            let seconds = exists(voice.file, "voices[\(index)]")
                ? (try? await AVURLAsset(url: voice.file).load(.duration))?.seconds ?? 0 : 0
            voiceLengths.append(seconds)
        }
        if let music = edit.music { _ = exists(music.file, "music") }
        for (index, sound) in edit.sounds.enumerated() { _ = exists(sound.file, "sounds[\(index)]") }
        for (index, info) in clipInfos.enumerated() where info == nil && FileManager.default.fileExists(atPath: edit.clips[index].file.path) {
            missing.append("clips[\(index)].file: \(edit.clips[index].file.lastPathComponent) is not a video this Mac can read")
        }
        let lengths = EditRules.Lengths(clips: clipInfos.map { $0?.duration ?? 0 },
                                        clipsHaveVideo: clipInfos.map { $0?.hasVideo ?? true },
                                        overlays: overlayLengths, voices: voiceLengths)
        let problems = missing + EditRules.problems(in: edit, lengths: lengths)
        guard problems.isEmpty, let first = clipInfos.first ?? nil else {
            throw EditProblems.found(problems.isEmpty ? ["clips: an edit needs at least one clip"] : problems)
        }
        let frame = edit.size ?? CGSize(width: first.width / 2 * 2, height: first.height / 2 * 2)
        return (Composing.Job(edit: edit, lengths: lengths, frame: frame), first)
    }
}
