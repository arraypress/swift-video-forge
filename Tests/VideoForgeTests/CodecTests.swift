//
//  CodecTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Every test here READS BACK what was written. Up to 0.3.1 the export
//  spec's codec was read by nobody: `--codec hevc` and `--codec pro-res422`
//  wrote H.264, and a 10-bit HEVC clip came out of a plain resize as 8-bit
//  H.264 — and every test passed, because none of them looked at the codec
//  of the file that came out.
//
//  Depth is checked two ways: the codec (`hvc1`, `apcn`) and the pixels.
//  The deep fixture is a luma ramp with 256 distinct 10-bit levels on a row;
//  anything that squeezes it through 8 bits on the way leaves at most 64.
//

import AVFoundation
import XCTest
@testable import VideoForge

final class CodecTests: XCTestCase {

    var directory: URL!
    /// 8-bit H.264 with sound.
    var clip: URL!
    /// 10-bit HEVC Main 10, a luma ramp, silent and untagged.
    var deep: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        clip = directory.appendingPathComponent("clip.mov")
        try await TestClips.writeMovie(to: clip, seconds: 1)
        deep = directory.appendingPathComponent("deep.mov")
        try await TestClips.writeDeepVideo(to: deep, seconds: 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The four-character code each codec is read back as.
    let written: [VideoCodec: String] = [
        .h264: "avc1", .hevc: "hvc1", .hevcAlpha: "hvc1", .proRes422: "apcn", .proRes4444: "ap4h",
    ]

    // MARK: - The fixtures are what they claim

    func testTheDeepFixtureIsTenBit() async throws {
        let info = try await VideoForge.describe(deep)
        XCTAssertEqual(info.video?.codec, "hvc1")
        XCTAssertTrue(info.isDeep)
        let levels = try await TestClips.lumaLevels(in: deep)
        XCTAssertGreaterThan(levels, 200, "the ramp holds ~256 levels")
    }

    // MARK: - The codec asked for is the codec written

    func testEveryCodecIsWrittenWhenFramesAreRedrawn() async throws {
        for (codec, fourCC) in written {
            let result = try await VideoForge.process(clip, to: out("redrawn-\(codec.rawValue).mov"),
                options: VideoProcessOptions(operations: [.resize(.height(120))],
                                             export: ExportSpec(codec: codec)))
            XCTAssertEqual(result.after.video?.codec, fourCC, "\(codec) on the render road")
            XCTAssertEqual(result.after.height, 120)
        }
    }

    func testEveryCodecIsWrittenWhenOnlyTimeChanges() async throws {
        for (codec, fourCC) in written where codec != .h264 {
            let result = try await VideoForge.process(clip, to: out("trimmed-\(codec.rawValue).mov"),
                options: VideoProcessOptions(operations: [.trim(.until(0.5))],
                                             export: ExportSpec(codec: codec)))
            XCTAssertEqual(result.after.video?.codec, fourCC, "\(codec) on the composition road")
            XCTAssertFalse(result.passedThrough, "a new codec is a re-encode")
            XCTAssertEqual(result.after.duration, 0.5, accuracy: 0.05)
        }
    }

    func testAskingForTheCodecTheClipAlreadyHasStillPassesThrough() async throws {
        let result = try await VideoForge.process(deep, to: out("same.mov"),
            options: VideoProcessOptions(operations: [.trim(.until(0.5))],
                                         export: ExportSpec(codec: .hevc)))
        XCTAssertTrue(result.passedThrough)
        XCTAssertEqual(result.after.video?.codec, "hvc1")
        XCTAssertTrue(result.after.isDeep)
    }

    // MARK: - Ten bits in, ten bits out

    func testARedrawOfTenBitFootageStaysTenBit() async throws {
        // The default codec, on the road that redraws: the case that wrote
        // 8-bit H.264 before, with no codec asked for at all.
        let result = try await VideoForge.process(deep, to: out("turned.mov"),
            options: VideoProcessOptions(operations: [.flip(.vertical)]))
        XCTAssertEqual(result.after.video?.codec, "hvc1")
        XCTAssertTrue(result.after.isDeep)
        let levels = try await TestClips.lumaLevels(in: result.destination)
        XCTAssertGreaterThan(levels, 200, "8 bits would leave at most 64")
    }

    func testProResKeepsTenBits() async throws {
        let result = try await VideoForge.process(deep, to: out("edit.mov"),
            options: VideoProcessOptions(operations: [.flip(.vertical)],
                                         export: ExportSpec(codec: .proRes422)))
        XCTAssertEqual(result.after.video?.codec, "apcn")
        // MEASURED: 164 of the ramp's 256 levels — ProRes is lossy, and the
        // ramp moves less than a level a pixel — against at most 64 for any
        // 8-bit path.
        let levels = try await TestClips.lumaLevels(in: result.destination)
        XCTAssertGreaterThan(levels, 128, "8 bits would leave at most 64")
    }

    func testAnUntaggedRedrawKeepsItsBrightness() async throws {
        // MEASURED: before the composition was tagged Rec. 709, ProRes wrote
        // an untagged source's redrawn frames 27–39 codes brighter. A flip
        // keeps every value on the row, only in the other order.
        for codec in [VideoCodec.hevc, .proRes422] {
            let result = try await VideoForge.process(deep, to: out("flip-\(codec.rawValue).mov"),
                options: VideoProcessOptions(operations: [.flip(.horizontal)],
                                             export: ExportSpec(codec: codec)))
            let before = try await TestClips.middleRow(of: deep)
            let after = try await TestClips.middleRow(of: result.destination)
            let mean = { (row: [Int]) in Double(row.reduce(0, +)) / Double(max(1, row.count)) }
            XCTAssertEqual(mean(after), mean(before), accuracy: 3, "\(codec)")
        }
    }

    func testTenBitIntoAnEightBitCodecIsRefused() async {
        for codec in [VideoCodec.h264, .hevcAlpha] {
            for operations in [[VideoOperation.trim(.until(0.5))], [.resize(.height(120))]] {
                let destination = out("truncated-\(codec.rawValue).mov")
                do {
                    _ = try await VideoForge.process(deep, to: destination,
                        options: VideoProcessOptions(operations: operations,
                                                     export: ExportSpec(codec: codec)))
                    XCTFail("\(codec) should have been refused")
                } catch let error as VideoForgeError {
                    XCTAssertEqual(error, .wouldTruncateDepth(codec: codec))
                } catch { XCTFail("got \(error)") }
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                               "refused before anything was written")
            }
        }
    }

    func testAReverseOfTenBitFootageStaysTenBit() async throws {
        let result = try await VideoForge.reverse(deep, to: out("backwards.mov"))
        XCTAssertEqual(result.after.video?.codec, "hvc1")
        XCTAssertTrue(result.after.isDeep)
        let levels = try await TestClips.lumaLevels(in: result.destination)
        XCTAssertGreaterThan(levels, 200)
    }

    func testAReverseWritesTheCodecAsked() async throws {
        let result = try await VideoForge.reverse(clip, to: out("backwards-hevc.mov"), codec: .hevc)
        XCTAssertEqual(result.after.video?.codec, "hvc1")
        do {
            _ = try await VideoForge.reverse(deep, to: out("backwards-h264.mov"), codec: .h264)
            XCTFail("should have been refused")
        } catch let error as VideoForgeError {
            XCTAssertEqual(error, .wouldTruncateDepth(codec: .h264))
        }
    }

    func testAJoinWritesTheCodecAsked() async throws {
        let result = try await VideoForge.join([clip, clip], to: out("joined.mov"),
                                               export: ExportSpec(codec: .hevc))
        XCTAssertEqual(result.after.video?.codec, "hvc1")
    }

    func testAJoinWithOneTenBitClipIsWrittenTenBit() async throws {
        // The first clip is 8-bit H.264; "source" must still not drop the
        // second one's depth.
        let result = try await VideoForge.join([clip, deep], to: out("mixed.mov"))
        XCTAssertEqual(result.after.video?.codec, "hvc1")
        XCTAssertTrue(result.after.isDeep)
        do {
            _ = try await VideoForge.join([clip, deep], to: out("mixed-h264.mov"),
                                          export: ExportSpec(codec: .h264))
            XCTFail("should have been refused")
        } catch let error as VideoForgeError {
            XCTAssertEqual(error, .wouldTruncateDepth(codec: .h264))
        }
    }

    func testMusicUnderTenBitFootageLeavesItTenBit() async throws {
        let music = out("music.caf")
        try TestClips.writeAudio(to: music, seconds: 2)
        let result = try await VideoForge.addAudio(to: deep, music: music, destination: out("scored.mov"))
        XCTAssertEqual(result.after.video?.codec, "hvc1")
        XCTAssertTrue(result.after.isDeep)
        XCTAssertTrue(result.after.hasAudio)
    }

    // MARK: - ProRes is QuickTime only

    func testProResIntoMP4IsRefused() async {
        let destination = out("edit.mp4")
        do {
            _ = try await VideoForge.process(clip, to: destination,
                options: VideoProcessOptions(operations: [.resize(.height(120))],
                                             export: ExportSpec(codec: .proRes422)))
            XCTFail("should have been refused")
        } catch let error as VideoForgeError {
            XCTAssertEqual(error, .codecNeedsContainer(codec: .proRes422, container: .mp4))
        } catch { XCTFail("got \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTheContainerFollowsTheCodec() throws {
        let mov = URL(fileURLWithPath: "/tmp/a.mov"), mp4 = URL(fileURLWithPath: "/tmp/a.mp4")
        // Inherited from an .mp4 source, ProRes moves into .mov.
        XCTAssertEqual(try CodecPlan.container(explicit: nil, destination: nil, inherited: .mp4,
                                               codec: .proRes4444), .mov)
        // Named by the destination or asked for, it is refused instead.
        XCTAssertThrowsError(try CodecPlan.container(explicit: nil, destination: mp4, inherited: .mov,
                                                     codec: .proRes422))
        XCTAssertThrowsError(try CodecPlan.container(explicit: .m4v, destination: nil, inherited: .mov,
                                                     codec: .proRes422))
        // The destination's extension beats the source's container.
        XCTAssertEqual(try CodecPlan.container(explicit: nil, destination: mov, inherited: .mp4,
                                               codec: .hevc), .mov)
        XCTAssertEqual(try CodecPlan.container(explicit: .mp4, destination: mov, inherited: .mov,
                                               codec: .hevc), .mp4, "asked for by name wins")
        XCTAssertEqual(try CodecPlan.container(explicit: nil, destination: nil, inherited: .mp4,
                                               codec: .h264), .mp4)
    }

    // MARK: - The decisions, without a file

    func testSourceResolvesToTheClipsOwnCodec() {
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "avc1", deep: false), .h264)
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "hvc1", deep: true), .hevc)
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "apch", deep: true), .proRes422)
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "ap4h", deep: true), .proRes4444)
        // A codec this library cannot write: HEVC when deep, H.264 when not.
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "av01", deep: true), .hevc)
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "vp09", deep: false), .h264)
        // An 8-bit codec holding deep footage (possible with H.264 High 10)
        // is not written back as 8-bit.
        XCTAssertEqual(CodecPlan.resolve(.source, sourceCodec: "avc1", deep: true), .hevc)
        // Asked for by name, it is what it says.
        XCTAssertEqual(CodecPlan.resolve(.proRes422, sourceCodec: "avc1", deep: false), .proRes422)
    }

    func testEachCodecHasItsOwnPreset() {
        XCTAssertEqual(CodecPlan.preset(for: .h264), AVAssetExportPresetHighestQuality)
        XCTAssertEqual(CodecPlan.preset(for: .hevc), AVAssetExportPresetHEVCHighestQuality)
        XCTAssertEqual(CodecPlan.preset(for: .hevcAlpha), AVAssetExportPresetHEVCHighestQualityWithAlpha)
        XCTAssertEqual(CodecPlan.preset(for: .proRes422), AVAssetExportPresetAppleProRes422LPCM)
        XCTAssertEqual(CodecPlan.preset(for: .proRes4444), AVAssetExportPresetAppleProRes4444LPCM)
        XCTAssertEqual(Set(VideoCodec.allCases.filter { $0 != .source }.map(CodecPlan.preset(for:))).count, 5,
                       "no two codecs share a preset")
    }

    func testOnlyTheDeepCodecsCountAsDeep() {
        // MEASURED: HEVC with alpha writes HEVC Main — 8-bit.
        XCTAssertEqual(Set(VideoCodec.allCases.filter(\.isDeep)), [.hevc, .proRes422, .proRes4444])
    }

    func testCodecsAreNamedTheWaysPeopleTypeThem() {
        XCTAssertEqual(VideoCodec.named("pro-res422"), .proRes422)
        XCTAssertEqual(VideoCodec.named("ProRes4444"), .proRes4444)
        XCTAssertEqual(VideoCodec.named("hevc-alpha"), .hevcAlpha)
        XCTAssertEqual(VideoCodec.named("hevc_alpha"), .hevcAlpha)
        XCTAssertEqual(VideoCodec.named("H264"), .h264)
        XCTAssertNil(VideoCodec.named("vp9"))
    }
}
