//
//  TX3G.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The 3GPP timed-text format (`tx3g`, ffmpeg's `mov_text`): the subtitle
//  track that AVFoundation, ffmpeg and most players all read in both MP4 and
//  QuickTime files. Measured on 2026-10-11 before choosing it:
//
//  - Two earlier attempts hand-built the sample entry from the spec and got
//    files AVFoundation refused to reopen (-12848). This builds the format
//    description from the same keys AVFoundation itself reports for an
//    ffmpeg-written track, and the result reopens, lists in the legible
//    media-selection group, and decodes in ffmpeg byte for byte.
//  - WebVTT (`wvtt`) writes and reads back, but loading the legible group
//    fails (-12718), so no player would offer it; ffmpeg 9 cannot read it in
//    MP4 either. CEA-608 closed captions (the AVCaption writer) cannot carry
//    CJK, Arabic or emoji — they come back as blocks — and the writer
//    rejects every text-track route (-12780).
//
//  A sample is a 16-bit big-endian byte count and the text — UTF-8, or
//  UTF-16 behind a byte-order mark — optionally followed by style boxes,
//  which a reader skips. An empty sample (count zero) is a gap.
//

import CoreMedia
import Foundation

/// Encodes and decodes `tx3g` subtitle samples.
enum TX3G {

    /// The most text one sample can carry: the count is sixteen bits.
    static let maximumBytes = Int(UInt16.max)

    /// The sample description every written track uses: white 16-point text
    /// on a transparent background, centred at the bottom — the defaults
    /// AVFoundation reports for an ffmpeg-written track, which every player
    /// tested honours or overrides with its own subtitle style.
    static func formatDescription() throws -> CMFormatDescription {
        let white: [String: Any] = ["Red": -1, "Green": -1, "Blue": -1, "Alpha": -1]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,
            kCMTextFormatDescriptionExtension_BackgroundColor: ["Red": 0, "Green": 0, "Blue": 0, "Alpha": -1],
            kCMTextFormatDescriptionExtension_DefaultTextBox: ["Top": 0, "Left": 0, "Bottom": 0, "Right": 0],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                "StartChar": 0, "EndChar": 0, "Font": 1, "FontFace": 0, "FontSize": 16,
                "ForegroundColor": white,
            ],
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Arial"],
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: nil, mediaType: kCMMediaType_Subtitle, mediaSubType: kCMSubtitleFormatType_3GText,
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw VideoForgeError.invalidSubtitles("the subtitle format could not be described (\(status))")
        }
        return description
    }

    /// One sample's bytes: the count, then the UTF-8 text.
    ///
    /// - Throws: ``VideoForgeError/invalidSubtitles(_:)`` when the text is
    ///   over 65,535 bytes, which the count cannot say.
    static func encode(_ text: String) throws -> Data {
        let utf8 = Data(text.utf8)
        guard utf8.count <= maximumBytes else {
            throw VideoForgeError.invalidSubtitles("a cue holds \(utf8.count) bytes of text; a subtitle sample holds at most \(maximumBytes)")
        }
        var data = Data([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)])
        data.append(utf8)
        return data
    }

    /// The text of one sample — `""` for a gap — or nil when the bytes are
    /// not a `tx3g` sample.
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let count = Int(bytes[0]) << 8 | Int(bytes[1])
        guard count > 0 else { return "" }
        guard 2 + count <= bytes.count else { return nil }
        let text = Array(bytes[2..<(2 + count)])
        if text.count >= 2, text[0] == 0xFE, text[1] == 0xFF {
            return String(bytes: text.dropFirst(2), encoding: .utf16BigEndian)
        }
        return String(bytes: text, encoding: .utf8)
    }
}
