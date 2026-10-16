//
//  StallTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The pump's watchdog. On macOS 27 an `AVAssetReader` can block inside
//  `copyNextSampleBuffer` for good (swift-caption-kit 0.8.1); a job fed by
//  one used to be a job that never ended, and a cancel that never returned.
//  These block a feed on purpose and check that the job ends, on time, with
//  the file gone — and that a retry after a stall writes a whole file.
//

import AVFoundation
import Synchronization
import XCTest
@testable import VideoForge

final class StallTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A writer with one small H.264 input, and a feed whose first step
    /// blocks for `blocks` seconds when `blocks` is set — or writes ten
    /// black frames when it is not.
    private static func job(_ url: URL, blocks: Double?) throws -> WriterJob {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        var frame = 0
        let feed = WriterFeed(input: input) {
            if let blocks {
                // Stands in for a reader that never answers.
                _ = DispatchSemaphore(value: 0).wait(timeout: .now() + blocks)
                return false
            }
            guard frame < 10 else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { return false }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            frame += 1
            return true
        }
        return WriterJob(reader: nil, writer: writer, feeds: [feed])
    }

    func testAStepBlockedPastTheLimitEndsTheJob() async throws {
        let url = folder.appendingPathComponent("stuck.mov")
        let started = Date()
        do {
            try await within(10) { try await WriterPump.runOnce(try Self.job(url, blocks: 4), limit: .milliseconds(500)) }
            XCTFail("a stalled step must end the job")
        } catch is WriterPump.Stall {
            XCTAssertLessThan(-started.timeIntervalSinceNow, 3, "ended by the watchdog, not by the step returning")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testAStallIsRetriedOnceAndTheRetryWritesTheFile() async throws {
        let url = folder.appendingPathComponent("retried.mov")
        let before = WriterPump.stalls.load(ordering: .relaxed)
        let attempts = Atomic<Int>(0)
        try await within(20) {
            try await WriterPump.retryingStall(url) {
                let first = attempts.add(1, ordering: .relaxed).newValue == 1
                try await WriterPump.runOnce(try Self.job(url, blocks: first ? 3 : nil), limit: .milliseconds(500))
            }
        }
        XCTAssertEqual(attempts.load(ordering: .relaxed), 2)
        XCTAssertEqual(WriterPump.stalls.load(ordering: .relaxed) - before, 1)
        // The first attempt's step comes back after the retry has started;
        // it must not finish its own file over the retry's.
        try await Task.sleep(for: .seconds(3.5))
        let frames = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.timeRange).duration
        XCTAssertEqual(frames?.seconds ?? 0, 10.0 / 30, accuracy: 0.01, "the retry's ten frames")
    }

    func testTwoStallsAreAnErrorNotAHang() async throws {
        let url = folder.appendingPathComponent("twice.mov")
        do {
            try await within(20) {
                try await WriterPump.retryingStall(url) {
                    try await WriterPump.runOnce(try Self.job(url, blocks: 3), limit: .milliseconds(500))
                }
            }
            XCTFail("a second stall is an error")
        } catch let error as VideoForgeError {
            guard case .writeFailed(_, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("twice"), reason)
        }
    }

    func testACancelDuringAStallReturns() async throws {
        let url = folder.appendingPathComponent("cancelled.mov")
        // Blocked for 6 s with a 1 s limit: the cancel cannot take the stuck
        // step's lock, and must not wait for the step.
        let task = Task { try await WriterPump.runOnce(try Self.job(url, blocks: 6), limit: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        let started = Date()
        do {
            try await within(10) { try await task.value }
            XCTFail("cancelled")
        } catch is CancellationError {
            XCTAssertLessThan(-started.timeIntervalSinceNow, 2.5, "ended by the watchdog, not by the step")
        }
    }
}

/// Runs `body`, failing with `TimedOut` if it has not finished in `seconds` —
/// so a hang is a test failure, not a suite that never ends. A body that
/// never returns is left running.
struct TimedOut: Error {}

func within<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Mutex<CheckedContinuation<T, Error>?>(nil)
    return try await withCheckedThrowingContinuation { continuation in
        once.withLock { $0 = continuation }
        Task {
            do {
                let value = try await body()
                once.withLock { $0.take() }?.resume(returning: value)
            } catch {
                once.withLock { $0.take() }?.resume(throwing: error)
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.withLock { $0.take() }?.resume(throwing: TimedOut())
        }
    }
}
