//
//  VideoSourceFormat+Track.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Reading a source format off a track or a format description.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

public extension VideoSourceFormat {

    /// The format a description and the track's own numbers describe.
    ///
    /// - Parameters:
    ///   - description: The track's first format description; nil reads as
    ///     8-bit H.264 with no tags.
    ///   - size: The stored frame size.
    ///   - frameRate: The nominal frame rate.
    ///   - dataRate: The estimated bitrate.
    init(description: CMFormatDescription?, size: CGSize, frameRate: Double, dataRate: Double) {
        let colour = description.flatMap(FormatDescriptions.colour(of:))
        self.init(codec: description.map(FormatDescriptions.codec(of:)) ?? "avc1",
                  width: Int(size.width), height: Int(size.height),
                  dataRate: dataRate, frameRate: frameRate,
                  bitsPerComponent: description.flatMap(FormatDescriptions.bitsPerComponent(of:)),
                  colorPrimaries: colour?.primaries, transferFunction: colour?.transfer,
                  yCbCrMatrix: colour?.matrix,
                  hasAlpha: description.map(FormatDescriptions.hasAlpha) ?? false)
    }

    /// The format of a video track.
    ///
    /// - Parameter track: A video track.
    /// - Returns: Its format.
    /// - Throws: Whatever loading the track's properties throws.
    static func load(from track: AVAssetTrack) async throws -> VideoSourceFormat {
        let (descriptions, size, fps, rate) = try await track.load(
            .formatDescriptions, .naturalSize, .nominalFrameRate, .estimatedDataRate)
        return VideoSourceFormat(description: descriptions.first, size: size,
                                 frameRate: Double(fps), dataRate: Double(rate))
    }
}
