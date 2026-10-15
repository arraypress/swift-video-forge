//
//  OverlayLayout.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Where a picture-in-picture goes and when it shows, as pure functions
//  over plain values, so each rule is pinned by a test with no video in
//  sight. Rectangles are pixels from the TOP LEFT of the frame as shown,
//  the convention `vid crop --rect` and `img` use; the compositor converts
//  to Core Image's bottom-left once.
//
//  The automatic corner is decided by looking, not by taste: the frames
//  under the overlay's stretch are searched for faces, and the corner that
//  covers the smallest share of any face wins — ties going to the corner
//  farthest from every face, then to bottom right. No threshold is
//  involved: a corner either covers part of a face or it does not.
//

import CoreGraphics
import Foundation

/// The picture-in-picture layout rules.
enum OverlayLayout {

    // MARK: - Checking

    /// What is wrong with a picture-in-picture's settings, if anything.
    static func problem(with pip: PictureInPicture) -> String? {
        if !(pip.start >= 0) { return "the overlay's start cannot be negative" }
        if let end = pip.end, !(end > pip.start) { return "the overlay's end must be after its start" }
        if !(0.05...1).contains(pip.size) { return "the overlay's size is 0.05 to 1 of the frame's width" }
        if !(0...0.4).contains(pip.margin) { return "the margin is 0 to 0.4 of the frame's shorter side" }
        if !(0...0.5).contains(pip.roundness) { return "roundness is 0 to 0.5" }
        if !(pip.fade >= 0) { return "the fade cannot be negative" }
        if !(0...1).contains(pip.mix) { return "the overlay's mix is 0 to 1" }
        return nil
    }

    // MARK: - Where

    /// The overlay's rectangle in a corner, whole pixels.
    ///
    /// Its width is `size` of the frame's; its height follows its own
    /// shape. One too tall for the frame — a portrait clip over a landscape
    /// one — is shrunk, keeping its shape, to fit inside the margins.
    ///
    /// - Parameters:
    ///   - corner: A real corner; ``PictureCorner/auto`` is treated as
    ///     bottom right.
    ///   - frame: The main clip's frame as shown.
    ///   - overlay: The overlay's frame as shown.
    ///   - size: Its width as a share of the frame's.
    ///   - margin: The gap to the edges as a share of the shorter side.
    /// - Returns: The rectangle, from the top left.
    static func rect(for corner: PictureCorner, frame: CGSize, overlay: CGSize,
                     size: Double, margin: Double) -> CGRect {
        guard frame.width > 0, frame.height > 0, overlay.width > 0, overlay.height > 0 else { return .zero }
        let gap = (CGFloat(margin) * min(frame.width, frame.height)).rounded()
        let shape = overlay.height / overlay.width
        var width = frame.width * CGFloat(size)
        width = min(width, frame.width - 2 * gap)
        var height = width * shape
        if height > frame.height - 2 * gap {
            height = frame.height - 2 * gap
            width = height / shape
        }
        width = max(2, width.rounded())
        height = max(2, height.rounded())
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: left ? gap : frame.width - gap - width,
                      y: top ? gap : frame.height - gap - height,
                      width: width, height: height)
    }

    /// The overlay scaled to cover the whole frame and centred — the part
    /// outside the frame is cropped away.
    static func cover(frame: CGSize, overlay: CGSize) -> CGRect {
        guard overlay.width > 0, overlay.height > 0 else { return CGRect(origin: .zero, size: frame) }
        let scale = max(frame.width / overlay.width, frame.height / overlay.height)
        let size = CGSize(width: overlay.width * scale, height: overlay.height * scale)
        return CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The corner radius in pixels for a rectangle.
    static func radius(roundness: Double, of rect: CGRect) -> CGFloat {
        CGFloat(max(0, min(0.5, roundness))) * min(rect.width, rect.height)
    }

    // MARK: - Which corner

    /// The largest share of any one face that `rect` covers, 0–1.
    static func coverage(of rect: CGRect, faces: [CGRect]) -> Double {
        faces.reduce(0) { most, face in
            let area = face.width * face.height
            guard area > 0 else { return most }
            let shared = rect.intersection(face)
            return shared.isNull ? most : max(most, Double(shared.width * shared.height / area))
        }
    }

    /// The gap between `rect` and the nearest face, in pixels: 0 when one
    /// touches it, infinite when there are none.
    static func clearance(of rect: CGRect, faces: [CGRect]) -> Double {
        faces.reduce(.infinity) { nearest, face in
            let dx = max(0, max(face.minX - rect.maxX, rect.minX - face.maxX))
            let dy = max(0, max(face.minY - rect.maxY, rect.minY - face.maxY))
            return min(nearest, Double((dx * dx + dy * dy).squareRoot()))
        }
    }

    /// The corner that covers the least of any face; then the one farthest
    /// from every face; then the earlier in ``PictureCorner/corners``.
    ///
    /// - Parameters:
    ///   - candidates: Each corner and its rectangle, in preference order.
    ///   - faces: Every face seen under the overlay's stretch, from the top
    ///     left, all frames together.
    /// - Returns: The winner and the share of a face it covers.
    static func choose(among candidates: [(corner: PictureCorner, rect: CGRect)],
                       faces: [CGRect]) -> (corner: PictureCorner, rect: CGRect, coverage: Double) {
        var best: (corner: PictureCorner, rect: CGRect, coverage: Double, clearance: Double)?
        for candidate in candidates {
            let covered = coverage(of: candidate.rect, faces: faces)
            let clear = clearance(of: candidate.rect, faces: faces)
            if let current = best,
               covered > current.coverage || (covered == current.coverage && clear <= current.clearance) {
                continue
            }
            best = (candidate.corner, candidate.rect, covered, clear)
        }
        guard let best else { return (.bottomRight, .zero, 0) }
        return (best.corner, best.rect, best.coverage)
    }

    // MARK: - When

    /// When the overlay shows: from `start` to `end`, or to the overlay's
    /// own end, cut to the main clip's.
    ///
    /// - Throws: ``VideoForgeError/invalidOptions(_:)`` when that leaves
    ///   nothing — an overlay starting after the main clip ends.
    static func window(start: Double, end: Double?, overlayDuration: Double,
                       mainDuration: Double) throws -> (start: Double, end: Double) {
        guard start < mainDuration else {
            throw VideoForgeError.invalidOptions(String(format: "the overlay starts at %.2f s, after the %.2f s clip ends",
                                                        start, mainDuration))
        }
        let stop = min(end ?? .infinity, start + overlayDuration, mainDuration)
        guard stop > start + 0.001 else {
            throw VideoForgeError.invalidOptions("the overlay has nothing to show — it is empty")
        }
        return (start, stop)
    }

    /// The overlay's opacity at `time`, 0–1.
    ///
    /// A fade ramps in from the first frame and out to the last, each
    /// frame lit as if sampled at its END: the first frame of a 0.5 s fade
    /// at 30 fps shows at 1/15, never at 0, so the overlay is on screen
    /// from the frame it was asked for — and the last frame before `end`
    /// is still faintly there.
    ///
    /// - Parameters:
    ///   - time: The frame's time on the written timeline.
    ///   - start: When the overlay appears.
    ///   - end: When it goes.
    ///   - fade: Seconds to fade in and out; 0 cuts.
    ///   - frameDuration: One frame, in seconds.
    static func opacity(at time: Double, start: Double, end: Double, fade: Double, frameDuration: Double) -> Double {
        guard time >= start - 1e-9, time < end - 1e-9 else { return 0 }
        guard fade > 0 else { return 1 }
        let rising = (time - start + frameDuration) / fade
        let falling = (end - time) / fade
        return max(0, min(1, rising, falling))
    }
}
