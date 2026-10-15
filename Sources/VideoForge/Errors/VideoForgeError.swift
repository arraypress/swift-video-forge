//
//  VideoForgeError.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Failures a caller can act on. Two of these exist because of things that
//  were measured rather than expected: a reverse of a long clip needs more
//  memory than a machine has, and a 10-bit source must not be written by an
//  8-bit codec.
//

import Foundation

/// Why a video operation could not be completed.
public enum VideoForgeError: Error, LocalizedError, Sendable, Equatable {
    /// The file is not there.
    case fileNotFound(URL)
    /// AVFoundation could not open it.
    case unreadable(URL, reason: String)
    /// The file opened but holds no video track.
    case noVideoTrack(URL)
    /// The file holds no audio to extract.
    case noAudioTrack(URL)
    /// A destination file already exists and overwriting was not allowed.
    case destinationExists(URL)
    /// The export failed.
    case exportFailed(reason: String)
    /// The writer refused the settings.
    case writeFailed(URL, reason: String)
    /// A trim keeps nothing.
    case emptyRange(String)
    /// A crop falls outside the frame.
    case cropOutOfBounds(requested: String, frame: String)
    /// Reversing this clip would need more memory than the budget allows.
    /// Carries what it would take and what was allowed, both in bytes.
    case reverseTooLarge(needs: Int, budget: Int)
    /// A 10-bit source was asked to be written by an 8-bit codec, which
    /// would throw away the depth the camera recorded.
    case wouldTruncateDepth(codec: VideoCodec)
    /// The codec can only be written to another container — ProRes is
    /// QuickTime only.
    case codecNeedsContainer(codec: VideoCodec, container: VideoContainer)
    /// A bitrate or a quality was asked of a codec that sets its own —
    /// ProRes.
    case codecTakesNoRate(codec: VideoCodec)
    /// The container cannot hold what it was asked to hold.
    case containerCannotHold(VideoContainer, TrackKind)
    /// Joining clips that do not agree on something that matters.
    case incompatibleClips(reason: String)
    /// Subtitles that cannot be written as asked — no cue inside the video,
    /// an unknown language, two default tracks.
    case invalidSubtitles(String)
    /// The movie holds no subtitle or caption track.
    case noSubtitleTrack(URL)

    /// A lowercase phrase that reads inside a sentence, for a CLI or a log.
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "no file at \(url.path)"
        case .unreadable(let url, let reason):
            return "\(url.lastPathComponent) could not be opened: \(reason)"
        case .noVideoTrack(let url):
            return "\(url.lastPathComponent) has no video track"
        case .noAudioTrack(let url):
            return "\(url.lastPathComponent) has no audio to extract"
        case .destinationExists(let url):
            return "\(url.lastPathComponent) already exists"
        case .exportFailed(let reason):
            return "the export failed: \(reason)"
        case .writeFailed(let url, let reason):
            return "could not write \(url.lastPathComponent): \(reason)"
        case .emptyRange(let what):
            return "\(what) keeps nothing"
        case .cropOutOfBounds(let requested, let frame):
            return "crop \(requested) falls outside a \(frame) frame"
        case .reverseTooLarge(let needs, let budget):
            let gb = { (n: Int) in String(format: "%.1f GB", Double(n) / 1_073_741_824) }
            return "reversing this would hold \(gb(needs)) of frames at once, over the \(gb(budget)) budget — trim it first, or scale it down"
        case .wouldTruncateDepth(let codec):
            return "this is 10-bit footage and \(codec.rawValue) is 8-bit — write hevc, pro-res422 or pro-res4444, or leave the codec as the source's"
        case .codecNeedsContainer(let codec, let container):
            return "\(codec.rawValue) is written only to mov, not \(container.rawValue)"
        case .codecTakesNoRate(let codec):
            return "\(codec.rawValue) sets its own bitrate and takes no quality — drop the bitrate and quality, or write hevc or h264"
        case .containerCannotHold(let container, let kind):
            return "\(container.rawValue) cannot hold a \(kind.rawValue) track"
        case .incompatibleClips(let reason):
            return "these clips cannot be joined: \(reason)"
        case .invalidSubtitles(let reason):
            return reason
        case .noSubtitleTrack(let url):
            return "\(url.lastPathComponent) has no subtitle or caption track"
        }
    }
}
