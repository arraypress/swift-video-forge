//
//  ComposeCompositor.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The compositor behind `compose`: every frame of an edit drawn in one go —
//  the clip on screen, framed and dipped, then the overlays over it, then
//  the drawings (titles, captions) over those. Same working space and colour
//  handling as the picture-in-picture compositor (see OverlayCompositor):
//  half float, Core Image's colour management on, written in the first
//  clip's colour space.
//

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

/// Renders an edit's frames.
final class ComposeCompositor: NSObject, AVVideoCompositing, Sendable {

    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_64RGBAHalf)],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_64RGBAHalf)],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let supportsWideColorSourceFrames = true
    let supportsHDRSourceFrames = true

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ComposeInstruction else {
            return request.finish(with: Self.failure("an instruction this compositor did not make"))
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            return request.finish(with: Self.failure("no buffer to render into"))
        }
        let plan = instruction.plan
        let time = request.compositionTime.seconds
        let image = Self.frame(at: time, plan: plan, clip: instruction.clip, overlays: instruction.overlays) { track in
            request.sourceFrame(byTrackID: track).map { CIImage(cvPixelBuffer: $0) }
        }
        let tags: [CFString: CFString] = [
            kCVImageBufferColorPrimariesKey: plan.primaries as CFString,
            kCVImageBufferTransferFunctionKey: plan.transfer as CFString,
            kCVImageBufferYCbCrMatrixKey: plan.matrix as CFString,
        ]
        for (key, value) in tags { CVBufferSetAttachment(output, key, value, .shouldPropagate) }
        let space = CVImageBufferCreateColorSpaceFromAttachments(tags as CFDictionary)?.takeRetainedValue()
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: plan.frame),
                       colorSpace: space ?? CGColorSpace(name: CGColorSpace.itur_709))
        request.finish(withComposedVideoFrame: output)
    }

    /// One frame of the edit, from the source frames `source` hands back by
    /// track — the same drawing for the written file and for stills.
    static func frame(at time: Double, plan: ComposePlan, clip: Int?, overlays: [Int],
                      source: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let bounds = CGRect(origin: .zero, size: plan.frame)
        let black = CIImage(color: .black).cropped(to: bounds)
        var image = black
        if let clip, clip < plan.clips.count, let stored = source(plan.mainTrack) {
            let placed = plan.clips[clip]
            let upright = Placing.upright(stored, transform: placed.transform)
            var picture = Self.placed(upright, in: placed.rect, frame: plan.frame)
            if placed.fit == .blur {
                // The same picture filling the frame, blurred and dimmed, behind it.
                let cover = EditRules.placement(of: upright.extent.size, in: plan.frame, fit: .fill,
                                                focus: CGPoint(x: 0.5, y: 0.5))
                let behind = Self.placed(upright, in: cover, frame: plan.frame)
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: Double(max(plan.frame.width, plan.frame.height)) * 0.03)
                    .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08])
                    .cropped(to: bounds)
                picture = picture.composited(over: behind)
            }
            image = picture.composited(over: black).cropped(to: bounds)
            let level = EditRules.brightness(at: time, range: placed.range, fadeIn: placed.fadeIn,
                                             fadeOut: placed.fadeOut, frameDuration: plan.frameDuration)
            if level < 1 {
                image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(1 - level)))
                    .cropped(to: bounds).composited(over: image)
            }
        }
        for index in overlays where index < plan.overlays.count {
            let overlay = plan.overlays[index]
            guard let stored = source(overlay.track) else { continue }
            let opacity = OverlayLayout.opacity(at: time, start: overlay.window.lowerBound, end: overlay.window.upperBound,
                                                fade: overlay.fade, frameDuration: plan.frameDuration)
            image = OverlayDrawing.composite(Placing.upright(stored, transform: overlay.transform), over: image,
                                             in: overlay.rect, frame: plan.frame, radius: overlay.radius,
                                             opacity: opacity)
        }
        for drawing in plan.drawings where time >= drawing.start - 1e-9 && time < drawing.end - 1e-9 {
            guard let picture = drawing.draw(time, plan.frame) else { continue }
            var layer = CIImage(cgImage: picture)
            if layer.extent.size != plan.frame {
                layer = layer.transformed(by: CGAffineTransform(scaleX: plan.frame.width / layer.extent.width,
                                                                y: plan.frame.height / layer.extent.height))
            }
            image = layer.composited(over: image).cropped(to: bounds)
        }
        return image
    }

    /// An upright picture scaled into a rectangle given from the top left.
    static func placed(_ image: CIImage, in rect: CGRect, frame: CGSize) -> CIImage {
        let scaled = OverlayDrawing.scaled(image, to: CGSize(width: rect.width.rounded(), height: rect.height.rounded()))
        return scaled.transformed(by: CGAffineTransform(translationX: rect.minX, y: frame.height - rect.maxY))
    }

    private static func failure(_ reason: String) -> NSError {
        NSError(domain: "VideoForge.ComposeCompositor", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "the edit could not be drawn: \(reason)"])
    }
}
