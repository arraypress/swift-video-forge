//
//  SubtitleTimingTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Subtitles through a trim, a speed change and a redraw. Up to 0.5.0 a
//  trim that cut inside a subtitle sample wrote an edit list ffmpeg read
//  0.5–0.75 s early and AVAssetReader read late by the cut; a re-encode
//  dropped the track; a passthrough trim left it outside any alternate
//  group, so players hid it. A pass here means the cues read back at the
//  times they play, from a track with nothing for a reader to misread.
//

import AVFoundation
import SubtitleKit
import XCTest
@testable import VideoForge

final class SubtitleTimingTests: XCTestCase {

    var directory: URL!
    var subtitled: URL!

    /// Cues away from every trim point, so each trim cuts inside a sample.
    let cues = [
        SubtitleCue(start: 1, end: 2, text: "one"),
        SubtitleCue(start: 3, end: 4, text: "three"),
        SubtitleCue(start: 4.5, end: 5.5, text: "four and a half"),
    ]

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        let clip = directory.appendingPathComponent("clip.mov")
        try await TestClips.writeMovie(to: clip, seconds: 6)
        subtitled = directory.appendingPathComponent("subtitled.mp4")
        try await VideoForge.addSubtitles([Subtitles(cues: cues, language: "en")], to: clip, destination: subtitled)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The cues as they should play after `transform` moves every time.
    func expected(_ transform: (Double) -> Double) -> [SubtitleCue] {
        cues.compactMap { cue in
            let end = transform(cue.end)
            guard end > 0 else { return nil }
            return SubtitleCue(start: max(0, transform(cue.start)), end: end, text: cue.text)
        }
    }

    func assertCues(_ url: URL, _ wanted: [SubtitleCue], _ label: String,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let tracks = try await VideoForge.subtitles(in: url)
        XCTAssertEqual(tracks.count, 1, label, file: file, line: line)
        let read = try XCTUnwrap(tracks.first).cues
        XCTAssertEqual(read.map(\.text), wanted.map(\.text), label, file: file, line: line)
        for (got, want) in zip(read, wanted) {
            XCTAssertEqual(got.start, want.start, accuracy: 0.002, "\(label): \(want.text) start", file: file, line: line)
            XCTAssertEqual(got.end, want.end, accuracy: 0.002, "\(label): \(want.text) end", file: file, line: line)
        }

        // Nothing for a reader to misread: the track's edit starts at the
        // start of its media, as plain as an edit gets.
        let asset = AVURLAsset(url: url)
        let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
        let track = try XCTUnwrap(subtitleTracks.first)
        let segments = try await track.load(.segments)
        XCTAssertEqual(segments.count, 1, label, file: file, line: line)
        XCTAssertEqual(segments.first?.timeMapping.source.start, .zero,
                       "\(label): the edit starts partway into the media", file: file, line: line)
        // And a player offers it.
        let group = try await asset.loadMediaSelectionGroup(for: .legible)
        XCTAssertTrue(group?.options.contains { $0.locale?.language.languageCode == "en" } ?? false,
                      "\(label): not in the subtitle menu", file: file, line: line)
    }

    // MARK: - The bug: a trim

    func testTrimsMoveTheCuesByExactlyTheCut() async throws {
        for cut in [0.25, 1.0, 2.5] {
            let destination = out("trim-\(cut).mp4")
            let result = try await VideoForge.process(subtitled, to: destination,
                                                      options: .trim(.from(cut)))
            XCTAssertTrue(result.passedThrough, "the copy for the subtitles keeps the trim lossless")
            XCTAssertEqual(result.lostTracks, [])
            try await assertCues(destination, expected { $0 - cut }, "trim \(cut)")
        }
    }

    func testATrimEndingMidCueCutsTheCue() async throws {
        let destination = out("between.mp4")
        try await VideoForge.process(subtitled, to: destination, options: .trim(.between(1.5, 3.5)))
        try await assertCues(destination, [SubtitleCue(start: 0, end: 0.5, text: "one"),
                                           SubtitleCue(start: 1.5, end: 2, text: "three")], "between")
    }

    // MARK: - Every other road

    func testTheWriterRoadTimesThemTheSame() async throws {
        let destination = out("bitrate.mp4")
        try await VideoForge.process(subtitled, to: destination, options: VideoProcessOptions(
            operations: [.trim(.from(0.25))], export: ExportSpec(bitRate: 2_000_000)))
        try await assertCues(destination, expected { $0 - 0.25 }, "writer road")
    }

    func testARedrawKeepsTheSubtitles() async throws {
        let destination = out("cropped.mp4")
        let result = try await VideoForge.process(subtitled, to: destination, options: VideoProcessOptions(
            operations: [.trim(.from(0.25)), .crop(x: 0, y: 0, width: 160, height: 120)]))
        XCTAssertEqual(result.lostTracks, [], "a re-encode used to drop the subtitle track")
        try await assertCues(destination, expected { $0 - 0.25 }, "redraw")
    }

    func testASpeedChangeScalesTheCues() async throws {
        for (rate, muted) in [(2.0, false), (2.0, true), (0.5, false)] {
            let destination = out("speed-\(rate)-\(muted).mp4")
            try await VideoForge.process(subtitled, to: destination, options: VideoProcessOptions(
                operations: [.speed(rate)], export: ExportSpec(keepsAudio: !muted)))
            try await assertCues(destination, expected { $0 / rate }, "speed \(rate) muted \(muted)")
        }
    }

    // MARK: - Reading a track with an edit

    /// A file written the 0.5.0 way — a passthrough export of a trimmed
    /// composition, subtitle track and all — keeps its edit 0.25 s into a
    /// sample. Read through the edit, its cues come back as they play.
    func testATrackWithAnEditReadsAsItPlays() async throws {
        let asset = AVURLAsset(url: subtitled)
        let composition = try await Composer.build(from: asset, operations: [.trim(.from(0.25))],
                                                   keepsAudio: true, keepsSidecarTracks: true)
        let old = out("edited.mp4")
        try await Composer.export(composition, to: old, container: .mp4, preset: AVAssetExportPresetPassthrough)
        let oldTracks = try await AVURLAsset(url: old).loadTracks(withMediaType: .subtitle)
        let track = try XCTUnwrap(oldTracks.first)
        let segments = try await track.load(.segments)
        XCTAssertEqual(segments.first?.timeMapping.source.start.seconds ?? 0, 0.25, accuracy: 0.001,
                       "the export no longer writes the edit this test is about")

        let readTracks = try await VideoForge.subtitles(in: old)
        let read = try XCTUnwrap(readTracks.first).cues
        XCTAssertEqual(read.map(\.text), cues.map(\.text))
        XCTAssertEqual(read.first?.start ?? 0, 0.75, accuracy: 0.002, "read in media time, edit ignored")
        XCTAssertEqual(read.last?.end ?? 0, 5.25, accuracy: 0.002)
    }

    // MARK: - The arithmetic

    func sample(_ start: Double, _ end: Double, _ text: String) -> Remuxer.Sample {
        Remuxer.Sample(range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000),
                                          end: CMTime(seconds: end, preferredTimescale: 1000)),
                       data: Data(text.utf8))
    }

    func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }

    func times(_ samples: [Remuxer.Sample]) -> [String] {
        samples.map { String(format: "%.3f-%.3f %@", $0.range.start.seconds, $0.range.end.seconds,
                             String(decoding: $0.data, as: UTF8.self)) }
    }

    func testRetimingCutsMovesAndScales() {
        let samples = [sample(0, 1, ""), sample(1, 2, "one"), sample(2, 3, ""), sample(3, 4, "three")]
        // A trim from 0.25 to 3.5: the first and last samples cut.
        XCTAssertEqual(times(SubtitleRetiming.retime(
            samples, through: [.init(source: range(0.25, 3.5), target: range(0, 3.25))], timescale: 1000)),
            ["0.000-0.750 ", "0.750-1.750 one", "1.750-2.750 ", "2.750-3.250 three"])
        // Twice as fast.
        XCTAssertEqual(times(SubtitleRetiming.retime(
            samples, through: [.init(source: range(1, 4), target: range(0, 1.5))], timescale: 1000)),
            ["0.000-0.500 one", "0.500-1.000 ", "1.000-1.500 three"])
        // An empty edit passes time and reads nothing; a later one reads on.
        XCTAssertEqual(times(SubtitleRetiming.retime(
            samples, through: [.init(source: nil, target: range(0, 1)),
                               .init(source: range(3, 4), target: range(1, 2))], timescale: 1000)),
            ["1.000-2.000 three"])
    }

    func testAGapIsFilledFromZero() {
        let filled = SubtitleRetiming.filledFromZero([sample(1, 2, "one")], gap: Data("gap".utf8))
        XCTAssertEqual(times(filled), ["0.000-1.000 gap", "1.000-2.000 one"])
        XCTAssertEqual(times(SubtitleRetiming.filledFromZero([sample(0, 1, "x")], gap: Data())), ["0.000-1.000 x"])
    }
}
