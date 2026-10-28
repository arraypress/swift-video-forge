//
//  SceneTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Shot changes and quiet stretches: the rules on made-up measures, then the
//  scan on drawn clips whose cuts are known to the frame.
//

import AVFoundation
import CoreGraphics
import XCTest
@testable import VideoForge

final class SceneTests: XCTestCase {

    // MARK: Measures

    /// A histogram with everything in one bin, nudged by `noise` into the next.
    private func spike(_ bin: Int, noise: Float = 0) -> [Float] {
        var values = [Float](repeating: 0, count: SceneCuts.bins)
        values[bin] = 1 - noise
        values[(bin + 1) % SceneCuts.bins] = noise
        return values
    }

    func testHistogramSumsToOneAndSortsColours() {
        var pixels = [UInt8](repeating: 0, count: 4 * 4)
        // BGRA: red, red, green, blue.
        pixels.replaceSubrange(0..<16, with: [0, 0, 255, 255, 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255])
        let histogram = pixels.withUnsafeBufferPointer {
            SceneCuts.histogram($0.baseAddress!, width: 4, height: 1, bytesPerRow: 16)
        }
        XCTAssertEqual(histogram.reduce(0, +), 1, accuracy: 1e-6)
        XCTAssertEqual(histogram[SceneCuts.bin(blue: 0, green: 0, red: 255)], 0.5, accuracy: 1e-6)
        XCTAssertNotEqual(SceneCuts.bin(blue: 0, green: 255, red: 0), SceneCuts.bin(blue: 255, green: 0, red: 0))
        XCTAssertNotEqual(SceneCuts.bin(blue: 0, green: 0, red: 64), SceneCuts.bin(blue: 0, green: 0, red: 255),
                          "a dark red and a bright red are different values")
    }

    func testDistanceRunsFromNothingToEverything() {
        XCTAssertEqual(SceneCuts.distance(spike(3), spike(3)), 0)
        XCTAssertEqual(SceneCuts.distance(spike(3), spike(40)), 1, accuracy: 1e-6)
        XCTAssertEqual(SceneCuts.distance(spike(3), spike(3, noise: 0.25)), 0.25, accuracy: 1e-6)
    }

    // MARK: Cuts

    /// 30 frames a second: `shots` back to back, each frame jittering by
    /// `jitter` the way grain and motion do.
    private func run(_ shots: [(bin: Int, frames: Int)], jitter: Float = 0.02) -> (times: [Double], histograms: [[Float]]) {
        var histograms: [[Float]] = []
        for shot in shots {
            for frame in 0..<shot.frames { histograms.append(spike(shot.bin, noise: frame % 2 == 0 ? 0 : jitter)) }
        }
        return (histograms.indices.map { Double($0) / 30 }, histograms)
    }

    func testACutLandsOnTheFirstFrameOfTheNewShot() {
        let (times, histograms) = run([(3, 75), (40, 60)])
        let cuts = SceneCuts.cuts(times: times, histograms: histograms, rate: 30)
        XCTAssertEqual(cuts.map(\.time), [2.5])
        XCTAssertEqual(cuts.first?.kind, .cut)
    }

    func testAFirstFrameThatDiffersIsNotACut() {
        // A still clip whose first encoded frame sits a little apart from
        // the rest: measured on a real H.264 encode, 0.024 against 0.
        var (times, histograms) = run([(3, 90)], jitter: 0)
        histograms[0] = spike(3, noise: 0.03)
        XCTAssertEqual(SceneCuts.cuts(times: times, histograms: histograms, rate: 30).count, 0)
        histograms[0] = spike(3)
        histograms[89] = spike(3, noise: 0.03)
        XCTAssertEqual(SceneCuts.cuts(times: times, histograms: histograms, rate: 30).count, 0, "nor a last one")
    }

    /// A histogram with its mass `position` bins along, split between two
    /// neighbouring bins — a picture that keeps moving, like a pan.
    private func drifting(_ position: Double) -> [Float] {
        var values = [Float](repeating: 0, count: SceneCuts.bins)
        let low = Int(position), fraction = Float(position - Double(low))
        values[low % SceneCuts.bins] = 1 - fraction
        values[(low + 1) % SceneCuts.bins] += fraction
        return values
    }

    func testInMovingFootageAJumpOnlyAFewTimesTheMotionIsNotACut() {
        // Every frame moves 0.05; one moves 0.15 — 3× the motion. The picture keeps changing, so the change
        // persists: only the ratio can say this is motion.
        var position = 0.0
        var histograms: [[Float]] = []
        for frame in 0..<60 {
            position += frame == 30 ? 0.15 : 0.05
            histograms.append(drifting(position))
        }
        let cuts = SceneCuts.cuts(times: histograms.indices.map { Double($0) / 30 }, histograms: histograms, rate: 30)
        XCTAssertEqual(cuts, [])
    }

    func testABusyStretchNeedsAJumpWellAboveItsOwnMotion() {
        // Every step moves 0.3 (fast motion); a jump to 0.9 is 3× that — under the ratio.
        var histograms: [[Float]] = []
        for frame in 0..<60 { histograms.append(spike(3, noise: frame % 2 == 0 ? 0 : 0.3)) }
        var jump = spike(3, noise: 0.3); jump[3] = 0.1; jump[50] = 0.6; jump[4] = 0.3
        histograms.insert(jump, at: 30)
        let cuts = SceneCuts.cuts(times: histograms.indices.map { Double($0) / 30 }, histograms: histograms, rate: 30)
        XCTAssertEqual(cuts, [], "a change only a few times the footage's own motion is motion")
    }

    func testAChangeBelowTheFloorIsNotACutHoweverStillTheFootage() {
        // Perfectly still, then a 1% change (a cursor on a held title): the ratio is huge, the change tiny.
        var histograms = Array(repeating: spike(3), count: 30)
        histograms += Array(repeating: spike(3, noise: 0.01), count: 30)
        let cuts = SceneCuts.cuts(times: histograms.indices.map { Double($0) / 30 }, histograms: histograms, rate: 30)
        XCTAssertEqual(cuts, [])
    }

    func testAFlashThatComesBackIsNotACut() {
        let (times, histograms) = run([(3, 40), (60, 2), (3, 40)])
        XCTAssertEqual(SceneCuts.cuts(times: times, histograms: histograms, rate: 30), [])
    }

    func testTwoJumpsInsideAThirdOfASecondAreOneCut() {
        // A new shot, then a second jump 4 frames later (a cut through a one-frame mix).
        var histograms = Array(repeating: spike(3), count: 40)
        histograms += Array(repeating: spike(20), count: 4)
        histograms += Array(repeating: spike(40), count: 40)
        let cuts = SceneCuts.cuts(times: histograms.indices.map { Double($0) / 30 }, histograms: histograms, rate: 30)
        XCTAssertEqual(cuts.count, 1)
    }

    // MARK: Dissolves

    private func spans(peak: Double, at time: Double) -> [(time: Double, distance: Double)] {
        stride(from: 0.0, to: 10, by: 0.25).map { t in
            (t, abs(t - time) < 0.01 ? peak : abs(t - time) < 0.3 ? peak * 0.8 : 0.2)
        }
    }

    func testADissolveIsTheMiddleOfAStrongSecondLongChange() {
        let found = SceneCuts.dissolves(spans: spans(peak: 0.9, at: 5), cuts: [])
        XCTAssertEqual(found.map(\.time), [5])
        XCTAssertEqual(found.first?.kind, .dissolve)
    }

    func testOneOddFingerprintCannotMakeADissolve() {
        // Prints a quarter-second apart, all alike but one (a flash at 1.0 s).
        var ring = FingerprintRing<Double> { abs($0 - $1) }
        var measures: [Double] = []
        for step in 0..<12 {
            let time = Double(step) * 0.25
            if let span = ring.add(time == 1.0 ? 10 : 0, at: time) { measures.append(span.distance) }
        }
        XCTAssertEqual(measures.count, 7)
        XCTAssertEqual(measures.max(), 0, "each measure is the smaller of two pairs; the flash is in one of them at most")
    }

    func testTheDissolveMeasureIsTimedBetweenItsTwoPairs() {
        var ring = FingerprintRing<Double> { abs($0 - $1) }
        var spans: [(time: Double, distance: Double)] = []
        for step in 0..<6 { if let span = ring.add(step < 3 ? 0 : 1, at: Double(step) * 0.25) { spans.append(span) } }
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].time, 0.625, accuracy: 1e-9)
        XCTAssertEqual(spans[0].distance, 1, "before and after differ in both pairs")
    }

    func testALightingChangeIsNotADissolve() {
        // MEASURED: a lighting ramp reached 0.59.
        XCTAssertEqual(SceneCuts.dissolves(spans: spans(peak: 0.6, at: 5), cuts: []), [])
    }

    func testAChangeBesideACutIsTheCuts() {
        let cut = SceneChange(time: 5.1, kind: .cut, strength: 0.5)
        XCTAssertEqual(SceneCuts.dissolves(spans: spans(peak: 0.9, at: 5), cuts: [cut]), [])
    }

    // MARK: Shots and silence

    func testShotsRunBetweenTheChanges() {
        let changes = [SceneChange(time: 2.5, kind: .cut, strength: 0.4), SceneChange(time: 6, kind: .dissolve, strength: 0.9)]
        XCTAssertEqual(SceneCuts.scenes(changes, duration: 10), [0..<2.5, 2.5..<6, 6..<10])
        XCTAssertEqual(SceneCuts.scenes([], duration: 4), [0..<4])
    }

    func testQuietStretchesNeedBothTheLevelAndTheLength() {
        let levels = [-20.0, -60, -60, -60, -20, -60, -20, -50, -50, -50, -50]
        let quiet = SoundRules.quiet(levels, step: 0.25, below: -45, atLeast: 0.5)
        XCTAssertEqual(quiet, [0.25..<1.0, 1.75..<2.75], "one quiet step is not a silence; a run that ends the sound is")
        XCTAssertEqual(SoundRules.dbfs(sumOfSquares: 0, count: 10), LevelSeries.floor)
        XCTAssertEqual(SoundRules.dbfs(sumOfSquares: 10, count: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(SoundRules.dbfs(sumOfSquares: 0.1, count: 10), -20, accuracy: 1e-9)
    }

    // MARK: The scan, end to end

    /// Grainy noise in one colour family per shot, so every frame differs from the last like footage does.
    private static func paint(_ context: CGContext, frame: Int, hue: CGFloat) {
        var state = UInt64(frame &* 2_654_435_761 &+ 1)
        for y in stride(from: 0, to: 360, by: 20) {
            for x in stride(from: 0, to: 640, by: 20) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let jitter = CGFloat((state >> 33) % 100) / 1000
                context.setFillColor(CGColor(red: hue, green: 0.3 + jitter, blue: 1 - hue, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 20, height: 20))
            }
        }
    }

    func testTheScanFindsDrawnCutsOnTheFrameAndIgnoresAFlash() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("shots.mov")
        // Shots change at frames 45 and 90; frames 120–121 are a white flash.
        try await TestClips.writeDrawn(to: url, seconds: 5, fps: 30) { context, frame in
            if frame == 120 || frame == 121 {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                return
            }
            Self.paint(context, frame: frame, hue: frame < 45 ? 0.9 : frame < 90 ? 0.1 : 0.5)
        }
        let report = try await Scenes.detect(url)
        XCTAssertEqual(report.changes.map(\.time), [1.5, 3.0])
        XCTAssertEqual(report.changes.map(\.kind), [.cut, .cut])
        XCTAssertEqual(report.scenes.count, 3)
        XCTAssertEqual(report.framesRead, 150)
    }

    func testSoundLevelsFindTheGapInATone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gap.caf")
        let rate = 48_000.0
        let samples = (0..<Int(rate * 3)).map { index -> Float in
            let t = Double(index) / rate
            return (1.0..<2.0).contains(t) ? 0 : Float(0.3 * sin(2 * .pi * 440 * t))
        }
        try TestClips.writeMono(samples, rate: rate, to: url)
        let levels = try await SoundLevels.measure(url, step: 0.05)
        XCTAssertEqual(levels.duration, 3, accuracy: 0.06)
        let silences = levels.silences(below: -45, atLeast: 0.5)
        XCTAssertEqual(silences.count, 1)
        XCTAssertEqual(silences.first?.lowerBound ?? 0, 1, accuracy: 0.06)
        XCTAssertEqual(silences.first?.upperBound ?? 0, 2, accuracy: 0.06)
        XCTAssertEqual(levels.dbfs[10], -13.5, accuracy: 0.5, "a 0.3 sine is -13.5 dBFS RMS")
    }
}
