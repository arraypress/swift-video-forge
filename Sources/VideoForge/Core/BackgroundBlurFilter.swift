//
//  BackgroundBlurFilter.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The frame-by-frame half of a background blur: Vision's person
//  segmentation for the people, a variable blur for everything else. The
//  mask is feathered a little, so a hair's edge does not cut hard.
//

import CoreImage
import CoreVideo
import Foundation
import Synchronization
import Vision

/// Blurs what is behind the people in a frame.
final class BackgroundBlurFilter: Sendable {
    let settings: BackgroundBlur
    /// One request, reused frame to frame, behind a lock: the render road
    /// calls from several threads.
    private let request: Mutex<VNGeneratePersonSegmentationRequest>

    init(settings: BackgroundBlur) {
        self.settings = settings
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = switch settings.quality {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.request = Mutex(request)
    }

    /// The people in `image`, white, at its extent — nil when there are none.
    func people(in image: CIImage) -> CIImage? {
        let extent = image.extent
        let buffer: CVPixelBuffer? = request.withLock { request in
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return nil }
            return request.results?.first?.pixelBuffer
        }
        guard let buffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        return mask
            .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                               y: extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// The frame with everything but its people blurred.
    func apply(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard settings.amount > 0, let people = people(in: image) else { return image }
        let radius = BlurRules.radius(amount: settings.amount, height: extent.height)
        let feathered = people.clampedToExtent()
            .applyingGaussianBlur(sigma: BlurRules.feather(height: extent.height)).cropped(to: extent)
        // The variable blur blurs where its mask is white: the background.
        let background = feathered.applyingFilter("CIColorInvert")
        let blurred = image.clampedToExtent()
            .applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": background, "inputRadius": radius])
            .cropped(to: extent)
        // The people themselves come back untouched, not merely less blurred.
        return image.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": blurred, "inputMaskImage": feathered,
        ]).cropped(to: extent)
    }
}
