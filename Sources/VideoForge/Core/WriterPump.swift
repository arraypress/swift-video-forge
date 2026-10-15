//
//  WriterPump.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Feeding an AVAssetWriter from several inputs without deadlocking it —
//  the one copy of this machinery, used by the writer road, the remuxer,
//  the reverser and swift-censor-kit.
//
//  The writer THROTTLES an input that runs ahead of the others: drain one
//  input to the end before feeding the next and it waits forever for the
//  one it paused. Censor-kit's 4K bug was nine minutes of spinning on an
//  audio input the writer had politely paused. So every input is fed only
//  when the writer asks, through `requestMediaDataWhenReady`.
//
//  Why the callbacks and not the async receivers macOS 26 added:
//  `inputReceiver(for:)`/`outputProvider(for:)` with one task per track
//  deadlocked on a plain two-track H.264/AAC copy, around two seconds in,
//  every time. The callbacks share one serial queue, so they never overlap,
//  and everything they touch sits behind one Mutex — the compiler checks
//  that; nothing here is unchecked.
//
//  Before 0.5.0 there were three of these: the remuxer's, the reverser's
//  single-input loop, and censor-kit's `pump`/`Feed`. This is all three.
//

import AVFoundation
import Foundation
import Synchronization

/// Runs a reader-to-writer job to the end.
public enum WriterPump {

    /// Starts the reader and the writer, feeds every input whenever the
    /// writer asks until each feed's source runs dry, and finishes the file.
    ///
    /// The partial file is removed when anything goes wrong.
    ///
    /// - Parameters:
    ///   - job: The reader, the writer with its inputs added, and the feeds.
    ///   - start: Where the writer's session starts.
    ///   - end: Where it ends, when the inputs might run past it — audio
    ///     through a time-pitch pass pads its end. Nil ends at the last sample.
    /// - Throws: A feed's own error, as thrown;
    ///   ``VideoForgeError/writeFailed(_:reason:)`` when the reader or the
    ///   writer fails; `CancellationError` when the task is cancelled.
    public static func run(_ job: sending WriterJob, from start: CMTime = .zero,
                           until end: CMTime? = nil) async throws {
        let url = job.writer.outputURL
        let shared = Shared(State(job))
        let queue = DispatchQueue(label: "video-forge.writer-pump")

        await withTaskCancellationHandler {
            await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                shared.state.withLock { state in
                    state.finished = finished
                    guard state.start(at: start) else { return }
                    for index in state.feeds.indices {
                        state.feeds[index].feed.input.requestMediaDataWhenReady(on: queue) {
                            shared.state.withLock { $0.pump(index) }
                        }
                    }
                }
            }
        } onCancel: {
            shared.state.withLock { $0.cancel() }
        }

        switch shared.state.withLock({ $0.outcome }) {
        case .cancelled:
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        case .failed(let error):
            shared.state.withLock { $0.abandon() }
            try? FileManager.default.removeItem(at: url)
            throw error
        case .running, .done:
            break
        }
        await withCheckedContinuation { (written: CheckedContinuation<Void, Never>) in
            shared.state.withLock { state in
                if let end { state.writer.endSession(atSourceTime: end) }
                state.writer.finishWriting { written.resume() }
            }
        }
        if let reason = shared.state.withLock({ $0.writerFailure }) {
            try? FileManager.default.removeItem(at: url)
            throw VideoForgeError.writeFailed(url, reason: reason)
        }
    }

    // MARK: - The session

    /// Owns the lock, so the writer's callbacks can share it.
    private final class Shared: Sendable {
        let state: Mutex<State>
        init(_ state: sending State) { self.state = Mutex(state) }
    }

    /// Where a running job stands.
    private enum Outcome: Sendable {
        case running, done, cancelled
        case failed(any Error)
    }

    /// A feed and whether it has finished.
    private struct Entry {
        let feed: WriterFeed
        var isFinished = false
    }

    /// Everything the callbacks touch. Only ever used under the lock.
    private struct State {
        let reader: AVAssetReader?
        let writer: AVAssetWriter
        var feeds: [Entry]
        var finished: CheckedContinuation<Void, Never>?
        var outcome = Outcome.running

        init(_ job: sending WriterJob) {
            reader = job.reader
            writer = job.writer
            feeds = job.feeds.map { Entry(feed: $0) }
        }

        var isRunning: Bool {
            if case .running = outcome { return true }
            return false
        }

        /// Starts reading and writing; false when either refuses, or the
        /// task was cancelled first.
        mutating func start(at time: CMTime) -> Bool {
            guard isRunning else { return stop(outcome) }
            if let reader, !reader.startReading() {
                return stop(.failed(failure(reader.error, "the source could not be read")))
            }
            guard writer.startWriting() else {
                return stop(.failed(failure(writer.error, "the writer would not start")))
            }
            writer.startSession(atSourceTime: time)
            if feeds.isEmpty { return stop(.done) }
            return true
        }

        /// Feeds one input until the writer wants no more for now.
        mutating func pump(_ index: Int) {
            guard isRunning, !feeds[index].isFinished else { return }
            let input = feeds[index].feed.input
            while input.isReadyForMoreMediaData {
                let more: Bool
                do {
                    more = try feeds[index].feed.step()
                } catch {
                    _ = stop(.failed(error))
                    return
                }
                if writer.status == .failed {
                    _ = stop(.failed(failure(writer.error, "the writer refused a sample")))
                    return
                }
                guard more else {
                    if let reader, reader.status == .failed {
                        _ = stop(.failed(failure(reader.error, "reading the source failed")))
                        return
                    }
                    feeds[index].isFinished = true
                    input.markAsFinished()
                    if feeds.allSatisfy(\.isFinished) { _ = stop(.done) }
                    return
                }
            }
        }

        /// Stops reading and writing after a cancel.
        mutating func cancel() {
            guard isRunning else { return }
            abandon()
            _ = stop(.cancelled)
        }

        /// Cleans up after a failure.
        func abandon() {
            if let reader, reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }

        /// Why the finished file is no good, if it is not.
        var writerFailure: String? {
            writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "the writer did not finish")
        }

        /// The error for a reader or writer failure.
        func failure(_ error: (any Error)?, _ fallback: String) -> VideoForgeError {
            .writeFailed(writer.outputURL, reason: error?.localizedDescription ?? fallback)
        }

        /// Records how it ended — the first ending wins — and wakes the
        /// waiting task, once. Returns false so `start` can end with it.
        mutating func stop(_ result: Outcome) -> Bool {
            if isRunning { outcome = result }
            finished?.resume()
            finished = nil
            return false
        }
    }
}
