//
//  JoinSubtitleTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Subtitles through a join. Up to 0.6.0 every subtitle track was dropped
//  — it showed only in `lostTracks`. A pass here means each clip's cues
//  play where that clip plays, one track per language, in the menu.
//

import AVFoundation
import SubtitleKit
import XCTest
@testable import VideoForge

final class JoinSubtitleTests: XCTestCase {

    var directory: URL!
    var first: URL!
    var second: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        let a = directory.appendingPathComponent("a.mov"), b = directory.appendingPathComponent("b.mov")
        try await TestClips.writeMovie(to: a, seconds: 3)
        try await TestClips.writeMovie(to: b, seconds: 2, hue: 0.6, hz: 660)
        first = directory.appendingPathComponent("a-subs.mov")
        second = directory.appendingPathComponent("b-subs.mov")
        // The first clip's last cue runs past its end: it must stop there,
        // not run into the second clip.
        try await VideoForge.addSubtitles([Subtitles(cues: [
            SubtitleCue(start: 0.5, end: 1.5, text: "A one"),
            SubtitleCue(start: 2.0, end: 3.5, text: "A two"),
        ], language: "en", isDefault: true)], to: a, destination: first)
        try await VideoForge.addSubtitles([
            Subtitles(cues: [SubtitleCue(start: 0.2, end: 1.0, text: "B one")], language: "en"),
            Subtitles(cues: [SubtitleCue(start: 0.4, end: 1.2, text: "B ichi")], language: "ja"),
        ], to: b, destination: second)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func assertJoined(_ url: URL, _ label: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let tracks = try await VideoForge.subtitles(in: url)
        XCTAssertEqual(tracks.map(\.language), ["en", "ja"], label, file: file, line: line)
        let english = try XCTUnwrap(tracks.first).cues
        XCTAssertEqual(english.map(\.text), ["A one", "A two", "B one"], label, file: file, line: line)
        for (cue, (start, end)) in zip(english, [(0.5, 1.5), (2.0, 3.0), (3.2, 4.0)]) {
            XCTAssertEqual(cue.start, start, accuracy: 0.002, "\(label): \(cue.text) start", file: file, line: line)
            XCTAssertEqual(cue.end, end, accuracy: 0.002, "\(label): \(cue.text) end", file: file, line: line)
        }
        let japanese = try XCTUnwrap(tracks.last).cues
        XCTAssertEqual(japanese.map(\.text), ["B ichi"], label, file: file, line: line)
        XCTAssertEqual(japanese.first?.start ?? 0, 3.4, accuracy: 0.002, label, file: file, line: line)
        XCTAssertEqual(japanese.first?.end ?? 0, 4.2, accuracy: 0.002, label, file: file, line: line)
        // The first clip's default stays the default, and both are offered.
        XCTAssertEqual(tracks.map(\.isEnabled), [true, false], label, file: file, line: line)
        let group = try await AVURLAsset(url: url).loadMediaSelectionGroup(for: .legible)
        for code in ["en", "ja"] {
            XCTAssertTrue(group?.options.contains { $0.locale?.language.languageCode?.identifier == code } ?? false,
                          "\(label): \(code) is not in the subtitle menu", file: file, line: line)
        }
    }

    func testAJoinKeepsEachClipsSubtitlesInItsTurn() async throws {
        let joined = directory.appendingPathComponent("joined.mov")
        let result = try await VideoForge.join([first, second], to: joined)
        XCTAssertEqual(result.lostTracks, [])
        try await assertJoined(joined, "export road")
    }

    func testTheWriterRoadKeepsThemToo() async throws {
        let joined = directory.appendingPathComponent("joined-written.mp4")
        let result = try await VideoForge.join([first, second], to: joined,
                                               export: ExportSpec(bitRate: 800_000))
        XCTAssertEqual(result.lostTracks, [])
        try await assertJoined(joined, "writer road")
    }

    func testClipsWithoutSubtitlesStillJoinPlainly() async throws {
        let a = directory.appendingPathComponent("a.mov"), b = directory.appendingPathComponent("b.mov")
        let joined = directory.appendingPathComponent("plain.mov")
        try await VideoForge.join([a, b], to: joined)
        let tracks = try await AVURLAsset(url: joined).loadTracks(withMediaType: .subtitle)
        XCTAssertTrue(tracks.isEmpty)
    }

    func testDroppingSidecarsDropsThem() async throws {
        let joined = directory.appendingPathComponent("bare.mov")
        try await VideoForge.join([first, second], to: joined, export: ExportSpec(keepsSidecarTracks: false))
        let tracks = try await AVURLAsset(url: joined).loadTracks(withMediaType: .subtitle)
        XCTAssertTrue(tracks.isEmpty)
    }
}
