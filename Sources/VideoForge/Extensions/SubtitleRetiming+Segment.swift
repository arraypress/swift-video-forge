//
//  SubtitleRetiming+Segment.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import AVFoundation
import Foundation

extension SubtitleRetiming.Segment {

    /// An edit as AVFoundation describes it — a file track's, or a
    /// composition track's, whose segments are the same type.
    init(_ segment: AVAssetTrackSegment) {
        self.init(source: segment.isEmpty ? nil : segment.timeMapping.source,
                  target: segment.timeMapping.target)
    }
}
