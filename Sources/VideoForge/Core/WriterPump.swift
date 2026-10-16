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
//  THE WATCHDOG (0.7.1). On macOS 27 an `AVAssetReader` can stop for good
//  inside `copyNextSampleBuffer` (found in swift-caption-kit 0.8.1 on edited
//  compositions: the call blocks in `FigSemaphoreWaitRelative` and never
//  returns). A feed's step runs under the lock, on the one queue, so a step
//  that never returns used to be a job that never ended — and a cancel that
//  never returned either, waiting for the lock. Now a step blocked past
//  ``stallLimit`` ends the job: the waiting task is woken from outside the
//  lock, the stuck reader is LEFT ALONE (cancelling one mid-read crashed
//  inside AVFoundation in 2 of 8 tries in caption-kit's probe), and if the
//  read ever comes back the job is abandoned there and then, so it can never
//  finish a file over a retry's. Jobs that can be built again are run twice
//  (``retryingStall(_:_:)``); a second stall is an error, never a hang.
//

import AVFoundation
import Foundation
import Synchronization

/// Runs a reader-to-writer job to the end.
public enum WriterPump {

    /// How long one feed step — one `copyNextSampleBuffer`, most often — may
    /// block before the job is called stalled. A frame never takes this long.
    public static let stallLimit: Duration = .seconds(30)

    /// Steps that blocked past the limit in this process — for tests, which
    /// must tell a retried stall from a slow run.
    static let stalls = Atomic<Int>(0)

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
    ///   writer fails, or a step blocks past ``stallLimit``;
    ///   `CancellationError` when the task is cancelled.
    public static func run(_ job: sending WriterJob, from start: CMTime = .zero,
                           until end: CMTime? = nil) async throws {
        let url = job.writer.outputURL
        do {
            try await runOnce(job, from: start, until: end)
        } catch is Stall {
            throw stalledError(url, times: 1)
        }
    }

    /// Runs `attempt` — which builds a job and runs it with ``runOnce`` —
    /// once more when a step stalls; a second stall is
    /// ``VideoForgeError/writeFailed(_:reason:)``.
    ///
    /// - Parameters:
    ///   - url: The file the job writes, removed after a stalled attempt.
    ///   - attempt: Builds the job afresh and runs it.
    static func retryingStall(_ url: URL, _ attempt: () async throws -> Void) async throws {
        for tries in 1...2 {
            do {
                return try await attempt()
            } catch is Stall {
                try? FileManager.default.removeItem(at: url)
                if tries == 2 { throw stalledError(url, times: 2) }
            }
        }
    }

    /// A step that blocked past the limit; the job was left where it stood.
    struct Stall: Error {}

    private static func stalledError(_ url: URL, times: Int) -> VideoForgeError {
        let seconds = Int(stallLimit.components.seconds)
        return .writeFailed(url, reason: times == 1
            ? "the source stopped delivering samples for \(seconds) s"
            : "the source stopped delivering samples for \(seconds) s, twice")
    }

    /// ``run(_:from:until:)``, throwing ``Stall`` for a stalled step so the
    /// caller can build the job again.
    ///
    /// - Parameter limit: How long a step may block; ``stallLimit`` but in tests.
    static func runOnce(_ job: sending WriterJob, from start: CMTime = .zero,
                        until end: CMTime? = nil, limit: Duration = stallLimit) async throws {
        let url = job.writer.outputURL
        let watch = Watch()
        let shared = Shared(State(job, watch: watch))
        let queue = DispatchQueue(label: "video-forge.writer-pump")
        let watchdog = watch.startWatchdog(limit: limit)
        defer { watchdog.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                watch.waiting.withLock { $0 = finished }
                shared.state.withLock { state in
                    guard state.start(at: start) else { return }
                    for index in state.feeds.indices {
                        state.feeds[index].feed.input.requestMediaDataWhenReady(on: queue) {
                            shared.state.withLock { $0.pump(index) }
                        }
                    }
                }
            }
        } onCancel: {
            // A pump inside a step holds the lock — maybe for good. The flag
            // stops it when the step returns; the watchdog, when it does not.
            watch.cancelled.store(true, ordering: .sequentiallyConsistent)
            _ = shared.state.withLockIfAvailable { $0.cancel() }
        }

        // Stalled: the stuck pump holds the lock, so nothing here touches it.
        if watch.stalled.load(ordering: .sequentiallyConsistent) {
            stalls.add(1, ordering: .relaxed)
            try? FileManager.default.removeItem(at: url)
            if watch.cancelled.load(ordering: .sequentiallyConsistent) { throw CancellationError() }
            throw Stall()
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

    // MARK: - The watch

    /// What the watchdog and a cancel share with the pump without its lock.
    private final class Watch: Sendable {
        /// The waiting task, woken once: by the end of the job, or by the
        /// watchdog.
        let waiting = Mutex<CheckedContinuation<Void, Never>?>(nil)
        /// When the step now running began, in uptime nanoseconds; 0 between steps.
        let stepSince = Atomic<UInt64>(0)
        let stalled = Atomic<Bool>(false)
        let cancelled = Atomic<Bool>(false)

        func wake() {
            waiting.withLock { $0.take() }?.resume()
        }

        /// Checks once a second for a step blocked past `limit`.
        func startWatchdog(limit: Duration) -> DispatchSourceTimer {
            let nanos = UInt64(limit.components.seconds) * 1_000_000_000
                + UInt64(limit.components.attoseconds / 1_000_000_000)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "video-forge.writer-pump.watchdog"))
            let tick = min(Duration.seconds(1), limit / 4)
            let tickNanos = Int(tick.components.seconds) * 1_000_000_000 + Int(tick.components.attoseconds / 1_000_000_000)
            timer.schedule(deadline: .now() + .nanoseconds(tickNanos), repeating: .nanoseconds(tickNanos))
            timer.setEventHandler { [self] in
                let since = stepSince.load(ordering: .sequentiallyConsistent)
                guard since != 0, DispatchTime.now().uptimeNanoseconds - since > nanos else { return }
                guard stalled.compareExchange(expected: false, desired: true,
                                              ordering: .sequentiallyConsistent).exchanged else { return }
                wake()
            }
            timer.resume()
            return timer
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
        let watch: Watch
        var outcome = Outcome.running

        init(_ job: sending WriterJob, watch: Watch) {
            reader = job.reader
            writer = job.writer
            feeds = job.feeds.map { Entry(feed: $0) }
            self.watch = watch
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
            guard isRunning, !feeds[index].isFinished, !watch.stalled.load(ordering: .sequentiallyConsistent) else { return }
            let input = feeds[index].feed.input
            while input.isReadyForMoreMediaData {
                if watch.cancelled.load(ordering: .sequentiallyConsistent) { return cancel() }
                let more: Bool
                watch.stepSince.store(max(1, DispatchTime.now().uptimeNanoseconds), ordering: .sequentiallyConsistent)
                defer { watch.stepSince.store(0, ordering: .sequentiallyConsistent) }
                do {
                    more = try feeds[index].feed.step()
                } catch {
                    _ = stop(.failed(error))
                    return
                }
                // The watchdog gave up on this step while it was blocked, and
                // the job has been reported stalled: it must never finish.
                // The writer is left as it is: cancelling it deletes the file
                // at its URL, which by now may be a retry's.
                if watch.stalled.load(ordering: .sequentiallyConsistent) {
                    if let reader, reader.status == .reading { reader.cancelReading() }
                    outcome = .failed(Stall())
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
            watch.wake()
            return false
        }
    }
}
