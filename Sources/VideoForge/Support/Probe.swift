//
//  Probe.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Reading what a movie is without decoding a frame of it. Everything here
//  comes from the container's own tables, so describing a two-hour 4K
//  recording costs the same as describing a three-second clip.
//

import AVFoundation
import CoreGraphics
import Foundation

/// Reads a movie's shape.
public enum Probe {

    /// What a movie file contains.
    ///
    /// - Parameter url: The file to describe.
    /// - Returns: Its duration, frame size, rate and every track.
    /// - Throws: ``VideoForgeError/fileNotFound(_:)`` or
    ///   ``VideoForgeError/unreadable(_:reason:)``.
    public static func describe(_ url: URL) async throws -> VideoInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VideoForgeError.fileNotFound(url)
        }
        let asset = AVURLAsset(url: url)
        return try await describe(asset, url: url)
    }

    /// The shared body, so a composition can be described too.
    ///
    /// - Parameters:
    ///   - asset: The asset to describe.
    ///   - url: The file it came from, for the byte count and the container.
    /// - Returns: Its shape.
    /// - Throws: ``VideoForgeError/unreadable(_:reason:)``.
    public static func describe(_ asset: AVAsset, url: URL) async throws -> VideoInfo {
        let duration: CMTime
        let assetTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            assetTracks = try await asset.load(.tracks)
        } catch {
            throw VideoForgeError.unreadable(url, reason: error.localizedDescription)
        }

        var tracks: [TrackInfo] = []
        var displayed = CGSize.zero
        var frameRate = 0.0
        var rotated = false

        for track in assetTracks {
            guard let kind = TrackKind.of(track.mediaType) else { continue }
            let info = try await describe(track: track, kind: kind)
            tracks.append(info)

            guard kind == .video else { continue }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            // A phone held upright records sideways and leaves a transform
            // saying so; the size a viewer sees is the transformed one.
            let shown = natural.applying(transform)
            displayed = CGSize(width: abs(shown.width), height: abs(shown.height))
            frameRate = Double(info.frameRate ?? 0)
            rotated = abs(transform.b) == 1 && abs(transform.c) == 1
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return VideoInfo(duration: duration.seconds.isFinite ? duration.seconds : 0,
                         width: Int(displayed.width), height: Int(displayed.height),
                         frameRate: frameRate,
                         container: VideoContainer.named(fileExtension: url.pathExtension),
                         byteCount: bytes ?? 0, tracks: tracks, isRotated: rotated)
    }

    /// One track's shape.
    ///
    /// - Parameters:
    ///   - track: The track to describe.
    ///   - kind: What kind it is.
    /// - Returns: Its codec, rate and dimensions.
    static func describe(track: AVAssetTrack, kind: TrackKind) async throws -> TrackInfo {
        let duration = try await track.load(.timeRange).duration.seconds
        let bitRate = Double(try await track.load(.estimatedDataRate))
        let formats = try await track.load(.formatDescriptions)
        let description = formats.first

        var codec = "----"
        var depth: Int?
        var channels: Int?
        var sampleRate: Double?

        if let description {
            codec = fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
            if kind == .video {
                let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
                // MEASURED, and not what it looks like. `Depth` is
                // QuickTime's PIXEL depth and reads 24 for 8-bit H.264 *and*
                // for 10-bit HEVC Main10 alike, so keying off it marks every
                // ordinary clip as deep. `BitsPerComponent` is the real
                // answer: present and equal to 10 on 10-bit footage, and
                // absent altogether on 8-bit, which is why the default lives
                // here rather than in a fallback.
                depth = extensions?["BitsPerComponent"] as? Int ?? 8
            }
            if kind == .audio, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                channels = Int(basic.pointee.mChannelsPerFrame)
                sampleRate = basic.pointee.mSampleRate
            }
        }

        let size = kind == .video ? try await track.load(.naturalSize) : nil
        let rate = kind == .video ? Double(try await track.load(.nominalFrameRate)) : nil
        let languages = try await track.load(.languageCode)

        return TrackInfo(kind: kind, codec: codec,
                         duration: duration.isFinite ? duration : 0,
                         bitRate: bitRate,
                         width: size.map { Int($0.width) }, height: size.map { Int($0.height) },
                         frameRate: rate, bitDepth: depth,
                         channels: channels, sampleRate: sampleRate,
                         language: languages == "und" ? nil : languages)
    }

    /// A `FourCharCode` as the four letters people write it as — `avc1`,
    /// `hvc1`, `aac `.
    static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [UInt8(truncatingIfNeeded: code >> 24), UInt8(truncatingIfNeeded: code >> 16),
                     UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "----"
    }
}
