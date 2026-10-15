//
//  Placing.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Joining clips that are not all shown the same way. A composition track
//  has ONE transform, so up to 0.5.0 every clip of a join was turned with
//  the first clip's: a phone's portrait clip after a landscape one came out
//  lying on its side, and a portrait first clip turned every landscape clip
//  after it sideways.
//
//  The rule now: the join is shown the way its FIRST clip is shown, at that
//  clip's size. Every clip is turned upright by its own transform, scaled
//  to fit inside that frame without changing its shape, and centred, black
//  filling the rest — a portrait clip in a landscape join is pillarboxed,
//  a landscape one in a portrait join letterboxed. Nothing is cropped and
//  nothing is stretched; clips of a different shape used to be stretched.
//

import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

/// Turns and fits each clip of a join.
enum Placing {

    /// Whether the clips of a join need placing one by one: they are not
    /// all turned the same way, or not all the same shape once turned.
    ///
    /// Clips that agree on both are drawn as before — one transform for
    /// the track, and a plain scale for a clip of another size.
    ///
    /// - Parameters:
    ///   - transforms: Each clip's `preferredTransform`.
    ///   - shownSizes: Each clip's frame as shown, turn applied.
    static func needsPlacing(transforms: [CGAffineTransform], shownSizes: [CGSize]) -> Bool {
        guard let transform = transforms.first, let size = shownSizes.first, size.height > 0 else { return false }
        let ratio = size.width / size.height
        return transforms.contains { !$0.turnsLike(transform) }
            || shownSizes.contains { $0.height <= 0 || abs($0.width / $0.height - ratio) > 0.01 }
    }

    /// The clip playing at `seconds` — the last one starting at or before
    /// it — or nil for none.
    static func clip(at seconds: Double, in placements: [ClipPlacement]) -> ClipPlacement? {
        placements.last { $0.range.start.seconds <= seconds + 1e-6 } ?? placements.first
    }

    /// A stored frame turned upright by its clip's transform.
    ///
    /// The transform is in the stored frame's top-down pixel space; Core
    /// Image counts from the bottom, so it is mirrored into that space —
    /// `b` and `c` change sign — and the result moved back to the origin,
    /// which also does away with the transform's own translation.
    static func upright(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        let turn = CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c, d: transform.d,
                                     tx: 0, ty: 0)
        guard turn != .identity else { return image }
        let turned = image.transformed(by: turn)
        return turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX,
                                                        y: -turned.extent.minY))
    }

    /// An upright frame scaled to fit inside `size`, centred, on black.
    static func fitted(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let frame = CGRect(origin: .zero, size: size)
        let scale = min(size.width / extent.width, size.height / extent.height)
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (size.width - extent.width * scale) / 2,
                                               y: (size.height - extent.height * scale) / 2))
        return placed.composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame)
    }
}
