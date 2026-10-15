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
//  The feeding is ``WriterPump``'s: callbacks on one serial queue, because
//  macOS 26's async receivers deadlocked on a plain H.264/AAC copy.
//

import AVFoundation
import Foundation

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
        let languageCode: String?
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
        let (job, refused) = try await makeJob(source, copying: copying, associations: associations,
                                               adding: adding, to: url, fileType: fileType)
        try await WriterPump.run(job)
        return refused
    }

    /// Builds the reader, the writer, their inputs and the feeds. Everything
    /// is made or loaded here, so it can be handed to the pump whole.
    private static func makeJob(_ source: URL, copying: [CopiedTrack], associations: [Association],
                                    adding: [MadeTrack],
                                    to url: URL, fileType: AVFileType) async throws -> sending (WriterJob, [AVMediaType]) {
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

        var feeds: [WriterFeed] = []
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
            feeds.append(.copying(from: output, to: input))
            if mediaType == .subtitle { subtitleInputs.append((input, copied.isEnabled)) }
            if mediaType == .audio { audioInputs.append((input, copied.isEnabled)) }
        }

        subtitleInputs += try add(adding, to: writer, feeds: &feeds, url: url)

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
            writer.addAlternateGroup(subtitleInputs.map(\.input), defaultInput: preferred)
        }
        if audioInputs.count > 1 {
            writer.addAlternateGroup(audioInputs.map(\.input),
                                     defaultInput: audioInputs.first(where: \.isDefault)?.input ?? audioInputs[0].input)
        }
        return (WriterJob(reader: reader, writer: writer, feeds: feeds), refused)
    }

    /// Adds an input for each made track, and a feed that writes it.
    ///
    /// - Returns: The inputs, each with whether it is the default — for the
    ///   caller to put in an alternate group.
    /// - Throws: ``VideoForgeError/writeFailed(_:reason:)`` when the writer
    ///   refuses a track.
    static func add(_ made: [MadeTrack], to writer: AVAssetWriter, feeds: inout [WriterFeed],
                    url: URL) throws -> [(input: AVAssetWriterInput, isDefault: Bool)] {
        try made.map { track in
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil,
                                           sourceFormatHint: track.format)
            input.expectsMediaDataInRealTime = false
            if let language = track.languageCode { input.languageCode = language }
            if let tag = track.extendedLanguageTag { input.extendedLanguageTag = tag }
            guard writer.canAdd(input) else {
                throw VideoForgeError.writeFailed(url, reason: "the writer refused a \(TrackKind.describing(track.mediaType)) track")
            }
            writer.add(input)
            feeds.append(madeFeed(track, into: input, url: url))
            return (input, track.isDefault)
        }
    }

    /// A feed that writes made samples, in order.
    private static func madeFeed(_ made: MadeTrack, into input: AVAssetWriterInput, url: URL) -> WriterFeed {
        var next = 0
        return WriterFeed(input: input) {
            guard next < made.samples.count else { return false }
            defer { next += 1 }
            guard let buffer = sampleBuffer(made.samples[next], format: made.format) else {
                throw VideoForgeError.writeFailed(url, reason: "a subtitle sample could not be made")
            }
            input.append(buffer)
            return true
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
