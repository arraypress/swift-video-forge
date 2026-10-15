//
//  FormatDescriptions.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Reading a video track's format description: the one place that knows
//  which extension keys mean what, so the prober, the writer road and the
//  reverser read the same facts the same way.
//

import CoreMedia
import Foundation

/// Facts read off a `CMFormatDescription`.
enum FormatDescriptions {

    /// The four-character code, as people write it: `avc1`, `hvc1`, `aac`.
    static func codec(of description: CMFormatDescription) -> String {
        Probe.fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
    }

    /// Bits per component, when declared.
    ///
    /// MEASURED, and not what it looks like: `Depth` is QuickTime's PIXEL
    /// depth and reads 24 for 8-bit H.264 and 10-bit HEVC Main 10 alike.
    /// `BitsPerComponent` is the real answer — present (10) on 10-bit
    /// footage, absent on 8-bit. ProRes always declares 12 (16 with alpha),
    /// whatever the footage was before it became ProRes.
    static func bitsPerComponent(of description: CMFormatDescription) -> Int? {
        CMFormatDescriptionGetExtension(description, extensionKey: "BitsPerComponent" as CFString) as? Int
    }

    /// Whether the track carries alpha.
    ///
    /// MEASURED: `ContainsAlphaChannel` is 1 on HEVC with alpha (written by
    /// AVFoundation or by ffmpeg's VideoToolbox encoder) and on ProRes 4444
    /// with alpha, and absent otherwise. The codec type alone cannot say:
    /// HEVC with alpha is `hvc1`, like any HEVC.
    static func hasAlpha(_ description: CMFormatDescription) -> Bool {
        let value = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel)
        return (value as? Bool) ?? ((value as? Int).map { $0 != 0 } ?? false)
    }

    /// The colour tags, as a complete set or not at all — the writer
    /// rejects a partial colour-properties dictionary, and guessing the
    /// missing member invents colour.
    static func colour(of description: CMFormatDescription)
        -> (primaries: String, transfer: String, matrix: String)? {
        let tag = { (key: CFString) in
            CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
        }
        guard let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = tag(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = tag(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return (primaries, transfer, matrix)
    }
}
