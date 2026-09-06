//
//  VideoRotation.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

/// A clockwise quarter turn of the frame.
public enum VideoRotation: Int, CaseIterable, Sendable, Codable, Hashable {
    case ninety = 90
    case oneEighty = 180
    case twoSeventy = 270

    /// Whether this turn swaps the frame's width and height.
    public var swapsAxes: Bool { self == .ninety || self == .twoSeventy }

    /// The turn in radians, clockwise.
    public var radians: CGFloat { CGFloat(rawValue) * .pi / 180 }
}
