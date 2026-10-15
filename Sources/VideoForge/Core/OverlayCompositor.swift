//
//  OverlayCompositor.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The custom compositor behind picture-in-picture. The Core Image filter
//  composition the render road uses hands its handler ONE source frame; an
//  overlay needs two, so this asks AVFoundation for both tracks' frames and
//  renders the graph OverlayDrawing builds.
//
//  Depth and colour, the codec plan's rules: frames are rendered in 16-bit
//  half float, so a 10-bit source keeps its levels, and in the main clip's
//  own colour space, so an HLG clip stays HLG; an SDR overlay is converted
//  into it (see the context below). Sources arrive as half-float RGB, which
//  AVFoundation decodes — an untagged clip as Rec. 709 (MEASURED: fed its
//  own Y'CbCr instead, Core Image read an untagged H.264 clip's with the
//  wrong matrix and pure red came out orange, everywhere).
//
//  A custom compositor gets each track's frames as STORED — a phone's
//  portrait clip lying on its side — so each is turned upright by its own
//  transform here (Placing), as a join's clips are.
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// What every frame of one picture-in-picture needs, worked out once.
struct OverlayPlan: Sendable {
    /// The main clip's video track in the composition.
    let mainTrack: CMPersistentTrackID
    /// The overlay's video track in the composition.
    let overlayTrack: CMPersistentTrackID
    /// The main clip's stored-to-shown transform.
    let mainTransform: CGAffineTransform
    /// The overlay's.
    let overlayTransform: CGAffineTransform
    /// The written frame: the main clip's, as shown.
    let frame: CGSize
    /// Where the overlay goes, from the top left; for a full-frame overlay,
    /// the rectangle that covers the frame.
    let rect: CGRect
    /// Corner rounding in pixels.
    let radius: CGFloat
    /// When it shows, and the fade, in seconds.
    let start: Double
    let end: Double
    let fade: Double
    /// One frame, in seconds.
    let frameDuration: Double
    /// The written colour tags.
    let primaries: String
    let transfer: String
    let matrix: String
}

/// One stretch of the composition: the main clip alone, or with the overlay.
final class OverlayInstruction: NSObject, AVVideoCompositionInstructionProtocol, Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    /// The frame recipe.
    let plan: OverlayPlan
    /// Whether the overlay is on screen anywhere in this stretch.
    let showsOverlay: Bool

    init(timeRange: CMTimeRange, plan: OverlayPlan, showsOverlay: Bool) {
        self.timeRange = timeRange
        self.plan = plan
        self.showsOverlay = showsOverlay
    }

    var requiredSourceTrackIDs: [NSValue]? {
        (showsOverlay ? [plan.mainTrack, plan.overlayTrack] : [plan.mainTrack]).map { NSNumber(value: $0) }
    }
}

/// Renders picture-in-picture frames.
final class OverlayCompositor: NSObject, AVVideoCompositing, Sendable {

    /// Half-float working space, so 10-bit and HDR values survive, with
    /// Core Image's colour management ON. MEASURED: AVFoundation hands each
    /// source over in its OWN colour space — an SDR overlay's 75% grey
    /// (Y′ 720) over an HLG clip arrived as SDR — so the frames are converted
    /// here, by their attachments, into the main clip's space: that grey is
    /// written at Y′ 625 in the HLG file. Unmanaged it went in at 723, SDR
    /// code values read as HLG. Main-clip pixels came out the same both ways.
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// What the sources arrive as: 16-bit half float, deep enough for any
    /// source. MEASURED against the alternatives on an 8-bit H.264 clip
    /// (PSNR outside the overlay against the source, ffmpeg decoding both):
    /// half float in and out 36.6 dB; 8-bit Y'CbCr in and out 35.4; Y'CbCr
    /// in, half float out 33.3; half float in, 10-bit Y'CbCr out 30.8. The
    /// render road's own redraws (a grade of contrast 1.001) measure 35.4 —
    /// the loss is the 4:2:0 chroma round trip at hard coloured edges.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_64RGBAHalf)],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    /// What frames are rendered into: 16-bit half float, deep enough for
    /// 10-bit and HDR whatever the source.
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_64RGBAHalf)],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let supportsWideColorSourceFrames = true
    let supportsHDRSourceFrames = true

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? OverlayInstruction else {
            return request.finish(with: Self.failure("an instruction this compositor did not make"))
        }
        let plan = instruction.plan
        guard let output = request.renderContext.newPixelBuffer() else {
            return request.finish(with: Self.failure("no buffer to render into"))
        }
        // Where the main clip's picture ends before its sound, there is no
        // frame to draw on: those frames are black, as a player shows them.
        var image = request.sourceFrame(byTrackID: plan.mainTrack)
            .map { Placing.upright(CIImage(cvPixelBuffer: $0), transform: plan.mainTransform) }
            ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: plan.frame))
        let time = request.compositionTime.seconds
        if instruction.showsOverlay, let overlayFrame = request.sourceFrame(byTrackID: plan.overlayTrack) {
            let opacity = OverlayLayout.opacity(at: time, start: plan.start, end: plan.end,
                                                fade: plan.fade, frameDuration: plan.frameDuration)
            let overlay = Placing.upright(CIImage(cvPixelBuffer: overlayFrame), transform: plan.overlayTransform)
            image = OverlayDrawing.composite(overlay, over: image, in: plan.rect, frame: plan.frame,
                                             radius: plan.radius, opacity: opacity)
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

    private static func failure(_ reason: String) -> NSError {
        NSError(domain: "VideoForge.OverlayCompositor", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "the overlay could not be drawn: \(reason)"])
    }
}
