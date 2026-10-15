//
//  FaceScan.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Looking for faces in a stretch of a clip, for a picture-in-picture that
//  has to keep clear of them. Frames are sampled evenly over the stretch,
//  shown upright, and searched by swift-image-forge's Vision detector — the
//  same one, and the same confidence floor, `img` crops by.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageForge

/// Finds faces in a clip.
enum FaceScan {

    /// How many frames are looked at. A face that stays in frame is seen
    /// in all of them; one that walks across is seen wherever it went.
    static let frameCount = 9

    /// The longest side a sampled frame is searched at. Vision finds faces
    /// down to a few percent of the frame there, and a face smaller than
    /// that cannot meet a 5%-wide overlay by much.
    static let searchSize: CGFloat = 1920

    /// The faces seen in `url` between `start` and `end`.
    ///
    /// - Parameters:
    ///   - url: The clip.
    ///   - start: Where to start looking, in seconds.
    ///   - end: Where to stop.
    ///   - frame: The clip's frame as shown, which the rectangles are in.
    /// - Returns: How many frames were looked at, and every face in them,
    ///   in pixels of `frame` from the top left.
    /// - Throws: ``VideoForgeError/unreadable(_:reason:)``.
    static func faces(in url: URL, from start: Double, to end: Double,
                      frame: CGSize) async throws -> (frames: Int, faces: [CGRect]) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: searchSize, height: searchSize)
        let step = (end - start) / Double(frameCount)
        var looked = 0
        var found: [CGRect] = []
        for index in 0..<frameCount {
            let time = CMTime(seconds: start + (Double(index) + 0.5) * step, preferredTimescale: 600)
            let image: CGImage
            do { image = try await generator.image(at: time).image } catch { continue }
            looked += 1
            let scale = frame.width / CGFloat(max(1, image.width))
            let faces: [DetectedFace]
            do { faces = try await Detectors.faces(in: image) } catch {
                throw VideoForgeError.unreadable(url, reason: error.localizedDescription)
            }
            found += faces.map {
                CGRect(x: $0.rect.minX * scale, y: $0.rect.minY * scale,
                       width: $0.rect.width * scale, height: $0.rect.height * scale)
            }
        }
        guard looked > 0 else {
            throw VideoForgeError.unreadable(url, reason: "no frame between \(start) and \(end) s could be read")
        }
        return (looked, found)
    }
}
