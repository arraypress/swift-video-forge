//
//  GradeTests.swift
//  VideoForge
//
//  Created by David Sherlock @ ArrayPress
//
//  Colour and tone, applied by VideoGrade at the Core Image seam the render
//  road already uses. The engine has its own tests; what matters here is
//  that a grade reaches the frames, does not disturb the geometry, and
//  animates with the clip rather than freezing on one pattern.
//

import AVFoundation
import CoreImage
import VideoGrade
import XCTest
@testable import VideoForge

final class GradeTests: XCTestCase {

    var directory: URL!
    var clip: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        clip = directory.appendingPathComponent("clip.mov")
        try await TestClips.writeVideo(to: clip, seconds: 1, fps: 15, width: 160, height: 120)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The average brightness of a frame, so a grade can be measured rather
    /// than assumed to have happened.
    func brightness(of url: URL, atSecond second: Double) async throws -> Double {
        let frame = try await Frames.at(url, times: [second])[0].image
        let width = frame.width, height = frame.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let total = stride(from: 0, to: pixels.count, by: 4).reduce(0.0) {
            $0 + Double(pixels[$1]) + Double(pixels[$1 + 1]) + Double(pixels[$1 + 2])
        }
        return total / Double(width * height * 3)
    }

    func testAGradeReachesTheFrames() async throws {
        let before = try await brightness(of: clip, atSecond: 0.5)

        var grade = VideoGrade()
        grade.brightness = 0.3
        let result = try await VideoForge.process(
            clip, to: out("bright.mov"),
            options: VideoProcessOptions(operations: [.grade(grade)]))

        let after = try await brightness(of: out("bright.mov"), atSecond: 0.5)
        XCTAssertGreaterThan(after, before + 5, "brighter means brighter")
        XCTAssertFalse(result.passedThrough, "colour work is not a passthrough")
    }

    func testAGradeLeavesTheGeometryAlone() async throws {
        var grade = VideoGrade()
        grade.contrast = 1.3
        let result = try await VideoForge.process(
            clip, to: out("contrast.mov"),
            options: VideoProcessOptions(operations: [.grade(grade)]))
        XCTAssertEqual(result.after.width, 160)
        XCTAssertEqual(result.after.height, 120)
        XCTAssertEqual(result.after.duration, 1, accuracy: 0.15)
    }

    func testANeutralGradeIsNotBuiltAtAll() throws {
        // Building a filter chain bakes a 32³ colour cube; doing it for a
        // grade that changes nothing would cost every frame for no reason.
        let plan = try Renderer.Plan(operations: [.grade(VideoGrade())],
                                     source: CGSize(width: 100, height: 100))
        XCTAssertNil(plan.grade)
    }

    func testAGradeIsBuiltOnceNotPerFrame() throws {
        var grade = VideoGrade()
        grade.saturation = 0
        let plan = try Renderer.Plan(operations: [.grade(grade)],
                                     source: CGSize(width: 100, height: 100))
        XCTAssertNotNil(plan.grade, "the filter lives on the plan, not in the handler")
    }

    func testAGradeThatCannotBeBuiltStopsTheJob() {
        // A LUT the caller named and that does not load is a mistake worth
        // failing for, not one to silently apply half of.
        var grade = VideoGrade()
        grade.lutURL = URL(fileURLWithPath: "/no/such/look.cube")
        XCTAssertThrowsError(try Renderer.Plan(operations: [.grade(grade)],
                                               source: CGSize(width: 100, height: 100)))
    }

    func testColourComesAfterGeometry() throws {
        // Grading before a crop would compute a vignette and a grain field
        // for pixels about to be discarded, and centre them on the wrong
        // frame. The plan holds both, and `apply` orders them.
        var grade = VideoGrade()
        grade.vignette = 0.5
        let plan = try Renderer.Plan(operations: [.aspect(width: 1, height: 1), .grade(grade)],
                                     source: CGSize(width: 200, height: 100))
        XCTAssertNotNil(plan.crop)
        XCTAssertNotNil(plan.grade)
        XCTAssertEqual(plan.outputSize, CGSize(width: 100, height: 100))
    }

    func testAGradeComposesWithTheRestOfThePipeline() async throws {
        var grade = VideoGrade()
        grade.saturation = 0
        let result = try await VideoForge.process(
            clip, to: out("mono-small.mov"),
            options: VideoProcessOptions(operations: [
                .trim(.until(0.5)),
                .resize(VideoSize(width: 80, height: 80)),
                .grade(grade),
            ]))
        XCTAssertEqual(result.after.width, 80)
        XCTAssertEqual(result.after.duration, 0.5, accuracy: 0.15)
    }

    func testAGradedJobSurvivesJSON() throws {
        var grade = VideoGrade()
        grade.exposure = 0.3
        grade.grain = 0.2
        grade.lutURL = URL(fileURLWithPath: "/looks/warm.cube")

        let options = VideoProcessOptions(
            operations: [.trim(.between(2, 8)), .resize(.height(1080)), .grade(grade)],
            export: ExportSpec(container: .mp4))
        let data = try JSONEncoder().encode(options)
        let back = try JSONDecoder().decode(VideoProcessOptions.self, from: data)
        XCTAssertEqual(back, options)

        guard case .grade(let decoded) = back.operations[2] else { return XCTFail("expected a grade") }
        XCTAssertEqual(decoded.lutURL?.lastPathComponent, "warm.cube",
                       "the LUT travels with the recipe")
    }

    func testGradingIsNotTimeOnly() {
        var grade = VideoGrade()
        grade.contrast = 1.1
        XCTAssertFalse(VideoOperation.grade(grade).isTimeOnly)
        XCTAssertFalse(VideoOperation.grade(grade).changesGeometry)
        XCTAssertEqual(VideoOperation.grade(grade).summary, "grade")
    }
}
