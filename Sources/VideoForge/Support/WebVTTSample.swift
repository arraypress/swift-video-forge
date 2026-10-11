//
//  WebVTTSample.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  WebVTT carried in an MP4 (`wvtt`, ISO 14496-30) — read only. Each sample
//  is a run of boxes: a `vttc` per cue on screen, holding a `payl` with the
//  text, or a lone `vtte` for a gap. Writing it is not offered: no player
//  tested would list such a track (see TX3G.swift).
//

import Foundation

/// Decodes `wvtt` subtitle samples.
enum WebVTTSample {

    /// The text of every cue in one sample — empty for a gap — or nil when
    /// the boxes do not parse.
    static func decode(_ data: Data) -> [String]? {
        guard let boxes = boxes(in: [UInt8](data)) else { return nil }
        return boxes.compactMap { box in
            guard box.type == "vttc", let inner = self.boxes(in: box.body),
                  let payload = inner.first(where: { $0.type == "payl" }) else { return nil }
            return String(bytes: payload.body, encoding: .utf8)
        }
    }

    /// The boxes in a byte run, or nil when a size runs past the end.
    static func boxes(in bytes: [UInt8]) -> [(type: String, body: [UInt8])]? {
        var result: [(type: String, body: [UInt8])] = []
        var offset = 0
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { return nil }
            let size = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard size >= 8, offset + size <= bytes.count else { return nil }
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            result.append((type, Array(bytes[(offset + 8)..<(offset + size)])))
            offset += size
        }
        return result
    }
}
