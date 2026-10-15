//
//  CodecPlan.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Which encoder a job writes with, and what that rules out. Pure
//  functions, so every road — the export session, the reverse writer, a
//  join, a soundtrack — decides the same way, and a test can check the
//  decision without writing a file.
//
//  Before 0.4.0 none of this existed: `ExportSpec.codec` was read by
//  nobody, every re-encode went through `AVAssetExportPresetHighestQuality`,
//  and that preset writes H.264 — so `--codec hevc` wrote H.264, and a
//  10-bit HEVC clip came out of a plain resize as 8-bit H.264.
//
//  MEASURED on macOS 27 (a 10-bit HEVC ramp with 256 distinct luma levels
//  on one row, and an 8-bit H.264 test pattern):
//
//  · `HighestQuality` writes H.264 High, 8-bit, whatever went in.
//  · `HEVCHighestQuality` writes HEVC Main 10 from a 10-bit source — all
//    256 levels survive, copied or redrawn — and HEVC Main from an 8-bit one.
//  · `HEVCHighestQualityWithAlpha` writes HEVC **Main, 8-bit** (64 levels
//    from the 10-bit ramp), and refuses to copy a source that has no alpha
//    (-11838 / -16976) though it redraws one happily.
//  · The ProRes presets write `apcn` 4:2:2 10-bit and `ap4h` 4:4:4:4
//    12-bit, and only to QuickTime: `.mov` is their one file type.
//

import AVFoundation
import Foundation

/// Decides the codec, preset and container a job writes.
enum CodecPlan {

    /// The codec a track's four-character code names, when it is one this
    /// library can write.
    ///
    /// - Parameter fourCharacterCode: The track's format, as ``TrackInfo/codec`` reports it.
    /// - Returns: The codec, or nil for one this library does not write.
    static func codec(named fourCharacterCode: String) -> VideoCodec? {
        switch fourCharacterCode.trimmingCharacters(in: .whitespaces) {
        case "avc1", "avc3": return .h264
        case "hvc1", "hev1": return .hevc
        case "apcn", "apch", "apcs", "apco": return .proRes422
        case "ap4h", "ap4x": return .proRes4444
        default: return nil
        }
    }

    /// What ``VideoCodec/source`` comes to for a given source.
    ///
    /// The source's own codec when this library can write it and it holds
    /// the source's depth; otherwise HEVC for deep footage and H.264 for the
    /// rest. "Source" is promised never to lose depth, so a 10-bit clip in a
    /// codec that cannot be written comes out as HEVC Main 10, not H.264.
    ///
    /// - Parameters:
    ///   - wanted: The codec asked for.
    ///   - sourceCodec: The source's four-character code, if known.
    ///   - deep: Whether the source carries more than 8 bits.
    /// - Returns: A concrete codec — never ``VideoCodec/source``.
    static func resolve(_ wanted: VideoCodec, sourceCodec: String?, deep: Bool) -> VideoCodec {
        guard wanted == .source else { return wanted }
        if let own = sourceCodec.flatMap(codec(named:)), !deep || own.isDeep { return own }
        return deep ? .hevc : .h264
    }

    /// Refuses to write deep footage with an 8-bit encoder.
    ///
    /// - Parameters:
    ///   - codec: The concrete codec to write.
    ///   - deep: Whether the source carries more than 8 bits.
    /// - Throws: ``VideoForgeError/wouldTruncateDepth(codec:)``.
    static func checkDepth(_ codec: VideoCodec, deep: Bool) throws {
        if deep, !codec.isDeep, codec != .source {
            throw VideoForgeError.wouldTruncateDepth(codec: codec)
        }
    }

    /// The export preset that writes a codec.
    ///
    /// - Parameter codec: A concrete codec.
    /// - Returns: The `AVAssetExportSession` preset name.
    static func preset(for codec: VideoCodec) -> String {
        switch codec {
        case .h264, .source: return AVAssetExportPresetHighestQuality
        case .hevc: return AVAssetExportPresetHEVCHighestQuality
        case .hevcAlpha: return AVAssetExportPresetHEVCHighestQualityWithAlpha
        case .proRes422: return AVAssetExportPresetAppleProRes422LPCM
        case .proRes4444: return AVAssetExportPresetAppleProRes4444LPCM
        }
    }

    /// Whether a time-only job may copy samples rather than re-encode.
    ///
    /// Only when nothing asks for a change: the codec is the source's own
    /// (asked for by name or as ``VideoCodec/source``), and neither a bit
    /// rate nor a frame rate was given.
    ///
    /// - Parameters:
    ///   - spec: The export settings.
    ///   - codec: The concrete codec the job writes.
    ///   - sourceCodec: The source's four-character code, if known.
    ///   - timeOnly: Whether every operation was time-only.
    /// - Returns: Whether the passthrough preset can be used.
    static func passesThrough(_ spec: ExportSpec, codec: VideoCodec,
                              sourceCodec: String?, timeOnly: Bool) -> Bool {
        guard timeOnly, spec.prefersPassthrough,
              spec.bitRate == nil, spec.frameRate == nil else { return false }
        return spec.codec == .source || sourceCodec.flatMap(self.codec(named:)) == codec
    }

    /// The container a job writes.
    ///
    /// Asked for by name first, then named by the destination's extension,
    /// then the source's. ProRes is written only to QuickTime: when the
    /// container was merely inherited from an `.mp4` source it becomes
    /// `.mov`; when it was asked for, or named by the destination, it is
    /// refused rather than quietly overruled.
    ///
    /// - Parameters:
    ///   - explicit: The container asked for, if any.
    ///   - destination: Where the file goes, if known.
    ///   - inherited: The source's container, if known.
    ///   - codec: The concrete codec the job writes.
    /// - Returns: The container.
    /// - Throws: ``VideoForgeError/codecNeedsContainer(codec:container:)``.
    static func container(explicit: VideoContainer?, destination: URL?,
                          inherited: VideoContainer?, codec: VideoCodec) throws -> VideoContainer {
        let named = destination.flatMap { VideoContainer.named(fileExtension: $0.pathExtension) }
            .flatMap { $0.holdsVideo ? $0 : nil }
        if let chosen = explicit ?? named {
            if codec.needsQuickTime, chosen != .mov {
                throw VideoForgeError.codecNeedsContainer(codec: codec, container: chosen)
            }
            return chosen
        }
        if codec.needsQuickTime { return .mov }
        return inherited ?? .mov
    }
}
