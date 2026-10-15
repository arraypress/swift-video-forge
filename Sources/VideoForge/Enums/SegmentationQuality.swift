//
//  SegmentationQuality.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Vision's person-segmentation quality levels.
public enum SegmentationQuality: String, CaseIterable, Sendable, Codable, Hashable {
    case fast, balanced, accurate
}
