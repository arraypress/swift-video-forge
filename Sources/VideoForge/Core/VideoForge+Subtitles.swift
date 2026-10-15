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

        let plan = try await Remuxer.plan(AVURLAsset(url: source),
                                            dropping: replacingExisting ? Remuxer.subtitleTypes : [])
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
        try subtitles.map { track in
            guard let codes = SubtitleLanguage.codes(for: track.language) else {
                throw VideoForgeError.invalidSubtitles("'\(track.language)' is not a language code — use one like en, ja or pt-BR")
            }
            guard let made = try madeTrack(track.cues, codes: codes, isDefault: track.isDefault, within: duration) else {
                throw VideoForgeError.invalidSubtitles(
                    "no \(track.language) cue falls inside the video's \(String(format: "%.1f", duration)) s")
            }
            return made
        }
    }

    /// One tx3g track for `cues` in a movie `duration` seconds long, or nil
    /// when no cue falls inside it.
    static func madeTrack(_ cues: [SubtitleCue], codes: (iso639: String, bcp47: String?)?, isDefault: Bool,
                          within duration: Double) throws -> Remuxer.MadeTrack? {
        let pieces = SubtitleTimeline.pieces(of: cues, within: duration)
        guard pieces.contains(where: { !$0.text.isEmpty }) else { return nil }
        let samples = try pieces.map { piece in
            Remuxer.Sample(
                range: CMTimeRange(start: CMTime(seconds: piece.start, preferredTimescale: 1000),
                                   end: CMTime(seconds: piece.end, preferredTimescale: 1000)),
                data: try TX3G.encode(piece.text))
        }
        return Remuxer.MadeTrack(mediaType: .subtitle, format: try TX3G.formatDescription(),
                                 languageCode: codes?.iso639, extendedLanguageTag: codes?.bcp47,
                                 isDefault: isDefault, samples: samples)
    }

    /// The subtitle tracks of clips joined end to end: each clip's cues
    /// moved to where the clip starts, cut at its end, and laid in one track
    /// per language — a clip with no track in a language leaves that track
    /// empty for its length. A clip's second English track joins the
    /// others' second English track.
    ///
    /// Up to 0.6.0 a join dropped every subtitle track (it showed only in
    /// `lostTracks`). The cues are read and written again as tx3g, so a
    /// track's styling is not kept; its text and timing are.
    ///
    /// - Parameters:
    ///   - sources: The clips, in order.
    ///   - container: The container being written.
    /// - Returns: The tracks; none when no clip has a readable track.
    /// - Throws: ``VideoForgeError`` when a clip's track cannot be read.
    static func joinedSubtitles(_ sources: [URL], container: VideoContainer) async throws -> [Remuxer.MadeTrack] {
        guard container.holdsSubtitles else { return [] }
        struct Lane {
            let language: String?
            let isClosedCaption: Bool
            let ordinal: Int
            var cues: [SubtitleCue]
            let isEnabled: Bool
        }
        var lanes: [Lane] = []
        var offset = 0.0
        for source in sources {
            let length = try await AVURLAsset(url: source).load(.duration).seconds
            let tracks: [SubtitleTrack]
            do { tracks = try await subtitles(in: source) } catch VideoForgeError.noSubtitleTrack { tracks = [] }
            var seen: [String: Int] = [:]
            for track in tracks where track.isReadable {
                let key = "\(track.language ?? "")|\(track.isClosedCaption)"
                let ordinal = seen[key, default: 0]
                seen[key] = ordinal + 1
                let moved = track.cues.filter { $0.start < length }.map {
                    SubtitleCue(start: $0.start + offset, end: min($0.end, length) + offset, text: $0.text)
                }
                if let index = lanes.firstIndex(where: {
                    $0.language == track.language && $0.isClosedCaption == track.isClosedCaption && $0.ordinal == ordinal
                }) {
                    lanes[index].cues += moved
                } else {
                    lanes.append(Lane(language: track.language, isClosedCaption: track.isClosedCaption,
                                      ordinal: ordinal, cues: moved, isEnabled: track.isEnabled))
                }
            }
            offset += length
        }
        // One default at most: the first track any clip showed unasked.
        let preferred = lanes.firstIndex(where: \.isEnabled)
        return try lanes.enumerated().compactMap { index, lane in
            try madeTrack(lane.cues, codes: lane.language.flatMap(SubtitleLanguage.codes(for:)),
                          isDefault: index == preferred, within: offset)
        }
    }

    // MARK: - Carrying through a job

    /// Takes the subtitle and timed-metadata tracks out of a composition
    /// and returns them as tracks to write from samples, each sample cut and
    /// re-timed through the composition's edits — a trim, a speed change.
    ///
    /// Why not leave them in: a composition export cannot cut a sample, so
    /// a trim inside one writes an edit list that ffmpeg and
    /// `AVAssetReader` misread by the length of the cut (SubtitleRetiming).
    /// And a re-encoding export drops subtitle tracks altogether.
    ///
    /// MEASURED (0.7.0): timed metadata has the same fault. One 0.5 s
    /// sample every half second, trimmed 0.25 s in: AVPlayer and the
    /// metadata adaptor read each sample where it was, ffprobe put every
    /// one 0.25 s early (`elst` media time 250 again); trimmed 1.6 s in, 0.4 s
    /// early. A trim on a sample boundary, and a speed change, read right.
    /// Every road lost the track's link to the video it describes, too
    /// (`cdsc`); a made track is linked to the written video again.
    ///
    /// - Parameters:
    ///   - composition: The composition, built from `asset`. Its subtitle
    ///     and metadata tracks are removed.
    ///   - asset: The source the composition reads.
    ///   - url: The source's file, for errors.
    /// - Returns: The tracks, subtitles first, each kind in the
    ///   composition's order.
    /// - Throws: ``VideoForgeError/unreadable(_:reason:)`` when a track
    ///   cannot be read.
    static func detachSparseTracks(from composition: AVMutableComposition, of asset: AVURLAsset,
                                   url: URL) async throws -> [Remuxer.MadeTrack] {
        var made: [Remuxer.MadeTrack] = []
        for mediaType in [AVMediaType.subtitle, .metadata] {
            for track in composition.tracks(withMediaType: mediaType) {
                let segments = track.segments ?? []
                composition.removeTrack(track)
                guard let sourceID = segments.first(where: { !$0.isEmpty })?.sourceTrackID,
                      let source = try await asset.loadTrack(withTrackID: sourceID) else { continue }
                let (formats, language, tag, enabled, timescale) = try await source.load(
                    .formatDescriptions, .languageCode, .extendedLanguageTag, .isEnabled, .naturalTimeScale)
                guard let format = formats.first else { continue }
                // The raw reader hands metadata back in media time too, edit
                // ignored — measured on a trimmed file — so both kinds are
                // read the same way.
                var samples = SubtitleRetiming.retime(
                    try await samples(of: source, in: asset, url: url),
                    through: segments.map { SubtitleRetiming.Segment($0) },
                    timescale: timescale > 0 ? timescale : 1000)
                // A tx3g track is given a gap sample from zero rather than an
                // empty edit; other formats keep what they have.
                if CMFormatDescriptionGetMediaSubType(format) == kCMSubtitleFormatType_3GText {
                    samples = SubtitleRetiming.filledFromZero(samples, gap: try TX3G.encode(""))
                }
                guard !samples.isEmpty else { continue }
                let describesVideo = mediaType == .metadata
                    ? try await source.loadAssociatedTracks(ofType: .metadataReferent)
                        .contains { $0.mediaType == .video }
                    : false
                made.append(Remuxer.MadeTrack(
                    mediaType: mediaType, format: format,
                    languageCode: language.flatMap { $0 == "und" ? nil : $0 },
                    extendedLanguageTag: tag, isDefault: enabled, samples: samples,
                    describesVideo: describesVideo))
            }
        }
        return made
    }

    // MARK: - Languages

    /// Whether a subtitle track can declare this language — `en`, `eng`,
    /// `pt-BR`, `zh-Hant` — so a caller can refuse a bad one before reading
    /// a file.
    public static func isSubtitleLanguage(_ code: String) -> Bool {
        SubtitleLanguage.codes(for: code) != nil
    }

    /// The language tag in a subtitle file's name — `film.ja.srt` gives
    /// `ja`, `film.pt-BR.vtt` gives `pt-BR` — or nil when it has none.
    public static func subtitleLanguage(inFileName url: URL) -> String? {
        SubtitleLanguage.fromFileName(url)
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
            let samples = try await samples(of: track, in: asset, url: url)
            return SubtitleTimeline.cues(from: samples.compactMap { sample in
                TX3G.decode(sample.data).map {
                    SubtitleTimeline.Piece(start: sample.range.start.seconds, end: sample.range.end.seconds, text: $0)
                }
            })
        case "wvtt":
            let samples = try await samples(of: track, in: asset, url: url)
            return SubtitleTimeline.cues(fromConcurrent: samples.compactMap { sample in
                WebVTTSample.decode(sample.data).map { (sample.range.start.seconds, sample.range.end.seconds, $0) }
            })
        case "c608":
            return try await closedCaptions(of: track, in: asset, url: url)
        default:
            return nil
        }
    }

    /// The samples of a sparse track, with the times they PLAY at.
    ///
    /// `AVAssetReaderTrackOutput` gives a subtitle track's samples in media
    /// time, its edit list ignored — a track trimmed 0.25 s into a sample
    /// read 0.25 s late — so the times are put through the track's edits
    /// here (see SubtitleRetiming).
    static func samples(of track: AVAssetTrack, in asset: AVURLAsset,
                        url: URL) async throws -> [Remuxer.Sample] {
        let (segments, timescale) = try await track.load(.segments, .naturalTimeScale)
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw VideoForgeError.unreadable(url, reason: error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else {
            throw VideoForgeError.unreadable(url, reason: reader.error?.localizedDescription ?? "the track could not be read")
        }
        var samples: [Remuxer.Sample] = []
        while let buffer = output.copyNextSampleBuffer() {
            // The reader also hands back empty marker buffers — the edit's
            // start, the track's end — which carry no text.
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(buffer)
            let duration = CMSampleBufferGetDuration(buffer)
            guard start.isNumeric, duration.isNumeric else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { continue }
            samples.append(Remuxer.Sample(range: CMTimeRange(start: start, duration: duration), data: data))
        }
        if reader.status == .failed {
            throw VideoForgeError.unreadable(url, reason: reader.error?.localizedDescription ?? "reading the track failed")
        }
        return SubtitleRetiming.retime(samples, through: segments.map { SubtitleRetiming.Segment($0) },
                                       timescale: timescale > 0 ? timescale : 1000)
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
