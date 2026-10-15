//
//  OverlayDrawing.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  One frame of a picture-in-picture, as a Core Image graph: the overlay
//  scaled into its rectangle, rounded, faded, and laid over the main frame.
//  No pixel is touched here — the compositor renders the graph — so the
//  same graph serves 8-bit and 10-bit, SDR and HDR frames alike.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Builds a picture-in-picture frame.
enum OverlayDrawing {

    /// `overlay` laid over `main`.
    ///
    /// - Parameters:
    ///   - overlay: The overlay frame, upright, its extent at the origin.
    ///   - main: The main frame, upright, its extent at the origin.
    ///   - rect: Where the overlay goes, in pixels from the TOP LEFT. For a
    ///     full-frame overlay, the covering rectangle, which may overhang.
    ///   - frame: The written frame's size.
    ///   - radius: Corner rounding, in pixels.
    ///   - opacity: 0–1.
    /// - Returns: The frame, cropped to `frame`.
    static func composite(_ overlay: CIImage, over main: CIImage, in rect: CGRect,
                          frame: CGSize, radius: CGFloat, opacity: Double) -> CIImage {
        let bounds = CGRect(origin: .zero, size: frame)
        let extent = overlay.extent
        guard opacity > 0, extent.width > 0, extent.height > 0, rect.width > 0, rect.height > 0 else {
            return main.cropped(to: bounds)
        }
        // Core Image counts from the bottom.
        let target = CGRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height)
        let placed = scaled(overlay, to: target.size)
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))

        let shown = target.intersection(bounds)
        let tint = CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(opacity))
        let mask: CIImage
        if radius > 0 {
            let rounded = CIFilter.roundedRectangleGenerator()
            rounded.extent = target
            rounded.radius = Float(radius)
            rounded.color = tint
            mask = rounded.outputImage?.cropped(to: shown) ?? CIImage(color: tint).cropped(to: shown)
        } else {
            mask = CIImage(color: tint).cropped(to: shown)
        }
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = placed
        blend.backgroundImage = main
        blend.maskImage = mask
        return (blend.outputImage ?? main).cropped(to: bounds)
    }

    /// An image scaled to a size: Lanczos, which keeps a small overlay of a
    /// 4K clip from shimmering the way a plain linear scale does.
    static func scaled(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard extent.width > 0, extent.height > 0, size != extent.size else { return origin }
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = origin.clampedToExtent()
        scale.scale = Float(size.height / extent.height)
        scale.aspectRatio = Float((size.width / extent.width) / (size.height / extent.height))
        return (scale.outputImage ?? origin).cropped(to: CGRect(origin: .zero, size: size))
    }
}
