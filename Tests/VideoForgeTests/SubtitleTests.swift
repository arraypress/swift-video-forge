//
//  SubtitleTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Subtitle tracks in and out, on synthetic clips. What a pass means here:
//  the track reopens with its language, a player would list it (the legible
//  media-selection group), the cues read back exactly, and the picture and
//  sound are the same bytes they were.
//

import AVFoundation
import SubtitleKit
import XCTest
@testable import VideoForge

final class SubtitleTests: XCTestCase {

    var directory: URL!
    var clip: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        clip = directory.appendingPathComponent("clip.mov")
        try await TestClips.writeMovie(to: clip, seconds: 4)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Unicode in three scripts, a line break, an overlap and a cue running
    /// past the end of a four-second clip.
    let japanese = [
        SubtitleCue(start: 0, end: 1, text: "Hello, world"),
        SubtitleCue(start: 1, end: 2, text: "日本語の字幕 — مرحبا 👋"),
        SubtitleCue(start: 2, end: 3, text: "Two lines\nsecond line"),
        SubtitleCue(start: 2.5, end: 3.5, text: "Overlapping cue"),
        SubtitleCue(start: 3.5, end: 6, text: "Past the end"),
    ]
    let english = [SubtitleCue(start: 0.5, end: 2, text: "English"), SubtitleCue(start: 2, end: 3, text: "Second")]

    // MARK: - Samples

    func testTX3GRoundTripsUnicodeAndGaps() throws {
        for text in ["", "Hello", "日本語 — مرحبا 👋", "Two\nlines"] {
            XCTAssertEqual(TX3G.decode(try TX3G.encode(text)), text)
        }
        XCTAssertEqual(try TX3G.encode("").count, 2, "a gap is a zero count and nothing else")
        // UTF-16 behind a byte-order mark, which other writers use.
        let utf16 = Data([0xFE, 0xFF]) + "Hi".data(using: .utf16BigEndian)!
        XCTAssertEqual(TX3G.decode(Data([0, UInt8(utf16.count)]) + utf16), "Hi")
        // Style boxes after the text are skipped.
        XCTAssertEqual(TX3G.decode(Data([0, 2]) + Data("Hi".utf8) + Data([0, 0, 0, 8, 0x73, 0x74, 0x79, 0x6C])), "Hi")
        XCTAssertNil(TX3G.decode(Data([0])))
        XCTAssertNil(TX3G.decode(Data([0, 9, 0x41])), "a count running past the end")
        XCTAssertThrowsError(try TX3G.encode(String(repeating: "a", count: 65_536)))
    }

    func testWebVTTSamplesDecode() {
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + body.count)
            return withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + body
        }
        let cue = { (text: String) in box("vttc", box("payl", Array(text.utf8))) }
        XCTAssertEqual(WebVTTSample.decode(Data(cue("One") + cue("Two"))), ["One", "Two"])
        XCTAssertEqual(WebVTTSample.decode(Data(box("vtte", []))), [])
        XCTAssertNil(WebVTTSample.decode(Data([0, 0, 0, 99, 0x76])), "a size past the end")
    }

    // MARK: - Timeline

    func testPiecesStackOverlapsFillGapsAndCutAtTheEnd() {
        let pieces = SubtitleTimeline.pieces(of: japanese + [SubtitleCue(start: 1, end: 1, text: "zero")], within: 4)
        XCTAssertEqual(pieces.map(\.start), [0, 1, 2, 2.5, 3, 3.5])
        XCTAssertEqual(pieces.last?.end, 4, "cut at the video's end")
        XCTAssertEqual(pieces[3].text, "Two lines\nsecond line\nOverlapping cue")
        let gapped = SubtitleTimeline.pieces(of: english, within: 4)
        XCTAssertEqual(gapped.first, .init(start: 0, end: 0.5, text: ""), "a gap from zero to the first cue")
        XCTAssertTrue(SubtitleTimeline.pieces(of: [SubtitleCue(start: 5, end: 6, text: "late")], within: 4)
            .allSatisfy { $0.text.isEmpty })
    }

    func testCuesComeBackFromPieces() {
        let pieces: [SubtitleTimeline.Piece] = [
            .init(start: 0, end: 1, text: "A"), .init(start: 1, end: 2, text: "A"),
            .init(start: 2, end: 3, text: ""), .init(start: 3, end: 4, text: "B"),
        ]
        XCTAssertEqual(SubtitleTimeline.cues(from: pieces),
                       [SubtitleCue(start: 0, end: 2, text: "A"), SubtitleCue(start: 3, end: 4, text: "B")])
        let concurrent = SubtitleTimeline.cues(fromConcurrent: [
            (0, 1, ["A"]), (1, 2, ["A", "B"]), (2, 3, ["B"]), (3, 4, []),
        ])
        XCTAssertEqual(concurrent, [SubtitleCue(start: 0, end: 2, text: "A"), SubtitleCue(start: 1, end: 3, text: "B")])
    }

    // MARK: - Languages

    func testLanguagesResolveToBothCodes() {
        XCTAssertEqual(SubtitleLanguage.codes(for: "en")?.iso639, "eng")
        XCTAssertNil(SubtitleLanguage.codes(for: "en")?.bcp47)
        XCTAssertEqual(SubtitleLanguage.codes(for: "eng")?.iso639, "eng")
        XCTAssertEqual(SubtitleLanguage.codes(for: "ja")?.iso639, "jpn")
        XCTAssertEqual(SubtitleLanguage.codes(for: "pt-BR")?.iso639, "por")
        XCTAssertEqual(SubtitleLanguage.codes(for: "pt-BR")?.bcp47, "pt-BR")
        XCTAssertEqual(SubtitleLanguage.codes(for: "pt_BR")?.bcp47, "pt-BR")
        XCTAssertNotNil(SubtitleLanguage.codes(for: "zh-Hant")?.bcp47)
        for nonsense in ["", "xx", "qq", "klingon", "en us", "../en"] {
            XCTAssertNil(SubtitleLanguage.codes(for: nonsense), nonsense)
        }
        XCTAssertEqual(SubtitleLanguage.fromFileName(URL(fileURLWithPath: "/m/film.ja.srt")), "ja")
        XCTAssertEqual(SubtitleLanguage.fromFileName(URL(fileURLWithPath: "/m/film.pt-BR.vtt")), "pt-BR")
        XCTAssertNil(SubtitleLanguage.fromFileName(URL(fileURLWithPath: "/m/film.srt")))
        XCTAssertNil(SubtitleLanguage.fromFileName(URL(fileURLWithPath: "/m/my.film.final.srt")))
        XCTAssertEqual(SubtitleLanguage.readable(code: "jpn", tag: nil), "ja")
        XCTAssertEqual(SubtitleLanguage.readable(code: "por", tag: "pt-BR"), "pt-BR")
        XCTAssertNil(SubtitleLanguage.readable(code: "und", tag: nil))
    }

    // MARK: - End to end

    func testAddedTracksReadBackAndPlayersWouldListThem() async throws {
        for ext in ["mov", "mp4"] {
            let destination = out("subtitled.\(ext)")
            let result = try await VideoForge.addSubtitles(
                [Subtitles(cues: japanese, language: "ja"), Subtitles(cues: english, language: "en", isDefault: true)],
                to: clip, destination: destination)
            XCTAssertTrue(result.passedThrough)
            XCTAssertEqual(result.after.duration, result.before.duration, accuracy: 0.01, ext)

            let tracks = try await VideoForge.subtitles(in: destination)
            XCTAssertEqual(tracks.map(\.language), ["ja", "en"], ext)
            XCTAssertEqual(tracks.map(\.codec), ["tx3g", "tx3g"])
            XCTAssertEqual(tracks.map(\.isEnabled), [false, true], "only the default shows unasked")
            XCTAssertEqual(tracks[0].cues.map(\.text), [
                "Hello, world", "日本語の字幕 — مرحبا 👋", "Two lines\nsecond line",
                "Two lines\nsecond line\nOverlapping cue", "Overlapping cue", "Past the end",
            ], ext)
            XCTAssertEqual(tracks[0].cues.last?.end ?? 0, 4, accuracy: 0.001, "cut at the end")
            XCTAssertEqual(tracks[1].cues, english, ext)

            let group = try await AVURLAsset(url: destination).loadMediaSelectionGroup(for: .legible)
            let offered = try XCTUnwrap(group, "no subtitle menu in \(ext)").options
            XCTAssertTrue(offered.contains { $0.locale?.language.languageCode == "ja" }, ext)
            XCTAssertTrue(offered.contains { $0.locale?.language.languageCode == "en" }, ext)
        }
    }

    func testPictureAndSoundAreCopiedByteForByte() async throws {
        let destination = out("subtitled.mov")
        try await VideoForge.addSubtitles([Subtitles(cues: english, language: "en")], to: clip, destination: destination)
        for type in [AVMediaType.video, .audio] {
            let before = try await bytes(of: type, in: clip)
            let after = try await bytes(of: type, in: destination)
            XCTAssertFalse(before.isEmpty)
            XCTAssertEqual(before, after, "\(type.rawValue) was not copied untouched")
        }
    }

    func testAddingKeepsOrReplacesTheTracksAlreadyThere() async throws {
        let first = out("first.mp4"), both = out("both.mp4"), replaced = out("replaced.mp4")
        try await VideoForge.addSubtitles([Subtitles(cues: english, language: "en")], to: clip, destination: first)
        try await VideoForge.addSubtitles([Subtitles(cues: japanese, language: "pt-BR")], to: first, destination: both)
        let kept = try await VideoForge.subtitles(in: both)
        XCTAssertEqual(kept.map(\.language), ["en", "pt-BR"])
        let group = try await AVURLAsset(url: both).loadMediaSelectionGroup(for: .legible)
        XCTAssertGreaterThanOrEqual(group?.options.count ?? 0, 2, "the old and new tracks are one group")

        try await VideoForge.addSubtitles([Subtitles(cues: japanese, language: "ja")], to: both,
                                          destination: replaced, replacingExisting: true)
        let replacedLanguages = try await VideoForge.subtitles(in: replaced).map(\.language)
        XCTAssertEqual(replacedLanguages, ["ja"])
    }

    func testRefusalsSayWhy() async throws {
        let destination = out("x.mp4")
        let cases: [(String, [Subtitles], URL)] = [
            ("nothing inside", [Subtitles(cues: [SubtitleCue(start: 9, end: 10, text: "late")], language: "en")], destination),
            ("bad language", [Subtitles(cues: english, language: "klingon")], destination),
            ("two defaults", [Subtitles(cues: english, language: "en", isDefault: true),
                              Subtitles(cues: english, language: "fr", isDefault: true)], destination),
            ("no tracks", [], destination),
            ("wrong container", [Subtitles(cues: english, language: "en")], out("x.gif")),
            ("over the source", [Subtitles(cues: english, language: "en")], clip),
        ]
        for (name, subtitles, target) in cases {
            do {
                try await VideoForge.addSubtitles(subtitles, to: clip, destination: target, overwrites: true)
                XCTFail("\(name) was accepted")
            } catch VideoForgeError.invalidSubtitles {
            } catch { XCTFail("\(name): \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        do {
            _ = try await VideoForge.subtitles(in: clip)
            XCTFail("a clip without subtitles listed some")
        } catch VideoForgeError.noSubtitleTrack {}
    }

    func testCancellingLeavesNoFile() async throws {
        let destination = out("cancelled.mov")
        let task = Task { [clip, english] in
            try await VideoForge.addSubtitles([Subtitles(cues: english, language: "en")], to: clip!, destination: destination)
        }
        task.cancel()
        do {
            _ = try await task.value
            // Finishing before the cancel landed is allowed; a half-written file is not.
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    // MARK: - Reading what others write

    func testWebVTTTracksReadBackWithOverlapsApart() async throws {
        let file = out("vtt.mp4")
        try await writeWebVTTTrack(to: file)
        let read = try await VideoForge.subtitles(in: file)
        let track = try XCTUnwrap(read.first)
        XCTAssertEqual(track.codec, "wvtt")
        XCTAssertEqual(track.cues, [
            SubtitleCue(start: 0, end: 2, text: "First"),
            SubtitleCue(start: 1, end: 3, text: "Second"),
        ])
    }

    func testClosedCaptionsReadBack() async throws {
        let file = out("cc.mov")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .closedCaption, outputSettings: nil)
        input.languageCode = "en"
        writer.add(input)
        let receiver = writer.inputCaptionReceiver(for: input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for (start, end, text) in [(0.5, 1.5, "Hello"), (2.0, 3.0, "World")] {
            try await receiver.append(AVCaption(text, timeRange: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))))
        }
        receiver.finish()
        await writer.finishWriting()
        let read = try await VideoForge.subtitles(in: file)
        let track = try XCTUnwrap(read.first)
        XCTAssertTrue(track.isClosedCaption)
        XCTAssertEqual(track.codec, "c608")
        XCTAssertEqual(track.cues.map(\.text), ["Hello", "World"])
        // CEA-608 sends two characters a frame, so a caption is painted on
        // slightly late; the times land within a fifth of a second.
        XCTAssertEqual(track.cues[1].start, 2.0, accuracy: 0.2)
    }

    // MARK: - Helpers

    /// Every sample of the first track of a type, concatenated.
    func bytes(of type: AVMediaType, in url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: type)
        let track = try XCTUnwrap(tracks.first)
        return try VideoForge.samples(of: track, in: asset, url: url).reduce(into: Data()) { $0.append($1.data) }
    }

    /// A subtitle-only MP4 with a `wvtt` track: "First" 0–2 and "Second"
    /// 1–3, overlapping, written as ISO 14496-30 samples.
    func writeWebVTTTrack(to url: URL) async throws {
        func box(_ type: String, _ body: Data) -> Data {
            var size = UInt32(8 + body.count).bigEndian
            return Data(bytes: &size, count: 4) + Data(type.utf8) + body
        }
        let cue = { (text: String) in box("vttc", box("payl", Data(text.utf8))) }
        var format: CMFormatDescription?
        CMFormatDescriptionCreate(
            allocator: nil, mediaType: kCMMediaType_Subtitle, mediaSubType: kCMSubtitleFormatType_WebVTT,
            extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vttC": Data("WEBVTT".utf8)]]
                as CFDictionary, formatDescriptionOut: &format)
        let description = try XCTUnwrap(format)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: description)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for (start, end, data) in [(0.0, 1.0, cue("First")), (1.0, 2.0, cue("First") + cue("Second")),
                                   (2.0, 3.0, cue("Second"))] {
            let sample = Remuxer.Sample(range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000),
                                                           end: CMTime(seconds: end, preferredTimescale: 1000)),
                                        data: data)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(input.append(try XCTUnwrap(Remuxer.sampleBuffer(sample, format: description))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
