//
//  BlurRules.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

/// The background blur's numbers, relative to the frame so a 720p preview
/// and a 4K export blur alike.
enum BlurRules {

    /// The blur radius in pixels: `amount` × 4% of the frame's height.
    static func radius(amount: Double, height: CGFloat) -> Double {
        max(0, min(1, amount)) * 0.04 * Double(height)
    }

    /// How much the people's edge is softened, in pixels: 0.3% of the
    /// frame's height, at least one pixel.
    static func feather(height: CGFloat) -> Double {
        max(1, 0.003 * Double(height))
    }
}
