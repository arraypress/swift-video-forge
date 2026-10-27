//
//  ComposeTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Whole edits. The rules first, with no file; then real renders of flat-
//  coloured clips, read back frame by frame: which clip is on screen when,
//  where it sits in a frame of another shape, what an overlay and a drawing
//  cover, how long the result is, and that music goes in without the
//  picture being encoded a second time.
//

import AVFoundation
import CoreGraphics
import XCTest
@testable import VideoForge

final class ComposeRulesTests: XCTestCase {

    let file = URL(fileURLWithPath: "/clips/a.mov")

    func lengths(_ clips: [Double], overlays: [Double] = [], voices: [Double] = []) -> EditRules.Lengths {
        EditRules.Lengths(clips: clips, clipsHaveVideo: clips.map { _ in true }, overlays: overlays, voices: voices)
    }

    func testClipsLandEndToEnd() {
        let clips = [EditClip(file, from: 1, to: 3), EditClip(file, from: 0.5), EditClip(file, to: 1)]
        let ranges = EditRules.clipRanges(clips, lengths: [10, 4, 2])
        XCTAssertEqual(ranges, [0...2, 2...5.5, 5.5...6.5])
        XCTAssertEqual(EditRules.duration(of: clips, lengths: [10, 4, 2]), 6.5)
    }

    func testEveryProblemIsNamedByItsPlace() {
        var edit = EditTimeline(clips: [EditClip(file, from: 1, to: 0.5), EditClip(file, from: 9)])
        edit.overlays = [EditOverlay(file, start: 50, corner: .auto)]
        edit.voices = [EditSound(file, start: -1, volume: 3)]
        edit.size = CGSize(width: 1081, height: 1920)
        let problems = EditRules.problems(in: edit, lengths: lengths([5, 5], overlays: [3], voices: [2]))
        for place in ["clips[0].to", "clips[1].from", "overlays[0].corner", "overlays[0].start", "voices[0].start",
                      "voices[0].volume", "size"] {
            XCTAssert(problems.contains { $0.hasPrefix(place + ":") }, "\(place) missing from \(problems)")
        }
        XCTAssertEqual(EditRules.problems(in: EditTimeline(clips: [EditClip(file)]), lengths: lengths([5])), [])
        XCTAssertEqual(EditRules.problems(in: EditTimeline(clips: []), lengths: lengths([])),
                       ["clips: an edit needs at least one clip"])
    }

    func testFadesLongerThanTheClipAreRefused() {
        let edit = EditTimeline(clips: [EditClip(file, to: 1, fadeIn: 0.6, fadeOut: 0.6)])
        XCTAssertEqual(EditRules.problems(in: edit, lengths: lengths([5])).count, 1)
    }

    func testFillCoversAroundTheFocusAndFitShowsAll() {
        let landscape = CGSize(width: 1920, height: 1080), vertical = CGSize(width: 1080, height: 1920)
        let centre = EditRules.placement(of: landscape, in: vertical, fit: .fill, focus: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(centre.height, 1920, accuracy: 0.01)
        XCTAssertEqual(centre.midX, 540, accuracy: 0.01, "centred")
        let left = EditRules.placement(of: landscape, in: vertical, fit: .fill, focus: CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(left.minX, 0, accuracy: 0.01, "a focus at the edge stops at the edge, no black")
        let right = EditRules.placement(of: landscape, in: vertical, fit: .fill, focus: CGPoint(x: 0.75, y: 0.5))
        XCTAssertEqual(right.minX + 0.75 * right.width, 540, accuracy: 0.01, "the focus point is centred")
        let fit = EditRules.placement(of: landscape, in: vertical, fit: .fit, focus: .zero)
        XCTAssertEqual(fit, CGRect(x: 0, y: 656.25, width: 1080, height: 607.5))
    }

    func testOverlayRectSharesFitInsideTheirBox() {
        let overlay = EditOverlay(file, start: 0, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let rect = EditRules.overlayRect(overlay, frame: CGSize(width: 1000, height: 1000), source: CGSize(width: 400, height: 200))
        XCTAssertEqual(rect, CGRect(x: 500, y: 125, width: 500, height: 250))
    }

    func testDipsToBlack() {
        let range = 2.0...4.0
        XCTAssertEqual(EditRules.brightness(at: 3, range: range, fadeIn: 0.5, fadeOut: 0.5, frameDuration: 0.04), 1)
        XCTAssertEqual(EditRules.brightness(at: 2, range: range, fadeIn: 0.5, fadeOut: 0, frameDuration: 0.1), 0.2, accuracy: 1e-9,
                       "the first frame of a fade-in is lit as at its end")
        XCTAssertEqual(EditRules.brightness(at: 3.75, range: range, fadeIn: 0, fadeOut: 0.5, frameDuration: 0.04), 0.5, accuracy: 1e-9)
    }

    func testInstructionsCutAtEveryEdge() {
        XCTAssertEqual(EditRules.edges(clips: [0...2, 2...5], overlays: [1...3, 4.5...9], total: 5), [0, 1, 2, 3, 4.5, 5])
    }
}

final class ComposeTests: XCTestCase {

    var directory: URL!
    var red: URL!
    var blue: URL!

    static func flat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> @Sendable (CGContext, Int) -> Void {
        { context, _ in
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        red = directory.appendingPathComponent("red.mov")
        blue = directory.appendingPathComponent("blue.mov")
        try await TestClips.writeDrawnMovie(to: red, seconds: 3, hz: 440, draw: Self.flat(0.9, 0.1, 0.1))
        try await TestClips.writeDrawnMovie(to: blue, seconds: 3, hz: 880, draw: Self.flat(0.1, 0.2, 0.9))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func frame(_ frames: [DecodedFrame], at time: Double) throws -> DecodedFrame {
        try XCTUnwrap(frames.min { abs($0.time - time) < abs($1.time - time) })
    }

    func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 170 && p.b < 90 }
    func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 170 && p.r < 90 }

    func testAnEditRendersItsClipsInOrderInItsOwnFrame() async throws {
        var edit = EditTimeline(clips: [EditClip(red, from: 0.5, to: 1.5), EditClip(blue, to: 1, fit: .blur)])
        edit.size = CGSize(width: 360, height: 640)
        // A white band across the top from 0.2 s to 1.8 s.
        edit.drawings = [EditDrawing(start: 0.2, end: 1.8) { _, frame in
            let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: frame.height - 40, width: frame.width, height: 40))
            return context.makeImage()
        }]
        let out = directory.appendingPathComponent("edit.mov")
        let done = try await VideoForge.compose(edit, to: out)
        XCTAssertEqual(done.clips, [0...1, 1...2])
        XCTAssertEqual(done.result.after.width, 360)
        XCTAssertEqual(done.result.after.height, 640)
        XCTAssertEqual(done.result.after.duration, 2, accuracy: 0.05)
        XCTAssertNil(done.soundtrack)

        let frames = try await TestClips.decodedFrames(of: out)
        let early = try frame(frames, at: 0.5), late = try frame(frames, at: 1.5)
        XCTAssert(isRed(early.rgb(180, 320)), "red is on first: \(early.rgb(180, 320))")
        XCTAssert(isBlue(late.rgb(180, 320)), "blue second: \(late.rgb(180, 320))")
        XCTAssertGreaterThan(early.rgb(180, 10).g, 230, "the drawing is on top at 0.5 s")
        XCTAssertLessThan(try frame(frames, at: 1.95).rgb(180, 10).g, 200, "and gone after 1.8 s")
        // Red fills a vertical frame (no black at its top); blue is fitted
        // over a blurred copy of itself (blue-ish, not black, above it).
        XCTAssert(isRed(early.rgb(180, 100)), "fill leaves no bars")
        XCTAssertGreaterThan(late.rgb(180, 100).b, 60, "blur fills the bars with the picture, not black: \(late.rgb(180, 100))")
        let audio = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "the clips' sound comes along")
    }

    func testOverlaysWithAlphaShowTheClipThrough() async throws {
        let alpha = directory.appendingPathComponent("alpha.mov")
        try await TestClips.writeAlphaVideo(to: alpha, seconds: 1)
        var edit = EditTimeline(clips: [EditClip(blue, to: 2)])
        edit.overlays = [EditOverlay(alpha, start: 0.5, end: 1.5, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))]
        let out = directory.appendingPathComponent("overlay.mov")
        try await VideoForge.compose(edit, to: out)
        let frames = try await TestClips.decodedFrames(of: out)
        let shown = try frame(frames, at: 1), before = try frame(frames, at: 0.2)
        XCTAssertNotEqual(shown.rgb(80, 180).b, before.rgb(80, 180).b, "the opaque half covers the clip")
        XCTAssert(isBlue(before.rgb(500, 180)), "outside it, the clip")
    }

    func testAnOverlayPlaysFromItsOwnStartAtItsTime() async throws {
        // Green for its first half second, magenta after.
        let changing = directory.appendingPathComponent("changing.mov")
        try await TestClips.writeDrawn(to: changing, seconds: 1, width: 320, height: 240) { context, index in
            context.setFillColor(index < 15 ? CGColor(red: 0, green: 0.85, blue: 0.1, alpha: 1)
                                            : CGColor(red: 0.9, green: 0, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
        var edit = EditTimeline(clips: [EditClip(blue, to: 2)])
        edit.overlays = [EditOverlay(changing, start: 0.5, fullFrame: true)]
        let out = directory.appendingPathComponent("timed.mov")
        try await VideoForge.compose(edit, to: out)
        let frames = try await TestClips.decodedFrames(of: out)
        let green = try frame(frames, at: 0.7).rgb(320, 180), magenta = try frame(frames, at: 1.3).rgb(320, 180)
        XCTAssert(green.g > 150 && green.r < 90, "0.2 s into the overlay is its green half: \(green)")
        XCTAssert(magenta.r > 150 && magenta.g < 90, "0.8 s into it, magenta: \(magenta)")
        XCTAssert(isBlue(try frame(frames, at: 1.7).rgb(320, 180)), "after its one second, the clip again")
    }

    func testMusicIsMixedWithoutDrawingThePictureTwice() async throws {
        let song = directory.appendingPathComponent("song.caf")
        try TestClips.writeTone(to: song, seconds: 4, hz: 330)
        let voice = directory.appendingPathComponent("voice.caf")
        try TestClips.writeTone(to: voice, seconds: 0.6, hz: 660)
        var edit = EditTimeline(clips: [EditClip(red, to: 1), EditClip(blue, to: 1)])
        edit.music = EditMusic(song, bed: MusicBed(fadeIn: 0, fadeOut: 0))
        edit.voices = [EditSound(voice, start: 1.2)]
        let out = directory.appendingPathComponent("music.mp4")
        let done = try await VideoForge.compose(edit, to: out)
        XCTAssertNotNil(done.soundtrack?.music)
        XCTAssertEqual(done.result.after.duration, 2, accuracy: 0.05)
        let samples = try await TestClips.monoSamples(of: out)
        let during = TestClips.toneLevel(samples, hz: 660, in: Int(1.3 * 48_000)..<Int(1.7 * 48_000))
        let before = TestClips.toneLevel(samples, hz: 660, in: Int(0.3 * 48_000)..<Int(0.7 * 48_000))
        XCTAssertGreaterThan(during, before + 20, "the voice is heard at 1.2 s, and not before: \(during) vs \(before) dB")
        let frames = try await TestClips.decodedFrames(of: out)
        XCTAssert(isRed(try frame(frames, at: 0.5).rgb(320, 180)))
        XCTAssert(isBlue(try frame(frames, at: 1.5).rgb(320, 180)))
    }

    func testProblemsAreAllReportedBeforeAnythingIsWritten() async throws {
        var edit = EditTimeline(clips: [EditClip(red, from: 2, to: 1), EditClip(directory.appendingPathComponent("gone.mov"))])
        edit.voices = [EditSound(directory.appendingPathComponent("vo.m4a"), start: 0)]
        let problems = await VideoForge.problems(in: edit)
        XCTAssert(problems.contains { $0.hasPrefix("clips[0].to:") }, "\(problems)")
        XCTAssert(problems.contains { $0.hasPrefix("clips[1].file:") }, "\(problems)")
        XCTAssert(problems.contains { $0.hasPrefix("voices[0].file:") }, "\(problems)")
        let out = directory.appendingPathComponent("never.mov")
        do {
            try await VideoForge.compose(edit, to: out)
            XCTFail("an edit with problems rendered")
        } catch VideoForgeError.invalidOptions(let text) {
            XCTAssertEqual(text.split(separator: "\n").count, problems.count)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testStillsMatchTheRender() async throws {
        let edit = EditTimeline(clips: [EditClip(red, to: 1), EditClip(blue, to: 1)], size: CGSize(width: 320, height: 320))
        let stills = try await VideoForge.composeFrames(edit, at: [0.5, 1.5], width: 160)
        XCTAssertEqual(stills.map(\.width), [160, 160])
        XCTAssertEqual(stills.map(\.height), [160, 160])
    }
}
