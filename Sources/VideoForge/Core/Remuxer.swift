//
//  Remuxer.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The road for adding a track without touching the others: every source
//  track is copied sample for sample through a reader and a writer, and the
//  new tracks are written beside them. Measured on a 90 s 1080p H.264 clip
//  with B-frames: video and audio packets MD5-identical to the source, every
//  timestamp identical, under a second on a warm cache.
//
//  Why not the composition road (Composer): a passthrough export writes
//  every track with alternate group 0, and a subtitle track outside an
//  alternate group is never offered by a player — the legible
//  media-selection group comes back empty. A writer can group its inputs.
//
//  Why the callback feeding and not the async receivers macOS 26 added:
//  `inputReceiver(for:)`/`outputProvider(for:)` with one task per track
//  deadlocked on a plain two-track H.264/AAC copy, around two seconds in,
//  every time. The callbacks share one serial queue, so they never overlap,
//  and everything they touch sits behind one Mutex — the compiler checks
//  that; nothing here is unchecked.
//

import AVFoundation
import Foundation
import Synchronization

/// Copies a movie's tracks untouched and writes new ones beside them.
enum Remuxer {

    /// A source track to carry across, with what was read about it.
    struct CopiedTrack: Sendable {
        let trackID: CMPersistentTrackID
        let mediaType: AVMediaType
        let format: CMFormatDescription?
        let transform: CGAffineTransform
        let languageCode: String?
        let extendedLanguageTag: String?
        let isEnabled: Bool
    }

    /// A track written from samples made here.
    struct MadeTrack: Sendable {
        let mediaType: AVMediaType
        let format: CMFormatDescription
        let languageCode: String
        let extendedLanguageTag: String?
        let isDefault: Bool
        let samples: [Sample]
    }

    /// One made sample: when it shows, and its bytes.
    struct Sample: Sendable {
        let range: CMTimeRange
        let data: Data
    }

    /// A relationship between two copied tracks — a chapter list, a forced
    /// subtitle track — re-made in the copy, which would otherwise lose it.
    struct Association: Sendable {
        let from: CMPersistentTrackID
        let to: CMPersistentTrackID
        let type: AVAssetTrack.AssociationType
    }

    /// The associations worth keeping.
    static let associationTypes: [AVAssetTrack.AssociationType] = [
        .chapterList, .forcedSubtitlesOnly, .selectionFollower, .timecode, .audioFallback, .metadataReferent,
    ]

    // MARK: - Reading the plan

    /// What to carry from `asset`: every track, or every one but the
    /// subtitles when they are being replaced.
    static func plan(_ asset: AVAsset, droppingSubtitles: Bool) async throws
        -> (tracks: [CopiedTrack], associations: [Association]) {
        var copied: [CopiedTrack] = []
        var associations: [Association] = []
        for track in try await asset.load(.tracks) {
            if droppingSubtitles, [.subtitle, .closedCaption].contains(track.mediaType) { continue }
            let (formats, transform, language, tag, enabled) = try await track.load(
                .formatDescriptions, .preferredTransform, .languageCode, .extendedLanguageTag, .isEnabled)
            copied.append(CopiedTrack(trackID: track.trackID, mediaType: track.mediaType,
                                      format: formats.first, transform: transform,
                                      languageCode: language, extendedLanguageTag: tag, isEnabled: enabled))
            for type in associationTypes {
                for other in try await track.loadAssociatedTracks(ofType: type) {
                    associations.append(Association(from: track.trackID, to: other.trackID, type: type))
                }
            }
        }
        let kept = Set(copied.map(\.trackID))
        return (copied, associations.filter { kept.contains($0.from) && kept.contains($0.to) })
    }

    // MARK: - Writing

    /// Writes `copying` and `adding` to `url`.
    ///
    /// - Returns: The media types of source tracks the writer refused, which
    ///   are left out rather than failing the job.
    /// - Throws: ``VideoForgeError/writeFailed(_:reason:)``, or
    ///   `CancellationError` when the task is cancelled — the partial file
    ///   is removed either way.
    static func remux(_ source: URL, copying: [CopiedTrack], associations: [Association],
                      adding: [MadeTrack],
                      to url: URL, fileType: AVFileType) async throws -> [AVMediaType] {
        let (session, refused) = try await makeSession(source, copying: copying, associations: associations,
                                                       adding: adding, to: url, fileType: fileType)
        let shared = Shared(session)
        let queue = DispatchQueue(label: "video-forge.remux")

        await withTaskCancellationHandler {
            await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                shared.state.withLock { session in
                    session.finished = finished
                    guard session.start() else { return }
                    for index in session.feeds.indices {
                        session.feeds[index].input.requestMediaDataWhenReady(on: queue) {
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
        case .failed(let reason):
            shared.state.withLock { $0.abandon() }
            try? FileManager.default.removeItem(at: url)
            throw VideoForgeError.writeFailed(url, reason: reason)
        case .running, .done:
            break
        }
        await withCheckedContinuation { (written: CheckedContinuation<Void, Never>) in
            shared.state.withLock { $0.writer.finishWriting { written.resume() } }
        }
        if let reason = shared.state.withLock({ $0.writerFailure }) {
            try? FileManager.default.removeItem(at: url)
            throw VideoForgeError.writeFailed(url, reason: reason)
        }
        return refused
    }

    /// Builds the reader, the writer and their inputs. Everything in the
    /// session is made or loaded here, so it can be handed to the lock whole.
    private static func makeSession(_ source: URL, copying: [CopiedTrack], associations: [Association],
                                    adding: [MadeTrack],
                                    to url: URL, fileType: AVFileType) async throws -> sending (Session, [AVMediaType]) {
        let asset = AVURLAsset(url: source)
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw VideoForgeError.writeFailed(url, reason: error.localizedDescription)
        }
        // The movie's own metadata — creation date, location, title — which
        // a copy must not lose.
        writer.metadata = (try? await asset.load(.metadata)) ?? []

        var feeds: [Feed] = []
        var refused: [AVMediaType] = []
        var inputsByTrack: [CMPersistentTrackID: AVAssetWriterInput] = [:]
        var subtitleInputs: [(input: AVAssetWriterInput, isDefault: Bool)] = []
        var audioInputs: [(input: AVAssetWriterInput, isDefault: Bool)] = []

        for copied in copying {
            let mediaType = copied.mediaType
            guard let track = try await asset.loadTrack(withTrackID: copied.trackID) else {
                refused.append(mediaType)
                continue
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil, sourceFormatHint: copied.format)
            input.expectsMediaDataInRealTime = false
            input.transform = copied.transform
            if let language = copied.languageCode { input.languageCode = language }
            if let tag = copied.extendedLanguageTag { input.extendedLanguageTag = tag }
            input.marksOutputTrackAsEnabled = copied.isEnabled
            guard reader.canAdd(output), writer.canAdd(input) else {
                refused.append(mediaType)
                continue
            }
            reader.add(output)
            writer.add(input)
            inputsByTrack[copied.trackID] = input
            feeds.append(Feed(input: input, source: .copy(output)))
            if mediaType == .subtitle { subtitleInputs.append((input, copied.isEnabled)) }
            if mediaType == .audio { audioInputs.append((input, copied.isEnabled)) }
        }

        for made in adding {
            let input = AVAssetWriterInput(mediaType: made.mediaType, outputSettings: nil, sourceFormatHint: made.format)
            input.expectsMediaDataInRealTime = false
            input.languageCode = made.languageCode
            if let tag = made.extendedLanguageTag { input.extendedLanguageTag = tag }
            guard writer.canAdd(input) else {
                throw VideoForgeError.writeFailed(url, reason: "the writer refused a \(made.mediaType.rawValue) track")
            }
            writer.add(input)
            feeds.append(Feed(input: input, source: .made(made.format, made.samples)))
            subtitleInputs.append((input, made.isDefault))
        }

        for association in associations {
            guard let from = inputsByTrack[association.from], let to = inputsByTrack[association.to],
                  from.canAddTrackAssociation(withTrackOf: to, type: association.type.rawValue) else { continue }
            from.addTrackAssociation(withTrackOf: to, type: association.type.rawValue)
        }

        // Alternates go in a group, or players will not offer them. A made
        // default wins over one the source had.
        if !subtitleInputs.isEmpty {
            let preferred = adding.contains(where: \.isDefault)
                ? subtitleInputs.last(where: \.isDefault)?.input
                : subtitleInputs.first(where: \.isDefault)?.input
            let group = AVAssetWriterInputGroup(inputs: subtitleInputs.map(\.input), defaultInput: preferred)
            if writer.canAdd(group) { writer.add(group) }
        }
        if audioInputs.count > 1 {
            let group = AVAssetWriterInputGroup(inputs: audioInputs.map(\.input),
                                                defaultInput: audioInputs.first(where: \.isDefault)?.input ?? audioInputs[0].input)
            if writer.canAdd(group) { writer.add(group) }
        }
        return (Session(reader: reader, writer: writer, feeds: feeds), refused)
    }

    // MARK: - The session

    /// Owns the session's lock, so the writer's callbacks can share it.
    private final class Shared: Sendable {
        let state: Mutex<Session>
        init(_ session: sending Session) { state = Mutex(session) }
    }

    /// Where a running session stands.
    enum Outcome: Sendable, Equatable {
        case running, done, cancelled
        case failed(String)
    }

    /// Where one input's samples come from.
    enum Source {
        case copy(AVAssetReaderTrackOutput)
        case made(CMFormatDescription, [Sample])
    }

    /// One writer input and what feeds it.
    struct Feed {
        let input: AVAssetWriterInput
        let source: Source
        var next = 0
        var isFinished = false
    }

    /// Everything the callbacks touch. Only ever used under the lock.
    struct Session {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        var feeds: [Feed]
        var finished: CheckedContinuation<Void, Never>?
        var outcome = Outcome.running

        init(reader: AVAssetReader, writer: AVAssetWriter, feeds: [Feed]) {
            self.reader = reader
            self.writer = writer
            self.feeds = feeds
        }

        /// Starts reading and writing; false when either refuses, or the
        /// task was cancelled first.
        mutating func start() -> Bool {
            guard outcome == .running else { return stop(outcome) }
            guard reader.startReading() else {
                return stop(.failed(reader.error?.localizedDescription ?? "the source could not be read"))
            }
            guard writer.startWriting() else {
                return stop(.failed(writer.error?.localizedDescription ?? "the writer would not start"))
            }
            writer.startSession(atSourceTime: .zero)
            if feeds.isEmpty { return stop(.done) }
            return true
        }

        /// Feeds one input until the writer wants no more for now.
        mutating func pump(_ index: Int) {
            guard outcome == .running, !feeds[index].isFinished else { return }
            let input = feeds[index].input
            while input.isReadyForMoreMediaData {
                guard let sample = nextSample(index) else {
                    guard outcome == .running else { return }
                    if reader.status == .failed {
                        _ = stop(.failed(reader.error?.localizedDescription ?? "reading the source failed"))
                        return
                    }
                    feeds[index].isFinished = true
                    input.markAsFinished()
                    if feeds.allSatisfy(\.isFinished) { _ = stop(.done) }
                    return
                }
                guard input.append(sample) else {
                    _ = stop(.failed(writer.error?.localizedDescription ?? "the writer refused a sample"))
                    return
                }
            }
        }

        /// The next sample for an input, or nil at its end.
        mutating func nextSample(_ index: Int) -> CMSampleBuffer? {
            switch feeds[index].source {
            case .copy(let output):
                return output.copyNextSampleBuffer()
            case .made(let format, let samples):
                guard feeds[index].next < samples.count else { return nil }
                defer { feeds[index].next += 1 }
                guard let buffer = Remuxer.sampleBuffer(samples[feeds[index].next], format: format) else {
                    _ = stop(.failed("a subtitle sample could not be made"))
                    return nil
                }
                return buffer
            }
        }

        /// Stops reading and writing after a cancel.
        mutating func cancel() {
            guard outcome == .running else { return }
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
            _ = stop(.cancelled)
        }

        /// Cleans up after a failure.
        func abandon() {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }

        /// Why the finished file is no good, if it is not.
        var writerFailure: String? {
            writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "the writer did not finish")
        }

        /// Records how it ended — the first ending wins — and wakes the
        /// waiting task, once. Returns false so `start` can end with it.
        mutating func stop(_ result: Outcome) -> Bool {
            if outcome == .running { outcome = result }
            finished?.resume()
            finished = nil
            return false
        }
    }

    /// One made sample as a buffer the writer takes.
    static func sampleBuffer(_ sample: Sample, format: CMFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: sample.data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: sample.data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = sample.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: sample.data.count)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: sample.range.duration,
                                        presentationTimeStamp: sample.range.start, decodeTimeStamp: .invalid)
        var size = sample.data.count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }
}
