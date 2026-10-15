//
//  WriterTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The writer road, and the rules under it. Up to 0.4.0 `bitRate`,
//  `quality` and `frameRate` were saved in recipes and read by nobody —
//  and every test passed, because none of them read the file back. These
//  do: the frame count, the times, the depth, the tags, the alpha.
//

import AVFoundation
import CoreVideo
import SubtitleKit
import XCTest
@testable import VideoForge

final class WriterRulesTests: XCTestCase {

    // MARK: - Settings derivation (moved from swift-censor-kit with the type)

    func testWriterSettingsMatchTheSource() {
        // The real iPhone HDR story: HEVC 10-bit HLG at 31 Mb/s.
        let hdr = WriterSettings.derive(
            from: VideoSourceFormat(codec: "hvc1", width: 3840, height: 2160, dataRate: 31_000_000,
                                    frameRate: 24, bitsPerComponent: 10, colorPrimaries: "ITU_R_2020",
                                    transferFunction: "ITU_R_2100_HLG", yCbCrMatrix: "ITU_R_2020"),
            codec: .hevc, processesInRGB: true)
        XCTAssertEqual(hdr.codec, .hevc)
        XCTAssertEqual(hdr.profileLevel, "HEVC_Main10_AutoLevel")
        XCTAssertEqual(hdr.averageBitRate, 31_000_000, "never below the source's rate")
        XCTAssertEqual(hdr.expectedFrameRate, 24)
        XCTAssertEqual(hdr.transferFunction, "ITU_R_2100_HLG")
        XCTAssertEqual(hdr.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)

        // Plain 8-bit H.264 with no rate estimate: the resolution floor.
        let sdr = WriterSettings.derive(
            from: VideoSourceFormat(codec: "avc1", width: 1920, height: 1080, frameRate: 30, bitsPerComponent: 8),
            codec: .h264, processesInRGB: true)
        XCTAssertNil(sdr.profileLevel)
        XCTAssertEqual(sdr.averageBitRate, Int(1920.0 * 1080 * 30 * 0.05))
        XCTAssertFalse(sdr.hasColorProperties)
        XCTAssertEqual(sdr.pixelFormat, kCVPixelFormatType_32BGRA)

        // A partial colour set is dropped whole — the writer rejects partial
        // dictionaries, and guessing the missing member invents colour.
        let partial = WriterSettings.derive(
            from: VideoSourceFormat(codec: "hvc1", width: 100, height: 100, dataRate: 5_000_000,
                                    frameRate: 30, colorPrimaries: "ITU_R_709_2", yCbCrMatrix: "ITU_R_709_2"),
            codec: .hevc)
        XCTAssertFalse(partial.hasColorProperties)
        XCTAssertNil(partial.colorPrimaries)

        // Deep footage written as HEVC is Main 10, whatever it arrived as.
        let fromProRes = WriterSettings.derive(
            from: VideoSourceFormat(codec: "ap4h", width: 1920, height: 1080, dataRate: 80_000_000,
                                    frameRate: 25, bitsPerComponent: 12),
            codec: .hevc)
        XCTAssertEqual(fromProRes.profileLevel, "HEVC_Main10_AutoLevel")
    }

    func testWhatIsAskedForIsWhatTheEncoderIsTold() {
        let source = VideoSourceFormat(codec: "avc1", width: 1920, height: 1080, dataRate: 20_000_000, frameRate: 60)
        let rate = WriterSettings.derive(from: source, codec: .h264, bitRate: 4_000_000, quality: 0.3)
        XCTAssertEqual(rate.averageBitRate, 4_000_000)
        XCTAssertNil(rate.quality, "a bitrate wins over a quality")

        let quality = WriterSettings.derive(from: source, codec: .hevc, quality: 0.6)
        XCTAssertNil(quality.averageBitRate, "a quality is not also a bitrate")
        XCTAssertEqual(quality.quality, 0.6)

        let slower = WriterSettings.derive(from: source, codec: .h264, frameRate: 29.97)
        XCTAssertEqual(slower.expectedFrameRate, 30)

        // A smaller picture needs less: the source's rate scales with it.
        let small = WriterSettings.derive(from: source, codec: .h264, size: CGSize(width: 960, height: 540))
        XCTAssertEqual(small.averageBitRate, 5_000_000)
        XCTAssertEqual(small.width, 960)

        // Odd sizes are floored to even: encoders refuse odd dimensions.
        let odd = WriterSettings.derive(from: source, codec: .h264, size: CGSize(width: 641, height: 359))
        XCTAssertEqual(odd.width, 640)
        XCTAssertEqual(odd.height, 358)
    }

    func testProResIsToldNoRate() {
        let source = VideoSourceFormat(codec: "avc1", width: 1920, height: 1080, dataRate: 8_000_000, frameRate: 30)
        for codec in [VideoCodec.proRes422, .proRes4444] {
            let settings = WriterSettings.derive(from: source, codec: codec, bitRate: 5_000_000, quality: 0.5)
            XCTAssertNil(settings.averageBitRate)
            XCTAssertNil(settings.quality)
            XCTAssertNil(settings.videoOutputSettings[AVVideoCompressionPropertiesKey],
                         "ProRes refuses a compression dictionary with a rate in it")
        }
        let hevc = WriterSettings.derive(
            from: VideoSourceFormat(codec: "hvc1", width: 320, height: 240, bitsPerComponent: 10), codec: .hevc)
        let compression = hevc.videoOutputSettings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(compression?[AVVideoProfileLevelKey] as? String, "HEVC_Main10_AutoLevel",
                       "under the compression properties, where it does not throw")
    }

    func testThePixelFormatKeepsTheDepthTheCodecCanHold() {
        let eight = VideoSourceFormat(codec: "avc1", width: 320, height: 240)
        let ten = VideoSourceFormat(codec: "hvc1", width: 320, height: 240, bitsPerComponent: 10)
        XCTAssertEqual(WriterSettings.derive(from: eight, codec: .h264).pixelFormat,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(WriterSettings.derive(from: ten, codec: .hevc).pixelFormat,
                       kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        // MEASURED: ProRes keeps 95–101 of 256 levels from any RGB format,
        // 254–264 from 10-bit Y'CbCr.
        XCTAssertEqual(WriterSettings.derive(from: ten, codec: .proRes422).pixelFormat,
                       kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(WriterSettings.derive(from: ten, codec: .proRes4444).pixelFormat,
                       kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(WriterSettings.derive(from: ten, codec: .proRes4444, keepsAlpha: true).pixelFormat,
                       kCVPixelFormatType_4444AYpCbCr16, "alpha costs ProRes its depth: no 10-bit format carries both")
        XCTAssertEqual(WriterSettings.derive(from: eight, codec: .hevcAlpha, keepsAlpha: true).pixelFormat,
                       kCVPixelFormatType_32BGRA)
    }

    func testFrameDurationsAreExact() {
        XCTAssertEqual(WriterRules.frameDuration(fps: 30), CMTime(value: 1, timescale: 30))
        XCTAssertEqual(WriterRules.frameDuration(fps: 29.97), CMTime(value: 1001, timescale: 30000))
        XCTAssertEqual(WriterRules.frameDuration(fps: 23.976), CMTime(value: 1001, timescale: 24000))
        XCTAssertEqual(WriterRules.frameDuration(fps: 59.94), CMTime(value: 1001, timescale: 60000))
        XCTAssertEqual(WriterRules.frameDuration(fps: 12.5), CMTime(value: 48_000, timescale: 600_000))
    }

    func testTheAACRateIsTheSourcesWithinBounds() {
        XCTAssertEqual(AudioRules.aacBitRate(source: 160_000, channels: 2), 160_000)
        XCTAssertEqual(AudioRules.aacBitRate(source: 0, channels: 2), 128_000)
        XCTAssertEqual(AudioRules.aacBitRate(source: 1_536_000, channels: 2), 320_000, "PCM in: capped")
        XCTAssertEqual(AudioRules.aacBitRate(source: 8_000, channels: 1), 32_000)
        let prores = AudioRules.encoded(sampleRate: 48_000, channels: 2, layout: nil, codec: .proRes422)
        XCTAssertEqual(prores[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM, "PCM beside ProRes")
    }

    // MARK: - Which road

    func testOnlyWhatAPresetCannotDoTakesTheWriter() {
        XCTAssertFalse(CodecPlan.usesWriter(ExportSpec(), codec: .h264, redraws: true))
        XCTAssertFalse(CodecPlan.usesWriter(ExportSpec(codec: .proRes422), codec: .proRes422, redraws: true))
        XCTAssertFalse(CodecPlan.usesWriter(ExportSpec(codec: .proRes4444), codec: .proRes4444, redraws: false))
        XCTAssertTrue(CodecPlan.usesWriter(ExportSpec(codec: .proRes4444), codec: .proRes4444, redraws: true))
        XCTAssertTrue(CodecPlan.usesWriter(ExportSpec(bitRate: 2_000_000), codec: .h264, redraws: false))
        XCTAssertTrue(CodecPlan.usesWriter(ExportSpec(quality: 0.5), codec: .hevc, redraws: false))
        XCTAssertTrue(CodecPlan.usesWriter(ExportSpec(frameRate: 30), codec: .h264, redraws: false))

        XCTAssertFalse(CodecPlan.passesThrough(ExportSpec(quality: 0.5), codec: .h264, sourceCodec: "avc1",
                                               timeOnly: true), "a quality is a re-encode")
        XCTAssertTrue(CodecPlan.passesThrough(ExportSpec(), codec: .h264, sourceCodec: "avc1", timeOnly: true))
    }

    func testSpeedWithSoundNeedsATimePitchPass() {
        XCTAssertTrue(CodecPlan.retimesSound([.speed(2)], keepsAudio: true, hasAudio: true))
        XCTAssertFalse(CodecPlan.retimesSound([.speed(2)], keepsAudio: false, hasAudio: true))
        XCTAssertFalse(CodecPlan.retimesSound([.speed(2), .remove(.audio)], keepsAudio: true, hasAudio: true))
        XCTAssertFalse(CodecPlan.retimesSound([.trim(.until(1))], keepsAudio: true, hasAudio: true))
        XCTAssertFalse(CodecPlan.retimesSound([.speed(2)], keepsAudio: true, hasAudio: false))
    }

    func testProResRefusesARate() {
        XCTAssertThrowsError(try CodecPlan.checkRates(ExportSpec(bitRate: 8_000_000), codec: .proRes422)) {
            XCTAssertEqual($0 as? VideoForgeError, .codecTakesNoRate(codec: .proRes422))
        }
        XCTAssertThrowsError(try CodecPlan.checkRates(ExportSpec(quality: 0.5), codec: .proRes4444))
        XCTAssertNoThrow(try CodecPlan.checkRates(ExportSpec(frameRate: 24), codec: .proRes422))
        XCTAssertNoThrow(try CodecPlan.checkRates(ExportSpec(bitRate: 8_000_000), codec: .hevc))
    }

    func testAlphaIsPartOfTheSourcesCodec() {
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "hvc1", deep: false, alpha: true), .hevcAlpha)
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "hvc1", deep: false, alpha: false), .hevc)
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "ap4h", deep: true, alpha: true), .proRes4444)
    }

    func testProResDepthIsTheCodecsNotTheFootages() {
        let prores = TrackInfo(kind: .video, codec: "apcn", duration: 1, bitRate: 1, bitDepth: 12)
        XCTAssertTrue(prores.isDeep, "a deep codec is still chosen for it")
        XCTAssertFalse(prores.forbidsEightBit, "but an 8-bit codec asked for by name is allowed")
        let hevc = TrackInfo(kind: .video, codec: "hvc1", duration: 1, bitRate: 1, bitDepth: 10)
        XCTAssertTrue(hevc.forbidsEightBit)
    }
}

final class WriterRoadTests: XCTestCase {

    var directory: URL!
    /// 8-bit H.264, 30 fps, two seconds, with sound.
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

    func process(_ source: URL, _ name: String, _ operations: [VideoOperation] = [],
                 _ export: ExportSpec) async throws -> VideoProcessResult {
        try await VideoForge.process(source, to: out(name),
                                     options: VideoProcessOptions(operations: operations, export: export))
    }

    // MARK: - Frame rate

    func testAFrameRateResamplesAndKeepsTheLength() async throws {
        let result = try await process(clip, "15.mov", [], ExportSpec(frameRate: 15))
        XCTAssertFalse(result.passedThrough)
        let times = try await TestClips.frameTimes(of: result.destination)
        XCTAssertEqual(times.count, 30, "2 s at 15 fps")
        XCTAssertEqual(times.first ?? -1, 0, accuracy: 0.001, "the first frame where it was")
        XCTAssertEqual(times.last ?? -1, 2 - 1.0 / 15, accuracy: 0.001, "the last frame a frame from the end")
        XCTAssertEqual(result.after.duration, 2, accuracy: 0.01)
        XCTAssertEqual(result.after.audio?.duration ?? 0, 2, accuracy: 0.03, "the sound keeps its length")
        XCTAssertEqual(result.after.frameRate, 15, accuracy: 0.1)
    }

    func testAFrameRateCanRise() async throws {
        let result = try await process(clip, "48.mov", [.resize(.height(120))], ExportSpec(frameRate: 48))
        let times = try await TestClips.frameTimes(of: result.destination)
        XCTAssertEqual(times.count, 96, "frames are repeated to fill the rate")
        XCTAssertEqual(result.after.height, 120)
        XCTAssertEqual(result.after.duration, 2, accuracy: 0.01)
    }

    // MARK: - Rate and quality

    func testTheBitrateAskedForIsTheBitrateWritten() async throws {
        // Noise costs whatever it is allowed, so the rate is the encoder's
        // to hit, not the picture's to undercut.
        let noisy = try await TestClips.writeMovie(to: out("noisy.mov"), seconds: 3, noise: true)
        for asked in [1_500_000, 4_000_000] {
            let result = try await process(noisy, "rate-\(asked).mov", [], ExportSpec(bitRate: asked))
            let written = result.after.video?.bitRate ?? 0
            XCTAssertEqual(written, Double(asked), accuracy: Double(asked) * 0.2, "VBR, within 20 %")
            XCTAssertEqual(result.after.audio?.codec, "aac", "the sound is copied across")
        }
    }

    func testQualityOrdersTheSize() async throws {
        let noisy = try await TestClips.writeMovie(to: out("noisy.mov"), seconds: 1, noise: true)
        let rough = try await process(noisy, "rough.mov", [], ExportSpec(codec: .hevc, quality: 0.2))
        let fine = try await process(noisy, "fine.mov", [], ExportSpec(codec: .hevc, quality: 0.8))
        XCTAssertEqual(fine.after.video?.codec, "hvc1")
        XCTAssertLessThan(rough.after.byteCount, fine.after.byteCount)
    }

    func testProResWithABitrateIsRefusedBeforeAnythingIsWritten() async {
        do {
            _ = try await process(clip, "prores.mov", [], ExportSpec(codec: .proRes422, bitRate: 8_000_000))
            XCTFail("ProRes cannot be told a bitrate")
        } catch {
            XCTAssertEqual(error as? VideoForgeError, .codecTakesNoRate(codec: .proRes422))
            XCTAssertFalse(FileManager.default.fileExists(atPath: out("prores.mov").path))
        }
    }

    // MARK: - Depth, tags, alpha

    func testTenBitStaysTenBitAndKeepsItsTags() async throws {
        let deep = out("hlg.mov")
        try await TestClips.writeDeepVideo(to: deep, hlg: true)
        let result = try await process(deep, "hlg-24.mov", [.flip(.horizontal)],
                                       ExportSpec(bitRate: 4_000_000, frameRate: 24))
        XCTAssertEqual(result.after.video?.codec, "hvc1")
        XCTAssertTrue(result.after.isDeep)
        let levels = try await TestClips.lumaLevels(in: result.destination)
        XCTAssertGreaterThan(levels, 200, "8 bits would leave at most 64")
        let track = try await AVURLAsset(url: result.destination).loadTracks(withMediaType: .video)[0]
        let format = try await VideoSourceFormat.load(from: track)
        XCTAssertEqual(format.transferFunction, AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(format.colorPrimaries, AVVideoColorPrimaries_ITU_R_2020)
    }

    func testARedrawKeepsHLGTagsOnTheExportRoadToo() async throws {
        // Up to 0.4.0 a composition over an AVComposition picked up no tags,
        // and the redraw was labelled Rec. 709: HDR relabelled as SDR.
        let deep = out("hlg.mov")
        try await TestClips.writeDeepVideo(to: deep, hlg: true)
        let result = try await process(deep, "flip.mov", [.flip(.vertical)], ExportSpec())
        let track = try await AVURLAsset(url: result.destination).loadTracks(withMediaType: .video)[0]
        let format = try await VideoSourceFormat.load(from: track)
        XCTAssertEqual(format.transferFunction, AVVideoTransferFunction_ITU_R_2100_HLG)
    }

    func testAProRes4444RedrawKeepsItsLevels() async throws {
        // MEASURED: 95 of 256 levels through the export session's compositor.
        let deep = out("deep.mov")
        try await TestClips.writeDeepVideo(to: deep)
        let result = try await process(deep, "4444.mov", [.flip(.vertical)], ExportSpec(codec: .proRes4444))
        XCTAssertEqual(result.after.video?.codec, "ap4h")
        let levels = try await TestClips.lumaLevels(in: result.destination)
        XCTAssertGreaterThan(levels, 200)
    }

    func testAlphaSurvivesTheDefaultCodec() async throws {
        let alpha = out("alpha.mov")
        try await TestClips.writeAlphaVideo(to: alpha)
        let source = try await VideoForge.describe(alpha)
        XCTAssertTrue(source.hasAlpha, "read off ContainsAlphaChannel: the codec is hvc1 like any HEVC")
        for (name, export) in [("resized.mov", ExportSpec()), ("rated.mov", ExportSpec(frameRate: 24))] {
            let result = try await process(alpha, name, [.resize(.height(120))], export)
            XCTAssertTrue(result.after.hasAlpha, name)
            let samples = try await TestClips.alphaSamples(of: result.destination)
            XCTAssertEqual(samples.left, 255, accuracy: 3, name)
            XCTAssertEqual(samples.right, 80, accuracy: 6, name)
        }
    }

    func testProResFromEightBitFootageCanGoBackToH264() async throws {
        let prores = try await process(clip, "edit.mov", [], ExportSpec(codec: .proRes422))
        XCTAssertTrue(prores.after.isDeep, "ProRes declares 12 bits")
        let back = try await process(prores.destination, "back.mp4", [.trim(.until(1))],
                                     ExportSpec(container: .mp4, codec: .h264))
        XCTAssertEqual(back.after.video?.codec, "avc1")
    }

    // MARK: - Speed

    func testAPassthroughSpeedChangeRetimesTheSound() async throws {
        // Up to 0.4.0: 3.02 s of sound under 6 s of picture at half speed.
        for rate in [0.5, 2.0] {
            let result = try await process(clip, "speed-\(rate).mov", [.speed(rate)], ExportSpec())
            XCTAssertTrue(result.passedThrough, "the frames are copied")
            XCTAssertEqual(result.after.duration, 2 / rate, accuracy: 0.02)
            XCTAssertEqual(result.after.audio?.duration ?? 0, 2 / rate, accuracy: 0.03,
                           "the sound is as long as the picture at \(rate)×")
        }
    }

    func testASpeedChangeKeepsItsSubtitlesInTime() async throws {
        let subtitled = out("subtitled.mov")
        try await VideoForge.addSubtitles(
            [Subtitles(cues: [SubtitleCue(start: 0.5, end: 1.5, text: "Hello")], language: "en")],
            to: clip, destination: subtitled)
        for (name, export) in [("copied.mov", ExportSpec()), ("rated.mov", ExportSpec(bitRate: 800_000))] {
            let result = try await process(subtitled, name, [.speed(2)], export)
            XCTAssertEqual(result.lostTracks, [], name)
            let tracks = try await VideoForge.subtitles(in: result.destination)
            XCTAssertEqual(tracks.first?.cues.first?.text, "Hello", name)
        }
    }

    func testSpeedAndABitrateCompose() async throws {
        let result = try await process(clip, "fast.mov", [.speed(2)], ExportSpec(bitRate: 500_000))
        XCTAssertEqual(result.after.duration, 1, accuracy: 0.02)
        XCTAssertEqual(result.after.audio?.duration ?? 0, 1, accuracy: 0.03)
    }

    // MARK: - Join

    func testAJoinTakesAFrameRate() async throws {
        let second = out("second.mov")
        try await TestClips.writeMovie(to: second, seconds: 1, hue: 0.6)
        let result = try await VideoForge.join([clip, second], to: out("joined.mov"),
                                               export: ExportSpec(frameRate: 10))
        let times = try await TestClips.frameTimes(of: result.destination)
        XCTAssertEqual(times.count, 30)
        XCTAssertEqual(result.after.duration, 3, accuracy: 0.02)
        XCTAssertEqual(result.after.audio?.duration ?? 0, 3, accuracy: 0.05)
    }

    func testClipsOfDifferentSizesJoinAtOneSize() async throws {
        // MEASURED: exported with no video composition, a join of a 640×360
        // and a 1280×720 clip wrote one sample description per size, and
        // ffmpeg could not decode past the first clip.
        let big = out("big.mov")
        try await TestClips.writeMovie(to: big, seconds: 1, width: 640, height: 480)
        let result = try await VideoForge.join([clip, big], to: out("mixed.mov"))
        let track = try await AVURLAsset(url: result.destination).loadTracks(withMediaType: .video)[0]
        let descriptions = try await track.load(.formatDescriptions)
        XCTAssertEqual(descriptions.count, 1)
        XCTAssertEqual(result.after.width, 320, "the first clip's size")
    }

    // MARK: - Reverse

    func testAReversedPhoneClipStaysUpright() async throws {
        // A clip stored sideways with a transform saying so, as a phone
        // held upright writes it. Up to 0.4.0 the transform was dropped.
        let stored = out("stored.mov")
        try await TestClips.writeVideo(to: stored, seconds: 1)
        let composition = AVMutableComposition()
        let asset = AVURLAsset(url: stored)
        let source = try await asset.loadTracks(withMediaType: .video)[0]
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)),
                                  of: source, at: .zero)
        track.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let phone = out("phone.mov")
        try await Composer.export(composition, to: phone, container: .mov,
                                  preset: AVAssetExportPresetPassthrough)
        let before = try await VideoForge.describe(phone)
        XCTAssertEqual(before.width, 240, "shown upright")
        let result = try await VideoForge.reverse(phone, to: out("reversed.mov"))
        XCTAssertEqual(result.after.width, 240)
        XCTAssertEqual(result.after.height, 320)
    }

    // MARK: - The pump

    func testAFeedsErrorStopsTheJobAndRemovesTheFile() async throws {
        let url = out("broken.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        writer.add(input)
        struct Broken: Error {}
        let feed = WriterFeed(input: input) { throw Broken() }
        do {
            try await WriterPump.run(WriterJob(reader: nil, writer: writer, feeds: [feed]))
            XCTFail("the feed's error comes out")
        } catch {
            XCTAssertTrue(error is Broken, "as thrown, not wrapped")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
