//
//  VideoCodec.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Which encoder writes the pictures. The rule that matters is that a
//  10-bit source must not be written by an 8-bit encoder: H.264's hardware
//  paths are 8-bit, so writing 10-bit footage as H.264 truncates the depth
//  the camera bothered to record. HEVC with alpha is 8-bit too — measured:
//  it writes HEVC Main, not Main 10.
//

import AVFoundation
import Foundation

/// The video codec to write.
public enum VideoCodec: String, CaseIterable, Sendable, Codable, Hashable {
    /// Whatever the source used. The default, and the only one that cannot
    /// make things worse.
    case source
    /// H.264. Universally playable, 8-bit only.
    case h264
    /// HEVC. Smaller at the same quality; Main 10 from a 10-bit source.
    case hevc
    /// HEVC with an alpha channel, for footage that has one. 8-bit.
    case hevcAlpha
    /// Apple ProRes 422 (10-bit 4:2:2), for an editing round trip rather
    /// than delivery. QuickTime only.
    case proRes422
    /// Apple ProRes 4444 (12-bit, with alpha). QuickTime only.
    case proRes4444

    /// The AVFoundation codec this names, or nil for ``source``.
    public var codecType: AVVideoCodecType? {
        switch self {
        case .source: return nil
        case .h264: return .h264
        case .hevc: return .hevc
        case .hevcAlpha: return .hevcWithAlpha
        case .proRes422: return .proRes422
        case .proRes4444: return .proRes4444
        }
    }

    /// Whether this codec can carry more than 8 bits per component.
    ///
    /// MEASURED, not assumed: HEVC with alpha writes HEVC Main — 8-bit — so
    /// a 10-bit ramp came back with 64 levels where HEVC kept all 256.
    public var isDeep: Bool {
        switch self {
        case .hevc, .proRes422, .proRes4444: return true
        case .h264, .hevcAlpha, .source: return false
        }
    }

    /// Whether this codec can only be written to QuickTime (`.mov`). The
    /// ProRes export presets list `.mov` as their one file type.
    public var needsQuickTime: Bool { self == .proRes422 || self == .proRes4444 }

    /// The codec a name means: its raw value, or the same with any case,
    /// dashes or underscores — `hevc`, `hevc-alpha`, `pro-res422`,
    /// `ProRes4444`.
    ///
    /// - Parameter text: The name as typed.
    /// - Returns: The codec, or nil for a name that is none of them.
    public static func named(_ text: String) -> VideoCodec? {
        let squeezed = { (name: String) in
            name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        }
        let wanted = squeezed(text.trimmingCharacters(in: .whitespaces))
        return allCases.first { squeezed($0.rawValue) == wanted }
    }

    /// Whether an alpha channel survives.
    public var keepsAlpha: Bool { self == .hevcAlpha || self == .proRes4444 }

    /// Whether this codec compresses so lightly that a bitrate is not worth
    /// asking for — ProRes decides its own.
    public var isIntraFrame: Bool { self == .proRes422 || self == .proRes4444 }
}
