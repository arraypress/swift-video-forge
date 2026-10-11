//
//  VideoForge+Subtitles.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Subtitle tracks in and out of a movie. Written as `tx3g` — the one
//  format measured to reopen in AVFoundation, list in a player's subtitle
//  menu and decode in ffmpeg, in both MP4 and QuickTime files (TX3G.swift
//  has what was tried and how each other route failed). Read back from
//  `tx3g`, QuickTime `text`, `wvtt` and CEA-608 closed captions.
//

import AVFoundation
import Foundation
import SubtitleKit

extension VideoForge {

    // MARK: - Writing

    /// Adds subtitle tracks to a movie, copying every other track untouched.
    ///
    /// The picture and sound are not re-encoded: their samples are copied
    /// byte for byte, so this takes about as long as copying the file. The
    /// new tracks go into one alternate group with any the movie already
    /// has, which is what makes a player offer them in its subtitle menu.
    ///
    /// ```swift
    /// let cues = try SubtitleParser.parse(contentsOf: srt)
    /// try await VideoForge.addSubtitles([Subtitles(cues: cues, language: "en")],
    ///                                   to: clip, destination: subtitled)
    /// ```
    ///
    /// - Parameters:
    ///   - subtitles: The tracks to add, each with its language. At most
    ///     one may be the default.
    ///   - source: The movie.
    ///   - destination: Where to write — `.mp4`, `.m4v` or `.mov`.
    ///   - replacingExisting: Drop the subtitle and caption tracks the
    ///     movie already has.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What happened.
    /// - Throws: ``VideoForgeError/invalidSubtitles(_:)`` for subtitles that
    ///   cannot be written as asked, or any other ``VideoForgeError``.
    @discardableResult
    public static func addSubtitles(_ subtitles: [Subtitles], to source: URL, destination: URL,
                                    replacingExisting: Bool = false,
                                    overwrites: Bool = false) async throws -> VideoProcessResult {
        let started = Date()
        guard !subtitles.isEmpty else { throw VideoForgeError.invalidSubtitles("no subtitles to add") }
        guard subtitles.filter(\.isDefault).count <= 1 else {
            throw VideoForgeError.invalidSubtitles("only one subtitle track can be the default")
        }
        guard let container = VideoContainer.named(fileExtension: destination.pathExtension) else {
            throw VideoForgeError.invalidSubtitles("subtitle tracks go in .mp4, .m4v or .mov, not .\(destination.pathExtension)")
        }
        guard source.standardizedFileURL.resolvingSymlinksInPath()
                != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw VideoForgeError.invalidSubtitles("write to a new file — the source is read while the copy is made")
        }
        let before = try await describe(source)
        let made = try madeTracks(subtitles, within: before.duration)
        try check(destination, overwrites: overwrites)

        let plan = try await Remuxer.plan(AVURLAsset(url: source), droppingSubtitles: replacingExisting)
        _ = try await Remuxer.remux(source, copying: plan.tracks, associations: plan.associations,
                                    adding: made, to: destination, fileType: container.fileType)

        return VideoProcessResult(
            source: source, destination: destination, before: before,
            after: try await describe(destination), passedThrough: true,
            operations: [], seconds: -started.timeIntervalSinceNow)
    }

    /// The tracks to write for `subtitles` in a movie `duration` seconds
    /// long: languages checked, cues cut to the movie, samples encoded.
    static func madeTracks(_ subtitles: [Subtitles], within duration: Double) throws -> [Remuxer.MadeTrack] {
        let format = try TX3G.formatDescription()
        return try subtitles.map { track in
            guard let codes = SubtitleLanguage.codes(for: track.language) else {
                throw VideoForgeError.invalidSubtitles("'\(track.language)' is not a language code — use one like en, ja or pt-BR")
            }
            let pieces = SubtitleTimeline.pieces(of: track.cues, within: duration)
            guard pieces.contains(where: { !$0.text.isEmpty }) else {
                throw VideoForgeError.invalidSubtitles(
                    "no \(track.language) cue falls inside the video's \(String(format: "%.1f", duration)) s")
            }
            let samples = try pieces.map { piece in
                Remuxer.Sample(
                    range: CMTimeRange(start: CMTime(seconds: piece.start, preferredTimescale: 1000),
                                       end: CMTime(seconds: piece.end, preferredTimescale: 1000)),
                    data: try TX3G.encode(piece.text))
            }
            return Remuxer.MadeTrack(mediaType: .subtitle, format: format, languageCode: codes.iso639,
                                     extendedLanguageTag: codes.bcp47, isDefault: track.isDefault,
                                     samples: samples)
        }
    }

    // MARK: - Reading

    /// Every subtitle and caption track in a movie, with its cues.
    ///
    /// Overlapping cues written into a `tx3g` track come back as the pieces
    /// a viewer saw — that format cannot hold two cues at once — while
    /// `wvtt` keeps them apart. A chapter track is not a subtitle and is
    /// left out.
    ///
    /// - Parameter url: The movie.
    /// - Returns: The tracks in file order. A format this library cannot
    ///   read is listed with `isReadable` false and no cues.
    /// - Throws: ``VideoForgeError/noSubtitleTrack(_:)`` when there are
    ///   none, or any other ``VideoForgeError``.
    public static func subtitles(in url: URL) async throws -> [SubtitleTrack] {
        _ = try await describe(url)
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.load(.tracks) } catch {
            throw VideoForgeError.unreadable(url, reason: error.localizedDescription)
        }
        var chapterTracks: Set<CMPersistentTrackID> = []
        for track in tracks {
            for chapter in try await track.loadAssociatedTracks(ofType: .chapterList) {
                chapterTracks.insert(chapter.trackID)
            }
        }

        var result: [SubtitleTrack] = []
        for track in tracks where [.subtitle, .text, .closedCaption].contains(track.mediaType)
            && !chapterTracks.contains(track.trackID) {
            let (formats, language, tag, enabled) = try await track.load(
                .formatDescriptions, .languageCode, .extendedLanguageTag, .isEnabled)
            let subtype = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
            let codec = subtype.map(Probe.fourCharacterCode) ?? "?"
            let cues = try await readCues(track, codec: codec, in: asset, url: url)
            result.append(SubtitleTrack(
                trackID: Int(track.trackID),
                language: SubtitleLanguage.readable(code: language, tag: tag),
                codec: codec.trimmingCharacters(in: .whitespaces),
                isClosedCaption: track.mediaType == .closedCaption,
                isEnabled: enabled, isReadable: cues != nil, cues: cues ?? []))
        }
        guard !result.isEmpty else { throw VideoForgeError.noSubtitleTrack(url) }
        return result
    }

    /// One track's cues, or nil for a format this library cannot read.
    static func readCues(_ track: AVAssetTrack, codec: String, in asset: AVURLAsset,
                         url: URL) async throws -> [SubtitleCue]? {
        switch codec {
        case "tx3g", "text":
            let samples = try samples(of: track, in: asset, url: url)
            return SubtitleTimeline.cues(from: samples.compactMap { sample in
                TX3G.decode(sample.data).map { SubtitleTimeline.Piece(start: sample.start, end: sample.end, text: $0) }
            })
        case "wvtt":
            let samples = try samples(of: track, in: asset, url: url)
            return SubtitleTimeline.cues(fromConcurrent: samples.compactMap { sample in
                WebVTTSample.decode(sample.data).map { (sample.start, sample.end, $0) }
            })
        case "c608":
            return try await closedCaptions(of: track, in: asset, url: url)
        default:
            return nil
        }
    }

    /// The raw samples of a sparse track, with their times.
    static func samples(of track: AVAssetTrack, in asset: AVURLAsset,
                        url: URL) throws -> [(start: Double, end: Double, data: Data)] {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw VideoForgeError.unreadable(url, reason: error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else {
            throw VideoForgeError.unreadable(url, reason: reader.error?.localizedDescription ?? "the track could not be read")
        }
        var samples: [(start: Double, end: Double, data: Data)] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(buffer)
            let duration = CMSampleBufferGetDuration(buffer)
            samples.append((start.seconds, (start + duration).seconds, data))
        }
        if reader.status == .failed {
            throw VideoForgeError.unreadable(url, reason: reader.error?.localizedDescription ?? "reading the track failed")
        }
        return samples
    }

    /// CEA-608 closed captions, through AVFoundation's caption reader.
    static func closedCaptions(of track: AVAssetTrack, in asset: AVURLAsset,
                               url: URL) async throws -> [SubtitleCue] {
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let provider = reader.outputCaptionProvider(for: output)
            try reader.start()
            var cues: [SubtitleCue] = []
            while let group = try await provider.next() {
                for caption in provider.captionsNotPresentInPreviousGroups(in: group) {
                    cues.append(SubtitleCue(start: caption.timeRange.start.seconds,
                                            end: caption.timeRange.end.seconds, text: caption.text))
                }
            }
            return cues
        } catch {
            throw VideoForgeError.unreadable(url, reason: error.localizedDescription)
        }
    }
}
