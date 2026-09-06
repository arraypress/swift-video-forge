//
//  ReverseTests.swift
//  VideoForge
//
//  Created by David Sherlock @ ArrayPress
//
//  The fixture's bar marches left to right, so which frame you are looking
//  at is readable from the pixels. That is what makes a reverse checkable
//  rather than merely plausible — and the check that matters is the one
//  with a budget small enough to force several chunks, because a chunked
//  reverse that forgets to reverse the CHUNK ORDER produces forward-playing
//  segments in backward order and looks almost right.
//

import AVFoundation
import CoreImage
import XCTest
@testable import VideoForge

final class ReverseTests: XCTestCase {

    var directory: URL!
    var clip: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        clip = directory.appendingPathComponent("clip.mov")
        try await TestClips.writeVideo(to: clip, seconds: 2, fps: 15, width: 160, height: 120)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// How far along the bar is, 0 at the left edge and 1 at the right.
    /// Reading it back is what turns "it reversed" into a measurement.
    func barPosition(in url: URL, atSecond second: Double) async throws -> Double {
        let frames = try await Frames.at(url, times: [second])
        let image = try XCTUnwrap(frames.first?.image)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // The bar is the only strongly red thing in the frame.
        let row = height / 2
        var columns: [Int] = []
        for x in 0..<width {
            let offset = row * width * 4 + x * 4
            if pixels[offset] > 150, pixels[offset + 1] < 120 { columns.append(x) }
        }
        guard !columns.isEmpty else { return -1 }
        let middle = Double(columns.reduce(0, +)) / Double(columns.count)
        return middle / Double(width)
    }

    func testTheFixtureMarchesLeftToRight() async throws {
        let early = try await barPosition(in: clip, atSecond: 0.1)
        let late = try await barPosition(in: clip, atSecond: 1.8)
        XCTAssertLessThan(early, late, "the fixture has to move for any of this to mean anything")
        XCTAssertLessThan(early, 0.35)
        XCTAssertGreaterThan(late, 0.6)
    }

    func testReversingPlaysItBackwards() async throws {
        let result = try await VideoForge.reverse(clip, to: out("back.mov"))
        XCTAssertEqual(result.after.duration, 2, accuracy: 0.2)

        let early = try await barPosition(in: out("back.mov"), atSecond: 0.1)
        let late = try await barPosition(in: out("back.mov"), atSecond: 1.8)
        XCTAssertGreaterThan(early, late, "reversed, the bar marches right to left")
        XCTAssertGreaterThan(early, 0.6, "it starts where the original ended")
    }

    func testAChunkedReverseIsStillATrueReverse() async throws {
        // The failure this exists for: reversing each chunk but joining them
        // in FORWARD order gives backward segments playing forwards, which
        // looks nearly right and is completely wrong. A budget of a few
        // frames forces many chunks.
        let perFrame = 160 * 120 * 4
        let result = try await VideoForge.reverse(clip, to: out("chunked.mov"),
                                                  budget: perFrame * 4)
        XCTAssertEqual(result.after.duration, 2, accuracy: 0.25)

        let positions = try await [0.1, 0.6, 1.1, 1.7].asyncMap {
            try await barPosition(in: out("chunked.mov"), atSecond: $0)
        }
        for (earlier, later) in zip(positions, positions.dropFirst()) {
            XCTAssertGreaterThan(earlier, later,
                                 "every sample must be further left than the one before: \(positions)")
        }
    }

    func testTheChunkPlanFitsTheBudget() {
        let info = VideoInfo(duration: 10, width: 1920, height: 1080, frameRate: 30,
                             container: .mov, byteCount: 0, tracks: [], isRotated: false)
        let budget = 100 * 1_048_576
        let chunks = Reverser.plan(info: info, budget: budget)

        XCTAssertGreaterThan(chunks.count, 1, "a 4K-ish clip does not fit in 100 MB")
        for chunk in chunks {
            let frames = Int(chunk.duration.seconds * info.frameRate) + 1
            XCTAssertLessThanOrEqual(Frames.memoryCost(size: info.size, count: frames),
                                     budget * 2, "a chunk must roughly fit the budget")
        }
        let total = chunks.reduce(0.0) { $0 + $1.duration.seconds }
        XCTAssertEqual(total, info.duration, accuracy: 0.01, "the chunks must cover the clip exactly")
    }

    func testASilentClipReversesWithoutComplaint() async throws {
        let result = try await VideoForge.reverse(clip, to: out("silent.mov"), keepsAudio: true)
        XCTAssertFalse(result.after.hasAudio, "there was no sound to reverse")
        XCTAssertTrue(result.after.hasVideo)
    }

    func testSoundIsReversedTooWhenThereIsSome() async throws {
        let withSound = out("sound.mov")
        try await TestClips.writeMovie(to: withSound, seconds: 1, fps: 15, width: 160, height: 120)
        let result = try await VideoForge.reverse(withSound, to: out("sound-back.mov"))
        XCTAssertTrue(result.after.hasAudio, "a reversed picture with forward sound is worse than silence")
        XCTAssertEqual(result.after.duration, 1, accuracy: 0.2)
    }
}

extension Array {
    /// `map` for an async transform, which the standard library still lacks.
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
