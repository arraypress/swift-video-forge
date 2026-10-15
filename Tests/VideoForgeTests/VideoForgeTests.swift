//
//  VideoForgeTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  End to end on synthetic clips. The durations here are asserted to a
//  hundredth of a second on purpose: the speed verb was measured landing
//  7% long before the export was clamped, and a looser assertion would
//  have called that a pass.
//

import AVFoundation
import ImageForge
import XCTest
@testable import VideoForge

final class VideoForgeTests: XCTestCase {

    var directory: URL!
    var clip: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        clip = directory.appendingPathComponent("clip.mov")
        try await TestClips.writeMovie(to: clip, seconds: 2)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - Describing

    func testDescribeReadsTheContainer() async throws {
        let info = try await VideoForge.describe(clip)
        XCTAssertEqual(info.duration, 2, accuracy: 0.05)
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.height, 240)
        XCTAssertEqual(info.frameRate, 30, accuracy: 0.5)
        XCTAssertEqual(info.container, .mov)
        XCTAssertTrue(info.hasVideo)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.tracks.count, 2)
        XCTAssertGreaterThan(info.byteCount, 0)
        XCTAssertFalse(info.isDeep, "an H.264 fixture is 8-bit")
        XCTAssertEqual(info.video?.bitDepth, 8)
    }

    func testTracksCarryTheirOwnShape() async throws {
        let info = try await VideoForge.describe(clip)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(video.codec, "avc1")
        XCTAssertEqual(video.width, 320)
        let audio = try XCTUnwrap(info.audio)
        XCTAssertEqual(audio.channels, 1)
        XCTAssertEqual(audio.sampleRate ?? 0, 44100, accuracy: 1)
    }

    func testDescribingAMissingFileSaysSo() async {
        do {
            _ = try await VideoForge.describe(out("nope.mov"))
            XCTFail("should have refused")
        } catch let error as VideoForgeError {
            guard case .fileNotFound = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    func testDepthComesFromBitsPerComponentNotDepth() async throws {
        // MEASURED: the `Depth` extension reads 24 for 8-bit H.264 AND for
        // 10-bit HEVC Main10, so keying off it marks every ordinary clip as
        // deep — which is exactly what this library must not do, since being
        // "deep" is what forbids writing H.264. `BitsPerComponent` is the
        // real signal, and it is absent entirely on 8-bit footage.
        let info = try await VideoForge.describe(clip)
        XCTAssertEqual(info.video?.bitDepth, 8, "absent means 8, not 24")
        XCTAssertFalse(info.isDeep)
    }

    // MARK: - Trim

    func testTrimKeepsTheStretchAsked() async throws {
        let result = try await VideoForge.process(
            clip, to: out("trim.mov"), options: .trim(.between(0.5, 1.5)))
        XCTAssertEqual(result.after.duration, 1, accuracy: 0.05)
        XCTAssertTrue(result.passedThrough, "a trim should not re-encode")
        XCTAssertTrue(result.lostTracks.isEmpty, "both tracks survive a trim")
    }

    func testTrimBeyondTheEndIsClampedRatherThanRefused() async throws {
        let result = try await VideoForge.process(
            clip, to: out("long.mov"), options: .trim(TrimSpec(start: 1, duration: 60)))
        XCTAssertEqual(result.after.duration, 1, accuracy: 0.05,
                       "asking for a minute of a two-second clip gives what is there")
    }

    func testATrimThatKeepsNothingIsRefused() async {
        do {
            _ = try await VideoForge.process(
                clip, to: out("empty.mov"), options: .trim(TrimSpec(start: 5, duration: 1)))
            XCTFail("should have refused")
        } catch let error as VideoForgeError {
            guard case .emptyRange = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    // MARK: - Speed

    func testSpeedLandsOnTheDurationAskedFor() async throws {
        // MEASURED: without clamping the export to the composition's own
        // duration this came out at 1.08s rather than 1.00s, because the
        // audio time-pitch pass pads the end. Hence the tight accuracy.
        let result = try await VideoForge.process(
            clip, to: out("fast.mov"), options: VideoProcessOptions(operations: [.speed(2)]))
        XCTAssertEqual(result.after.duration, 1, accuracy: 0.05)
    }

    func testSlowingDownIsTheSameArithmeticBackwards() async throws {
        let result = try await VideoForge.process(
            clip, to: out("slow.mov"), options: VideoProcessOptions(operations: [.speed(0.5)]))
        XCTAssertEqual(result.after.duration, 4, accuracy: 0.1)
    }

    func testAZeroSpeedIsRefused() async {
        do {
            _ = try await VideoForge.process(
                clip, to: out("zero.mov"), options: VideoProcessOptions(operations: [.speed(0)]))
            XCTFail("should have refused")
        } catch let error as VideoForgeError {
            guard case .emptyRange = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    func testTrimAndSpeedCompose() async throws {
        let result = try await VideoForge.process(
            clip, to: out("both.mov"),
            options: VideoProcessOptions(operations: [.trim(.between(0, 1)), .speed(2)]))
        XCTAssertEqual(result.after.duration, 0.5, accuracy: 0.05)
    }

    // MARK: - Frames

    func testResizeChangesTheFrame() async throws {
        let result = try await VideoForge.process(
            clip, to: out("small.mov"),
            options: VideoProcessOptions(operations: [.resize(VideoSize(width: 160, height: 160))]))
        XCTAssertEqual(result.after.width, 160)
        XCTAssertEqual(result.after.height, 120, "fitting keeps the 4:3 shape")
        XCTAssertFalse(result.passedThrough, "redrawing frames is not a passthrough")
        XCTAssertEqual(result.after.duration, 2, accuracy: 0.1)
        XCTAssertTrue(result.after.hasAudio, "the sound comes along untouched")
    }

    func testFillCropsToTheShapeAsked() async throws {
        let result = try await VideoForge.process(
            clip, to: out("square.mov"),
            options: VideoProcessOptions(operations: [.resize(.fill(width: 200, height: 200))]))
        XCTAssertEqual(result.after.width, 200)
        XCTAssertEqual(result.after.height, 200)
    }

    func testCropTakesARectangleFromTheTopLeft() async throws {
        let result = try await VideoForge.process(
            clip, to: out("crop.mov"),
            options: VideoProcessOptions(operations: [.crop(x: 0, y: 0, width: 160, height: 120)]))
        XCTAssertEqual(result.after.width, 160)
        XCTAssertEqual(result.after.height, 120)
    }

    func testACropOutsideTheFrameIsRefused() async {
        do {
            _ = try await VideoForge.process(
                clip, to: out("bad.mov"),
                options: VideoProcessOptions(operations: [.crop(x: 300, y: 0, width: 100, height: 100)]))
            XCTFail("should have refused")
        } catch let error as VideoForgeError {
            guard case .cropOutOfBounds = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    func testAspectCropsToTheLargestRectangleThatFits() async throws {
        let result = try await VideoForge.process(
            clip, to: out("wide.mov"),
            options: VideoProcessOptions(operations: [.aspect(width: 16, height: 9)]))
        XCTAssertEqual(result.after.width, 320)
        XCTAssertEqual(result.after.height, 180)
    }

    func testRotatingAQuarterTurnSwapsTheSides() async throws {
        let result = try await VideoForge.process(
            clip, to: out("turned.mov"),
            options: VideoProcessOptions(operations: [.rotate(.ninety)]))
        XCTAssertEqual(result.after.width, 240)
        XCTAssertEqual(result.after.height, 320)
    }

    func testFlippingKeepsTheShape() async throws {
        let result = try await VideoForge.process(
            clip, to: out("mirror.mov"),
            options: VideoProcessOptions(operations: [.flip(.horizontal)]))
        XCTAssertEqual(result.after.width, 320)
        XCTAssertEqual(result.after.height, 240)
    }

    func testTrimAndResizeCompose() async throws {
        // The trim runs on the composition road first, so the render road
        // only ever sees the frames that survive it.
        let result = try await VideoForge.process(
            clip, to: out("both2.mov"),
            options: VideoProcessOptions(operations: [
                .trim(.until(1)), .resize(VideoSize(width: 160, height: 160)),
            ]))
        XCTAssertEqual(result.after.duration, 1, accuracy: 0.05)
        XCTAssertEqual(result.after.width, 160)
    }

    func testEvenDimensionsAreForced() {
        // Encoders work in macroblocks: an odd dimension is refused by some
        // and silently rounded by others, and silent rounding is how a
        // frame-accurate edit stops lining up.
        XCTAssertEqual(VideoSize.even(CGSize(width: 101, height: 57)),
                       CGSize(width: 102, height: 58))
        XCTAssertEqual(VideoSize.even(CGSize(width: 0, height: 1)),
                       CGSize(width: 2, height: 2))
    }

    // MARK: - Tracks

    func testRemovingTheAudioLeavesASilentClip() async throws {
        let result = try await VideoForge.process(
            clip, to: out("mute.mov"),
            options: VideoProcessOptions(operations: [.remove(.audio)]))
        XCTAssertFalse(result.after.hasAudio)
        XCTAssertTrue(result.after.hasVideo)
        XCTAssertEqual(result.lostTracks, [.audio], "the loss is reported, not silent")
    }

    func testKeepsAudioFalseDoesTheSame() async throws {
        let result = try await VideoForge.process(
            clip, to: out("mute2.mov"),
            options: VideoProcessOptions(export: .mute))
        XCTAssertFalse(result.after.hasAudio)
    }

    // MARK: - Audio

    func testAudioComesOutOnItsOwn() async throws {
        let info = try await VideoForge.extractAudio(from: clip, to: out("sound.m4a"))
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)
        XCTAssertFalse(info.hasVideo)
        XCTAssertTrue(info.hasAudio)
    }

    func testExtractingFromASilentClipSaysSo() async throws {
        let silent = out("silent.mov")
        try await TestClips.writeVideo(to: silent, seconds: 1)
        do {
            _ = try await VideoForge.extractAudio(from: silent, to: out("none.m4a"))
            XCTFail("should have refused")
        } catch let error as VideoForgeError {
            guard case .noAudioTrack = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    func testMusicGoesUnderThePicture() async throws {
        let silent = out("silent2.mov")
        try await TestClips.writeVideo(to: silent, seconds: 2)
        let music = out("music.caf")
        try TestClips.writeAudio(to: music, seconds: 5, hz: 220)

        let result = try await VideoForge.addMusic(music, to: silent, destination: out("scored.mov")).result
        XCTAssertTrue(result.after.hasAudio)
        XCTAssertEqual(result.after.duration, 2, accuracy: 0.1,
                       "music longer than the picture is trimmed to it")
    }

    // MARK: - Joining

    func testClipsJoinEndToEnd() async throws {
        let second = out("second.mov")
        try await TestClips.writeMovie(to: second, seconds: 1, hue: 0.6)
        let result = try await VideoForge.join([clip, second], to: out("joined.mov"))
        XCTAssertEqual(result.after.duration, 3, accuracy: 0.15)
        XCTAssertTrue(result.after.hasAudio)
    }

    /// Up to 0.5.0 two clips without sound failed with "Operation
    /// Stopped": the join kept an audio track of nothing but empty edits.
    func testSilentClipsJoin() async throws {
        let first = out("silent-1.mov"), second = out("silent-2.mov")
        try await TestClips.writeVideo(to: first, seconds: 1)
        try await TestClips.writeVideo(to: second, seconds: 1, hue: 0.6)
        for (name, export) in [("session", ExportSpec()), ("writer", ExportSpec(frameRate: 24))] {
            let result = try await VideoForge.join([first, second], to: out("silent-\(name).mov"), export: export)
            XCTAssertEqual(result.after.duration, 2, accuracy: 0.1, name)
            XCTAssertFalse(result.after.hasAudio, name)
        }
    }

    func testJoiningNothingIsRefused() async {
        do {
            _ = try await VideoForge.join([], to: out("nothing.mov"))
            XCTFail("should have refused")
        } catch let error as VideoForgeError {
            guard case .incompatibleClips = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    // MARK: - Frames out

    func testStillsComeOutAtTheTimesAsked() async throws {
        let grabbed = try await Frames.at(clip, times: [0, 0.5, 1.5])
        XCTAssertEqual(grabbed.count, 3)
        XCTAssertEqual(grabbed[0].image.width, 320)
        XCTAssertEqual(grabbed.map(\.seconds), [0, 0.5, 1.5])
    }

    func testASteadyRateGivesTheRightNumberOfFrames() async throws {
        let grabbed = try await Frames.every(clip, fps: 5)
        XCTAssertEqual(grabbed.count, 10, "five a second across two seconds")
    }

    func testFramesCanBeBoundedInSize() async throws {
        let grabbed = try await Frames.every(clip, fps: 2, maxPixelSize: 80)
        XCTAssertLessThanOrEqual(grabbed[0].image.width, 80)
    }

    func testAGifIsWritten() async throws {
        let gif = out("loop.gif")
        let bytes = try await Frames.animate(clip, to: gif, fps: 8, maxPixelSize: 160)
        XCTAssertGreaterThan(bytes, 0)

        // Read it back with the library that wrote it.
        let info = try ImageForge.describe(gif)
        XCTAssertEqual(info.format, .gif)
        XCTAssertEqual(info.frameCount, 16, "eight a second across two seconds")
        XCTAssertTrue(info.isAnimated)
        XCTAssertLessThanOrEqual(info.width, 160)
    }

    func testAGifCanBeMadeFromAStretchAndReversed() async throws {
        let gif = out("back.gif")
        try await Frames.animate(clip, to: gif, fps: 10, trim: .until(1),
                                 maxPixelSize: 120, animation: .reverse)
        XCTAssertEqual(try ImageForge.describe(gif).frameCount, 10)
    }

    func testAnApngIsWrittenToo() async throws {
        let png = out("loop.png")
        try await Frames.animate(clip, to: png, format: .png, fps: 6, maxPixelSize: 120)
        let info = try ImageForge.describe(png)
        XCTAssertEqual(info.format, .png)
        XCTAssertEqual(info.frameCount, 12, "an animated PNG is still a PNG")
    }

    func testFramesAreWrittenAsSeparateFiles() async throws {
        let folder = out("stills")
        let written = try await Frames.write(clip, into: folder, fps: 2, maxPixelSize: 100)
        XCTAssertEqual(written.count, 4)
        XCTAssertEqual(written[0].lastPathComponent, "clip-0001.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written[3].path))
    }

    func testAnImpossibleRunIsRefusedBeforeItIsAttempted() async {
        // MEASURED: 90 frames of 640×360 is 79 MB as BGRA, so ten seconds of
        // 4K comes to roughly ten gigabytes. Holding every frame is what
        // reversing needs, and refusing beats taking the machine down.
        let cost = Frames.memoryCost(size: CGSize(width: 3840, height: 2160), count: 300)
        XCTAssertGreaterThan(cost, 9 * 1_073_741_824)

        do {
            _ = try await Frames.every(clip, fps: 1000, budget: 1_000_000)
            XCTFail("should have refused")
        } catch let error as VideoForgeError {
            guard case .reverseTooLarge = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("trim it first"),
                          "the message should say what to do instead")
        } catch { XCTFail("got \(error)") }
    }

    func testTheMemoryCostArithmeticIsFourBytesAPixel() {
        XCTAssertEqual(Frames.memoryCost(size: CGSize(width: 100, height: 100), count: 10),
                       100 * 100 * 4 * 10)
        XCTAssertEqual(Frames.memoryCost(size: CGSize(width: 10, height: 10), count: 0), 0)
    }

    // MARK: - Writing rules

    func testAnExistingFileIsNotReplacedUnlessAsked() async throws {
        let taken = out("taken.mov")
        try Data("occupied".utf8).write(to: taken)
        do {
            _ = try await VideoForge.process(clip, to: taken, options: .trim(.until(1)))
            XCTFail("should have refused")
        } catch let error as VideoForgeError {
            guard case .destinationExists = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }

        var options = VideoProcessOptions.trim(.until(1))
        options.overwrites = true
        let result = try await VideoForge.process(clip, to: taken, options: options)
        XCTAssertEqual(result.after.duration, 1, accuracy: 0.05)
    }

    func testAnOutputFolderIsCreatedRatherThanRefused() async throws {
        // AVAssetExportSession does not create the folder and reports a
        // missing parent as "Cannot create file", which reads like a
        // permissions problem. `img` has always created it; the two tools
        // disagreeing about whether `--out ./new` works is worse than either.
        let fresh = out("does/not/exist/yet/trimmed.mov")
        let result = try await VideoForge.process(clip, to: fresh, options: .trim(.until(1)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(result.after.duration, 1, accuracy: 0.05)
    }

    func testTheResultReportsTheRoadItTook() async throws {
        let trimmed = try await VideoForge.process(clip, to: out("a.mov"), options: .trim(.until(1)))
        XCTAssertTrue(trimmed.passedThrough, "time-only work leaves the frames alone")

        var reencode = VideoProcessOptions.trim(.until(1))
        reencode.export.prefersPassthrough = false
        let forced = try await VideoForge.process(clip, to: out("b.mov"), options: reencode)
        XCTAssertFalse(forced.passedThrough)
        XCTAssertGreaterThan(forced.speed, 0, "it reports how fast it ran")
    }
}
