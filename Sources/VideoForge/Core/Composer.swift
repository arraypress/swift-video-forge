//
//  Composer.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The road that never decodes a frame. Trimming, joining, changing speed
//  and dropping a track are all rearrangements of TIME, and an
//  `AVMutableComposition` does them by pointing at the source's samples
//  rather than reading them. On a two-hour recording that is the difference
//  between a second and twenty minutes — and it is also the only version
//  that does not re-encode, so it is the only one that cannot lose quality.
//
//  MEASURED: an export of a scaled composition does NOT come out at the
//  composition's duration once there is an audio track in it. Asking for
//  2× on a 3.00s clip gave 1.61s where the composition said 1.50s, and
//  0.5× gave 6.09s against 6.00s — the audio time-pitch pass pads the end.
//  The composition is always right, so the export is clamped to it. Video
//  alone was exact either way, which is how the audio track was identified
//  as the culprit.
//

import AVFoundation
import Foundation

/// Builds and exports compositions — the road that leaves frames alone.
public enum Composer {

    /// Builds a composition for the time-only operations in a job.
    ///
    /// - Parameters:
    ///   - asset: The source.
    ///   - operations: The steps. Anything that is not time-only is ignored
    ///     here; the caller has already decided this road can be taken.
    ///   - keepsAudio: Whether to carry the sound across.
    ///   - keepsSidecarTracks: Whether to carry subtitles and metadata.
    /// - Returns: The composition, and the time range worth exporting.
    /// - Throws: ``VideoForgeError`` when the source has nothing usable.
    public static func build(from asset: AVAsset,
                             operations: [VideoOperation],
                             keepsAudio: Bool,
                             keepsSidecarTracks: Bool) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)

        // Which tracks survive: the caller's choice, then the operations'.
        var wanted: Set<TrackKind> = [.video]
        if keepsAudio { wanted.insert(.audio) }
        if keepsSidecarTracks { wanted.formUnion([.subtitle, .metadata]) }
        for case .remove(let kind) in operations { wanted.remove(kind) }

        // The trim is applied as the range copied out of the source, so the
        // frames outside it are never touched at all.
        var range = CMTimeRange(start: .zero, duration: duration)
        for case .trim(let spec) in operations { range = spec.range(in: duration) }
        guard range.duration.seconds > 0 else {
            throw VideoForgeError.emptyRange("the trim")
        }

        for kind in TrackKind.allCases where wanted.contains(kind) {
            let sources = try await asset.loadTracks(withMediaType: kind.mediaType)
            for source in sources {
                guard let track = composition.addMutableTrack(
                    withMediaType: kind.mediaType,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                do {
                    try track.insertTimeRange(range, of: source, at: .zero)
                    // A phone clip is stored sideways with a transform
                    // saying so; dropping it lays the video on its side.
                    if kind == .video {
                        track.preferredTransform = try await source.load(.preferredTransform)
                    }
                } catch {
                    // A track that will not copy — a codec the composition
                    // cannot reference — is dropped rather than failing the
                    // whole job, and shows up in `lostTracks`.
                    composition.removeTrack(track)
                }
            }
        }

        guard composition.tracks.isEmpty == false else {
            throw VideoForgeError.exportFailed(reason: "no track could be copied")
        }

        for case .speed(let rate) in operations {
            try scale(composition, by: rate)
        }
        return composition
    }

    /// Changes a composition's speed in place.
    ///
    /// - Parameters:
    ///   - composition: The composition to scale.
    ///   - rate: 2 plays twice as fast, 0.5 half.
    /// - Throws: ``VideoForgeError/emptyRange(_:)`` for a rate that leaves
    ///   nothing.
    public static func scale(_ composition: AVMutableComposition, by rate: Double) throws {
        guard rate > 0 else { throw VideoForgeError.emptyRange("a speed of \(rate)") }
        let whole = CMTimeRange(start: .zero, duration: composition.duration)
        let target = CMTime(seconds: composition.duration.seconds / rate, preferredTimescale: 600)
        guard target.seconds > 0 else { throw VideoForgeError.emptyRange("a speed of \(rate)") }
        composition.scaleTimeRange(whole, toDuration: target)
    }

    /// Joins several movies end to end.
    ///
    /// Clips need not agree on size or codec — each is copied into the same
    /// composition and the export re-encodes if it must. They do have to
    /// have something to copy.
    ///
    /// - Parameters:
    ///   - assets: The clips, in order.
    ///   - keepsAudio: Whether to carry sound across.
    /// - Returns: The joined composition.
    /// - Throws: ``VideoForgeError/incompatibleClips(reason:)``.
    public static func concatenate(_ assets: [AVAsset], keepsAudio: Bool = true) async throws -> AVMutableComposition {
        guard !assets.isEmpty else {
            throw VideoForgeError.incompatibleClips(reason: "no clips were given")
        }
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid)
        let audio = keepsAudio ? composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var cursor = CMTime.zero
        var transformSet = false

        for asset in assets {
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoForgeError.incompatibleClips(reason: "one clip has no video track")
            }
            try video?.insertTimeRange(range, of: sourceVideo, at: cursor)
            if !transformSet {
                video?.preferredTransform = try await sourceVideo.load(.preferredTransform)
                transformSet = true
            }
            if let audio, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audio.insertTimeRange(range, of: sourceAudio, at: cursor)
            } else if let audio {
                // A silent clip in the middle must still take up its time,
                // or everything after it slides forward against the picture.
                audio.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        return composition
    }

    /// Exports a composition to a file.
    ///
    /// - Parameters:
    ///   - composition: What to write.
    ///   - url: Where to write it.
    ///   - container: The file type.
    ///   - preset: The export preset. Passthrough where the caller allows it.
    ///   - videoComposition: The per-frame work, when there is any.
    /// - Throws: ``VideoForgeError/exportFailed(reason:)``.
    public static func export(_ composition: AVComposition, to url: URL,
                              container: VideoContainer, preset: String,
                              videoComposition: AVVideoComposition? = nil) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw VideoForgeError.exportFailed(reason: "no exporter for preset \(preset)")
        }
        session.audioTimePitchAlgorithm = .spectral
        session.videoComposition = videoComposition
        // The composition knows the intended duration exactly; the export
        // does not, once audio time-pitch is involved. See the note at the
        // top of this file — this one line is the difference between 1.50s
        // and 1.61s.
        session.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        do {
            try await session.export(to: url, as: container.fileType)
        } catch {
            throw VideoForgeError.exportFailed(reason: error.localizedDescription)
        }
    }

    /// The preset to ask for.
    ///
    /// Passthrough copies samples verbatim, which is instant and lossless —
    /// but it cannot change the frame, so it is only offered when the job
    /// is genuinely a rearrangement of time.
    ///
    /// - Parameters:
    ///   - spec: The export settings.
    ///   - timeOnly: Whether every operation was time-only.
    /// - Returns: The preset name.
    public static func preset(for spec: ExportSpec, timeOnly: Bool) -> String {
        guard timeOnly, spec.prefersPassthrough, spec.codec == .source,
              spec.bitRate == nil, spec.frameRate == nil else {
            return AVAssetExportPresetHighestQuality
        }
        return AVAssetExportPresetPassthrough
    }
}
