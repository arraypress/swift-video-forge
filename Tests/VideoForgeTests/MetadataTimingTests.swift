//
//  MetadataTimingTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Timed metadata through a trim, a speed change and a redraw. Up to 0.6.0
//  a trim inside a metadata sample wrote the same partial edit subtitles
//  had (`elst` media time 250 for 0.25 s): ffprobe read every sample 0.25 s
//  early, and every road dropped the track's link to the video it
//  describes. A pass here means a plain edit, each sample where it plays,
//  and the link kept.
//

import AVFoundation
import XCTest
@testable import VideoForge

final class MetadataTimingTests: XCTestCase {

    var directory: URL!
    var clip: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        clip = directory.appendingPathComponent("described.mov")
        try await TestClips.writeMetadataMovie(to: clip)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The markers as they should play after `transform` moves each time:
    /// marker n covers [n/2, n/2 + 0.5) in the source.
    func expected(_ transform: (Double) -> Double, until end: Double) -> [(start: Double, end: Double, value: String)] {
        (0..<6).compactMap { index in
            let start = max(0, transform(Double(index) * 0.5))
            let stop = min(end, transform(Double(index) * 0.5 + 0.5))
            return stop > start + 0.001 ? (start, stop, "m\(index)") : nil
        }
    }

    func assertMarkers(_ url: URL, _ wanted: [(start: Double, end: Double, value: String)], _ label: String,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        XCTAssertEqual(tracks.count, 1, "\(label): metadata tracks", file: file, line: line)
        let track = try XCTUnwrap(tracks.first)

        // A plain edit: the media plays from its start, so a reader that
        // ignores edits — ffmpeg, the raw reader — reads the right times.
        let segments = try await track.load(.segments)
        XCTAssertEqual(segments.count, 1, label, file: file, line: line)
        XCTAssertEqual(segments.first?.timeMapping.source.start, .zero,
                       "\(label): the edit starts partway into the media", file: file, line: line)

        let read = try await TestClips.metadataSamples(of: url)
        XCTAssertEqual(read.map(\.value), wanted.map(\.value), label, file: file, line: line)
        for (got, want) in zip(read, wanted) {
            XCTAssertEqual(got.start, want.start, accuracy: 0.002, "\(label): \(want.value) start", file: file, line: line)
            XCTAssertEqual(got.end, want.end, accuracy: 0.002, "\(label): \(want.value) end", file: file, line: line)
        }

        let described = try await track.loadAssociatedTracks(ofType: .metadataReferent)
        XCTAssertEqual(described.map(\.mediaType), [.video], "\(label): the link to the video", file: file, line: line)
    }

    func testTheSourceReadsAsWritten() async throws {
        try await assertMarkers(clip, expected({ $0 }, until: 3), "source")
    }

    func testPassthroughTrimsCutInsideASample() async throws {
        for start in [0.25, 1.0, 1.6] {
            let trimmed = out("trim-\(start).mov")
            let result = try await VideoForge.process(clip, to: trimmed, options: .trim(.from(start)))
            XCTAssertTrue(result.passedThrough)
            try await assertMarkers(trimmed, expected({ $0 - start }, until: 3 - start), "trim \(start)")
        }
    }

    func testSpeedScalesTheMarkers() async throws {
        let fast = out("fast.mov")
        try await VideoForge.process(clip, to: fast, options: VideoProcessOptions(operations: [.speed(2)]))
        try await assertMarkers(fast, expected({ $0 / 2 }, until: 1.5), "speed 2")
    }

    func testRedrawsAndTheWriterRoadKeepThem() async throws {
        let resized = out("resized.mov")
        try await VideoForge.process(clip, to: resized, options: VideoProcessOptions(
            operations: [.trim(.from(0.25)), .resize(.height(120))]))
        try await assertMarkers(resized, expected({ $0 - 0.25 }, until: 2.75), "trim + resize")

        let written = out("written.mov")
        try await VideoForge.process(clip, to: written, options: VideoProcessOptions(
            operations: [.trim(.from(0.25))], export: ExportSpec(bitRate: 500_000)))
        try await assertMarkers(written, expected({ $0 - 0.25 }, until: 2.75), "trim on the writer road")
    }
}
