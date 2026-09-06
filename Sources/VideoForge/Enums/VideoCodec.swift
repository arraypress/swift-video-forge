//
//  VideoCodec.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Which encoder writes the pictures. The rule that matters is that a
//  10-bit source must not be written by an 8-bit encoder: H.264's hardware
//  paths are 8-bit, so writing 10-bit footage as H.264 truncates the depth
//  the camera bothered to record.
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
    /// HEVC. Smaller at the same quality, and the only one of these that
    /// carries 10 bits.
    case hevc
    /// HEVC with an alpha channel, for footage that has one.
    case hevcAlpha
    /// Apple ProRes 422, for an editing round trip rather than delivery.
    case proRes422
    /// Apple ProRes 4444, which keeps alpha.
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
    public var isDeep: Bool {
        switch self {
        case .hevc, .hevcAlpha, .proRes422, .proRes4444: return true
        case .h264, .source: return false
        }
    }

    /// Whether an alpha channel survives.
    public var keepsAlpha: Bool { self == .hevcAlpha || self == .proRes4444 }

    /// Whether this codec compresses so lightly that a bitrate is not worth
    /// asking for — ProRes decides its own.
    public var isIntraFrame: Bool { self == .proRes422 || self == .proRes4444 }
}
