//
//  EditFit.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// How a clip in an edit fills a frame of another shape.
public enum EditFit: String, Sendable, Codable, CaseIterable, Hashable {
    /// Cover the frame, cropping what overhangs — around ``EditClip/focus``.
    case fill
    /// Show all of it, black around it.
    case fit
    /// Show all of it over a blurred, filled copy of itself — the usual way
    /// to put landscape footage in a vertical frame.
    case blur
}
