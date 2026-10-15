//
//  CGAffineTransform+Turns.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

extension CGAffineTransform {

    /// Whether two transforms turn and mirror a frame the same way —
    /// translations, which only move the turned frame back into view, aside.
    func turnsLike(_ other: CGAffineTransform) -> Bool {
        let close = { (x: CGFloat, y: CGFloat) in abs(x - y) < 1e-6 }
        return close(a, other.a) && close(b, other.b) && close(c, other.c) && close(d, other.d)
    }
}
