//
//  PictureInPictureTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Picture-in-picture, measured blind: where the written frame differs
//  from the clip underneath IS the overlay, so its rectangle, its timing
//  and whether it covers a face are read from the file, not looked at.
//

import AVFoundation
import CoreGraphics
import ImageForge
import SubtitleKit
import XCTest
@testable import VideoForge

final class PictureInPictureTests: XCTestCase {

    var directory: URL!
    var main: URL!
    var overlay: URL!

    /// A flat dark grey main clip — whatever differs from it is the overlay.
    static let grey: @Sendable (CGContext, Int) -> Void = { context, _ in
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    }

    /// A flat green 4:3 overlay.
    static let green: @Sendable (CGContext, Int) -> Void = { context, _ in
        context.setFillColor(CGColor(red: 0, green: 0.85, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    }

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        main = directory.appendingPathComponent("main.mov")
        overlay = directory.appendingPathComponent("overlay.mov")
        try await TestClips.writeDrawnMovie(to: main, seconds: 2, hz: 440, draw: Self.grey)
        try await TestClips.writeDrawnMovie(to: overlay, seconds: 3, width: 320, height: 240, hz: 660, draw: Self.green)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func isGreen(_ pixel: (r: Int, g: Int, b: Int)) -> Bool { pixel.g > 150 && pixel.r < 90 }

    func assertRect(_ measured: CGRect?, _ wanted: CGRect, tolerance: CGFloat = 2, _ label: String,
                    file: StaticString = #filePath, line: UInt = #line) throws {
        let got = try XCTUnwrap(measured, "\(label): no overlay found", file: file, line: line)
        for (a, b, name) in [(got.minX, wanted.minX, "x"), (got.minY, wanted.minY, "y"),
                             (got.width, wanted.width, "width"), (got.height, wanted.height, "height")] {
            XCTAssertEqual(a, b, accuracy: tolerance, "\(label): \(name) \(got) vs \(wanted)", file: file, line: line)
        }
    }

    // MARK: - Where

    func testTheOverlayIsWhereItWasAsked() async throws {
        let written = out("tr.mov")
        let done = try await VideoForge.pictureInPicture(main, overlay: overlay, to: written, options: PictureInPicture(
            start: 0.5, end: 1.5, corner: .topRight, size: 0.25, margin: 0.05))
        // 25% of 640 is 160 wide, 120 tall at 4:3; 5% of 360 is 18 px in.
        let wanted = CGRect(x: 640 - 18 - 160, y: 18, width: 160, height: 120)
        XCTAssertEqual(done.placement.rect, wanted)
        XCTAssertEqual(done.placement.corner, .topRight)
        XCTAssertEqual(done.placement.framesScanned, 9)

        let before = try await TestClips.decodedFrames(of: main)
        let after = try await TestClips.decodedFrames(of: written)
        XCTAssertEqual(after.count, before.count)
        try assertRect(TestClips.differingRect(before[30], after[30]), wanted, "frame at 1 s")
        XCTAssertEqual(done.result.after.width, 640)
        XCTAssertEqual(done.result.after.duration, 2, accuracy: 0.05)
    }

    func testEveryCornerAndRoundingStaysInsideItsRect() async throws {
        let before = try await TestClips.decodedFrames(of: main)
        for corner in [PictureCorner.topLeft, .bottomLeft, .bottomRight] {
            let written = out("\(corner.rawValue).mov")
            let done = try await VideoForge.pictureInPicture(main, overlay: overlay, to: written, options: PictureInPicture(
                corner: corner, size: 0.3, roundness: 0.2))
            let after = try await TestClips.decodedFrames(of: written)
            // Rounded corners take the corner pixels away, never add any.
            try assertRect(TestClips.differingRect(before[20], after[20]), done.placement.rect, "\(corner)")
            let rect = done.placement.rect
            XCTAssertFalse(isGreen(after[20].rgb(Int(rect.minX) + 1, Int(rect.minY) + 1)), "\(corner): corner not rounded")
            XCTAssertTrue(isGreen(after[20].rgb(Int(rect.midX), Int(rect.midY))), "\(corner): no overlay")
        }
    }

    // MARK: - When

    func testTheOverlayAppearsAndGoesOnTheFrameAsked() async throws {
        let written = out("timed.mov")
        // 0.51 s falls between frames 15 (0.500) and 16 (0.533); 1.49 between
        // 44 (1.467) and 45 (1.500).
        let done = try await VideoForge.pictureInPicture(main, overlay: overlay, to: written, options: PictureInPicture(
            start: 0.51, end: 1.49, corner: .bottomLeft))
        let centre = (Int(done.placement.rect.midX), Int(done.placement.rect.midY))
        let shown = try await TestClips.decodedFrames(of: written).enumerated()
            .filter { isGreen($0.element.rgb(centre.0, centre.1)) }.map(\.offset)
        XCTAssertEqual(shown, Array(16...44))
    }

    func testAFadeLightsTheFirstAndLastFramesPartly() async throws {
        let written = out("cutaway.mov")
        let done = try await VideoForge.pictureInPicture(main, overlay: overlay, to: written, options: PictureInPicture(
            start: 0.5, end: 1.5, fullFrame: true, fade: 0.5))
        XCTAssertNil(done.placement.corner)
        let frames = try await TestClips.decodedFrames(of: written)
        let before = try await TestClips.decodedFrames(of: main)
        // Full frame: the whole picture is the overlay once faded in.
        try assertRect(TestClips.differingRect(before[30], frames[30]), CGRect(x: 0, y: 0, width: 640, height: 360),
                       "full frame")
        let green = frames.map { $0.rgb(320, 180).g }
        XCTAssertEqual(green[14], green[0], accuracy: 3, "before the start")
        XCTAssertGreaterThan(green[15], green[14] + 5, "the first frame is partly lit")
        XCTAssertLessThan(green[15], green[30] - 50, "the first frame is not fully lit")
        XCTAssertGreaterThan(green[30], 180, "lit after the fade")
        XCTAssertGreaterThan(green[44], green[45] + 5, "the last frame is still faintly there")
        XCTAssertEqual(green[45], green[0], accuracy: 3, "gone at the end")
    }

    // MARK: - Faces

    /// A main clip with the portrait in its bottom-right quarter, where a
    /// picture-in-picture conventionally goes.
    func faceClip() async throws -> URL {
        let face = try TestClips.face()
        let url = out("face.mov")
        try await TestClips.writeDrawnMovie(to: url, seconds: 2) { context, _ in
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.draw(face, in: CGRect(x: 400, y: 10, width: 220, height: 220))
        }
        return url
    }

    func testTheAutomaticCornerCoversNoFace() async throws {
        let talking = try await faceClip()
        let written = out("auto.mov")
        let done = try await VideoForge.pictureInPicture(talking, overlay: overlay, to: written,
                                                         options: PictureInPicture(size: 0.3))
        XCTAssertGreaterThan(done.placement.facesSeen, 0)
        XCTAssertEqual(done.placement.faceCoverage, 0)
        // The test means something: the conventional corner WOULD cover it.
        let scan = try await FaceScan.faces(in: talking, from: 0, to: 2, frame: CGSize(width: 640, height: 360))
        let bottomRight = OverlayLayout.rect(for: .bottomRight, frame: CGSize(width: 640, height: 360),
                                             overlay: CGSize(width: 320, height: 240), size: 0.3, margin: 0.04)
        XCTAssertGreaterThan(OverlayLayout.coverage(of: bottomRight, faces: scan.faces), 0)

        // Measured on the written file: the overlay found by difference, the
        // faces found by Vision in the same frame, and they do not meet.
        let before = try await TestClips.decodedFrames(of: talking)
        let after = try await TestClips.decodedFrames(of: written)
        let placed = try XCTUnwrap(TestClips.differingRect(before[30], after[30]))
        let faces = try await Detectors.faces(in: try XCTUnwrap(after[30].image))
        XCTAssertFalse(faces.isEmpty, "the face is still visible")
        for face in faces { XCTAssertTrue(face.rect.intersection(placed).isNull, "\(face.rect) under \(placed)") }
    }

    // MARK: - Depth, colour and sound

    func testTenBitHLGStaysTenBitHLG() async throws {
        let deep = out("deep.mov")
        try await TestClips.writeDeepVideo(to: deep, seconds: 1, hlg: true)
        let written = out("deep-pip.mov")
        // A small overlay at the top left keeps clear of the middle row.
        let done = try await VideoForge.pictureInPicture(deep, overlay: overlay, to: written, options: PictureInPicture(
            corner: .topLeft, size: 0.2))
        XCTAssertEqual(done.result.after.video?.codec, "hvc1")
        XCTAssertEqual(done.result.after.video?.bitDepth, 10)
        let levels = try await TestClips.lumaLevels(in: written)
        // MEASURED: 226 of the ramp's 256 levels with the overlay in the
        // frame, 254 with it not yet on — the encoder spends its bits on the
        // overlay's hard edges; 8 bits would leave at most 64.
        XCTAssertGreaterThan(levels, 200, "a 10-bit ramp of 256 levels came out with \(levels)")
        let track = try await AVURLAsset(url: written).loadTracks(withMediaType: .video).first
        let description = try await track?.load(.formatDescriptions).first
        let colour = try XCTUnwrap(description.flatMap(FormatDescriptions.colour(of:)))
        XCTAssertEqual(colour.transfer, AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(colour.primaries, AVVideoColorPrimaries_ITU_R_2020)
    }

    func testTheOverlaysSoundIsMutedUnlessMixed() async throws {
        let muted = out("muted.mov"), mixed = out("mixed.mov")
        try await VideoForge.pictureInPicture(main, overlay: overlay, to: muted, options: PictureInPicture(
            start: 0.5, end: 1.5, corner: .topLeft))
        try await VideoForge.pictureInPicture(main, overlay: overlay, to: mixed, options: PictureInPicture(
            start: 0.5, end: 1.5, corner: .topLeft, mix: 0.5))
        let quiet = try await TestClips.monoSamples(of: muted)
        let loud = try await TestClips.monoSamples(of: mixed)
        let during = 33_600..<62_400        // 0.7–1.3 s at 48 kHz
        let outside = 76_800..<91_200       // 1.6–1.9 s
        // The main clip's tone at 0.3 reads −10.5 dB; the overlay's, at half
        // its 0.3, should read −16.5 dB under it — and nothing when muted.
        XCTAssertEqual(TestClips.toneLevel(loud, hz: 440, in: during), -10.5, accuracy: 1)
        XCTAssertEqual(TestClips.toneLevel(loud, hz: 660, in: during), -16.5, accuracy: 1)
        XCTAssertLessThan(TestClips.toneLevel(loud, hz: 660, in: outside), -50)
        XCTAssertLessThan(TestClips.toneLevel(quiet, hz: 660, in: during), -50)
        XCTAssertEqual(TestClips.toneLevel(quiet, hz: 440, in: during), -10.5, accuracy: 1)
    }

    func testTheWriterRoadPlacesItTheSame() async throws {
        let written = out("written.mp4")
        let done = try await VideoForge.pictureInPicture(main, overlay: overlay, to: written, options: PictureInPicture(
            start: 0.5, corner: .bottomRight, mix: 0.5), export: ExportSpec(bitRate: 2_000_000))
        let before = try await TestClips.decodedFrames(of: main)
        let after = try await TestClips.decodedFrames(of: written)
        try assertRect(TestClips.differingRect(before[30], after[30]), done.placement.rect, "writer road")
        let sound = try await TestClips.monoSamples(of: written)
        XCTAssertEqual(TestClips.toneLevel(sound, hz: 660, in: 33_600..<62_400), -16.5, accuracy: 1)
    }

    func testTheMainClipsSubtitlesComeAlong() async throws {
        let subtitled = out("subtitled.mov")
        try await VideoForge.addSubtitles([Subtitles(cues: [SubtitleCue(start: 0.25, end: 1.25, text: "hello")],
                                                     language: "en")], to: main, destination: subtitled)
        let written = out("pip-subtitled.mov")
        let done = try await VideoForge.pictureInPicture(subtitled, overlay: overlay, to: written,
                                                         options: PictureInPicture(corner: .topLeft))
        XCTAssertEqual(done.result.lostTracks, [])
        let cues = try await VideoForge.subtitles(in: written).first?.cues
        XCTAssertEqual(cues?.map(\.text), ["hello"])
        XCTAssertEqual(cues?.first?.start ?? 0, 0.25, accuracy: 0.002)
    }

    /// Up to the first build of 0.7.0, a clip whose sound ran past its
    /// picture crashed the background blur (a frame of infinite extent
    /// made a nil mask) and failed the overlay (no main frame to draw on).
    func testAPictureShorterThanItsSoundIsDrawnToTheEnd() async throws {
        let picture = out("short-picture.mov"), sound = out("long-sound.caf"), clip = out("uneven.mov")
        try await TestClips.writeDrawn(to: picture, seconds: 1, width: 320, height: 180, draw: Self.grey)
        try TestClips.writeAudio(to: sound, seconds: 1.5)
        let composition = AVMutableComposition()
        for (url, type) in [(picture, AVMediaType.video), (sound, AVMediaType.audio)] {
            let asset = AVURLAsset(url: url)
            let sources = try await asset.loadTracks(withMediaType: type)
            let duration = try await asset.load(.duration)
            let source = try XCTUnwrap(sources.first)
            let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        try await Composer.export(composition, to: clip, container: .mov, preset: AVAssetExportPresetPassthrough)
        let blurred = try await VideoForge.process(clip, to: out("uneven-blur.mov"), options: VideoProcessOptions(
            operations: [.blurBackground(BackgroundBlur())]))
        XCTAssertGreaterThan(blurred.after.duration, 1.4)
        let overlaid = try await VideoForge.pictureInPicture(clip, overlay: overlay, to: out("uneven-pip.mov"))
        XCTAssertGreaterThan(overlaid.result.after.duration, 1.4)
    }

    // MARK: - Rules

    func testCornerRectanglesFollowTheirRules() {
        let frame = CGSize(width: 1920, height: 1080)
        // A portrait overlay too tall for the frame is shrunk to fit.
        let tall = OverlayLayout.rect(for: .topLeft, frame: frame, overlay: CGSize(width: 1080, height: 1920),
                                      size: 0.5, margin: 0.05)
        XCTAssertEqual(tall, CGRect(x: 54, y: 54, width: 547, height: 972))
        let wide = OverlayLayout.rect(for: .bottomRight, frame: frame, overlay: CGSize(width: 1920, height: 1080),
                                      size: 0.25, margin: 0.04)
        XCTAssertEqual(wide, CGRect(x: 1920 - 43 - 480, y: 1080 - 43 - 270, width: 480, height: 270))
        let cover = OverlayLayout.cover(frame: frame, overlay: CGSize(width: 640, height: 480))
        XCTAssertEqual(cover.width, 1920, accuracy: 0.01)
        XCTAssertEqual(cover.minY, -180, accuracy: 0.01)
    }

    func testTheCornerIsChosenByFacesThenClearanceThenOrder() {
        let corners = PictureCorner.corners.map { ($0, CGRect(x: $0 == .bottomRight || $0 == .topRight ? 100 : 0,
                                                            y: $0 == .bottomRight || $0 == .bottomLeft ? 100 : 0,
                                                            width: 50, height: 50)) }
        XCTAssertEqual(OverlayLayout.choose(among: corners, faces: []).corner, .bottomRight)
        // A face under bottom right: bottom left and top right are clear;
        // top left is farthest from it.
        let face = CGRect(x: 120, y: 120, width: 20, height: 20)
        let chosen = OverlayLayout.choose(among: corners, faces: [face])
        XCTAssertEqual(chosen.corner, .topLeft)
        XCTAssertEqual(chosen.coverage, 0)
        XCTAssertEqual(OverlayLayout.coverage(of: CGRect(x: 120, y: 120, width: 10, height: 20), faces: [face]), 0.5)
    }

    func testOpacityLightsFromTheFirstFrame() {
        let d = 1.0 / 30
        XCTAssertEqual(OverlayLayout.opacity(at: 0.99, start: 1, end: 2, fade: 0, frameDuration: d), 0)
        XCTAssertEqual(OverlayLayout.opacity(at: 1, start: 1, end: 2, fade: 0, frameDuration: d), 1)
        XCTAssertEqual(OverlayLayout.opacity(at: 1, start: 1, end: 2, fade: 0.5, frameDuration: d), d / 0.5, accuracy: 1e-9)
        XCTAssertEqual(OverlayLayout.opacity(at: 2 - d, start: 1, end: 2, fade: 0.5, frameDuration: d), d / 0.5, accuracy: 1e-9)
        XCTAssertEqual(OverlayLayout.opacity(at: 2, start: 1, end: 2, fade: 0.5, frameDuration: d), 0)
    }

    func testBadSettingsAreRefusedBeforeAnythingIsRead() async throws {
        XCTAssertNotNil(PictureInPicture(size: 2).problem)
        XCTAssertNotNil(PictureInPicture(start: 2, end: 1).problem)
        XCTAssertNotNil(PictureInPicture(mix: 1.5).problem)
        XCTAssertNil(PictureInPicture().problem)
        do {
            try await VideoForge.pictureInPicture(main, overlay: overlay, to: out("late.mov"),
                                                  options: PictureInPicture(start: 5))
            XCTFail("an overlay after the end was accepted")
        } catch VideoForgeError.invalidOptions {}
    }
}
