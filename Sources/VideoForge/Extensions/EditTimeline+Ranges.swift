//
//  EditTimeline+Ranges.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

extension EditTimeline {

    /// Where each clip lands on an edit, end to end, given each file's
    /// length in seconds — for resolving times that refer to clips before
    /// the edit is rendered.
    ///
    /// - Parameters:
    ///   - clips: The clips.
    ///   - lengths: Each clip's file length, in seconds.
    /// - Returns: Each clip's stretch of the edit.
    public static func ranges(of clips: [EditClip], lengths: [Double]) -> [ClosedRange<Double>] {
        EditRules.clipRanges(clips, lengths: lengths)
    }
}
