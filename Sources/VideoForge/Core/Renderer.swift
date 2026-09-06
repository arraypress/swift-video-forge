//
//  Renderer.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The road that redraws every frame — cropping, scaling, turning,
//  mirroring. Built on `AVMutableVideoComposition` with a Core Image
//  handler, deliberately, rather than on a hand-rolled reader and writer.
//
//  The hand-rolled version is where the interleave deadlock lives: two
//  writer inputs, one drained ahead of the other, and the writer politely
//  pauses the one that ran ahead and waits forever. Letting AVFoundation
//  own the plumbing means audio, subtitle and timed-metadata tracks come
//  along untouched and the deadlock cannot be reintroduced by accident.
//
//  Frames arrive at the handler already ORIENTED — a phone clip shot
//  upright is presented upright, not sideways with a transform attached —
//  so the geometry here is in the coordinates a viewer sees.
//

import AVFoundation
import CoreImage
import VideoGrade
import CoreGraphics
import Foundation

/// Redraws frames.
public enum Renderer {

    /// Builds a video composition applying the frame operations in a job.
    ///
    /// - Parameters:
    ///   - asset: The source.
    ///   - operations: The steps. Time-only steps are ignored here — they
    ///     belong to the composition road and have already been applied.
    ///   - source: The frame's size, orientation applied.
    /// - Returns: The composition, and the size it renders at.
    /// - Throws: ``VideoForgeError`` when an operation cannot be honoured.
    public static func build(for asset: AVAsset,
                             operations: [VideoOperation],
                             source: CGSize) async throws -> (composition: AVMutableVideoComposition,
                                                              size: CGSize) {
        let plan = try Plan(operations: operations, source: source)
        let target = plan.outputSize

        let composition = try await AVMutableVideoComposition.videoComposition(
            with: asset) { request in
                // The frame's own time, so the animated parts of a grade —
                // grain, light leaks, film damage — move instead of being
                // frozen on one pattern for the whole clip.
                let rendered = plan.apply(to: request.sourceImage,
                                          at: request.compositionTime.seconds)
                request.finish(with: rendered, context: nil)
            }
        composition.renderSize = target
        return (composition, target)
    }

    /// What the frame operations come to, worked out once rather than per
    /// frame — a 4K clip at 60fps calls the handler fourteen thousand times
    /// a minute, and none of those should be re-deriving arithmetic.
    struct Plan {
        /// The rectangle taken out of the source, in Core Image's
        /// bottom-left coordinates.
        let crop: CGRect?
        /// The scale applied after cropping.
        let scale: CGSize
        /// The turn applied after scaling.
        let rotation: VideoRotation?
        /// The mirror applied last.
        let flip: VideoFlip?
        /// The colour and tone pass, built ONCE. A 4K clip at 60fps calls
        /// the handler fourteen thousand times a minute; rebuilding the
        /// filter chain — which bakes a 32³ colour cube — in each of those
        /// would dominate the run.
        let grade: GradeFilter?
        /// The size the composition renders at.
        let outputSize: CGSize

        /// - Parameters:
        ///   - operations: The steps, in order.
        ///   - source: The frame's size.
        /// - Throws: ``VideoForgeError/cropOutOfBounds(requested:frame:)``.
        init(operations: [VideoOperation], source: CGSize) throws {
            var cropRect: CGRect?
            var size = source
            var turn: VideoRotation?
            var mirror: VideoFlip?
            var scaleTo = size
            var look: GradeFilter?

            for operation in operations where !operation.isTimeOnly {
                switch operation {
                case .crop(let x, let y, let width, let height):
                    let requested = CGRect(x: x, y: y, width: width, height: height)
                    guard width > 0, height > 0,
                          CGRect(origin: .zero, size: size).contains(requested) else {
                        throw VideoForgeError.cropOutOfBounds(
                            requested: "\(width)×\(height) at \(x),\(y)",
                            frame: "\(Int(size.width))×\(Int(size.height))")
                    }
                    // Core Image counts from the bottom; everything a caller
                    // types counts from the top, as it does in `img`.
                    cropRect = CGRect(x: requested.minX,
                                      y: size.height - requested.maxY,
                                      width: requested.width, height: requested.height)
                    size = VideoSize.even(requested.size)
                    scaleTo = size

                case .aspect(let width, let height):
                    let ratio = CGFloat(width) / CGFloat(height)
                    var keep = CGSize(width: size.width, height: (size.width / ratio).rounded(.down))
                    if keep.height > size.height {
                        keep = CGSize(width: (size.height * ratio).rounded(.down), height: size.height)
                    }
                    keep = VideoSize.even(keep)
                    cropRect = CGRect(x: ((size.width - keep.width) / 2).rounded(),
                                      y: ((size.height - keep.height) / 2).rounded(),
                                      width: keep.width, height: keep.height)
                    size = keep
                    scaleTo = size

                case .resize(let spec):
                    let resolved = spec.resolved(from: size)
                    if !spec.fits {
                        // Filling means covering the box and giving back the
                        // overflow, so the crop happens on the SCALED frame.
                        let cover = max(resolved.width / size.width, resolved.height / size.height)
                        let scaled = CGSize(width: size.width * cover, height: size.height * cover)
                        scaleTo = scaled
                        cropRect = CGRect(x: ((scaled.width - resolved.width) / 2).rounded(),
                                          y: ((scaled.height - resolved.height) / 2).rounded(),
                                          width: resolved.width, height: resolved.height)
                        size = resolved
                    } else {
                        scaleTo = resolved
                        size = resolved
                    }

                case .rotate(let angle):
                    turn = angle
                    if angle.swapsAxes { size = CGSize(width: size.height, height: size.width) }

                case .flip(let axis):
                    mirror = axis

                case .grade(let wanted):
                    guard !wanted.isNeutral else { break }
                    do {
                        look = try GradeFilter(grade: wanted)
                    } catch {
                        // A named LUT that will not load is a mistake worth
                        // stopping for, not one to apply half of.
                        throw VideoForgeError.exportFailed(
                            reason: "the grade could not be built: \(error.localizedDescription)")
                    }

                default:
                    break
                }
            }

            crop = cropRect
            scale = scaleTo
            rotation = turn
            flip = mirror
            grade = look
            outputSize = VideoSize.even(size)
        }

        /// Applies the plan to one frame.
        ///
        /// - Parameters:
        ///   - image: The frame, already oriented.
        ///   - time: Where the frame sits in the composition, in seconds.
        ///     The grade's animated effects read it.
        /// - Returns: The frame to write.
        func apply(to image: CIImage, at time: TimeInterval = 0) -> CIImage {
            var output = image

            // A fill-resize scales first and crops the overflow; every other
            // crop takes its rectangle out of the source. Both are handled
            // by cropping whatever the plan says, after the scale it says.
            let sourceSize = output.extent.size
            if scale != sourceSize, sourceSize.width > 0, sourceSize.height > 0 {
                output = output.transformed(by: CGAffineTransform(
                    scaleX: scale.width / sourceSize.width,
                    y: scale.height / sourceSize.height))
            }
            if let crop {
                output = output.cropped(to: crop.offsetBy(dx: output.extent.minX,
                                                          dy: output.extent.minY))
                output = output.transformed(by: CGAffineTransform(
                    translationX: -output.extent.minX, y: -output.extent.minY))
            }
            if let rotation {
                output = output.transformed(by: CGAffineTransform(rotationAngle: -rotation.radians))
                output = output.transformed(by: CGAffineTransform(
                    translationX: -output.extent.minX, y: -output.extent.minY))
            }
            if let flip {
                let extent = output.extent
                let transform = flip == .horizontal
                    ? CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0)
                    : CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -extent.height)
                output = output.transformed(by: transform)
                output = output.transformed(by: CGAffineTransform(
                    translationX: -output.extent.minX, y: -output.extent.minY))
            }
            // Colour last, over the final geometry: grading before a crop
            // would compute a vignette and a grain field for pixels that are
            // about to be thrown away, and centre them on the wrong frame.
            if let grade {
                output = grade.apply(output, time: time)
            }
            return output
        }
    }
}
