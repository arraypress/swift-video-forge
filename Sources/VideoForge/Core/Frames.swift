//
//  Frames.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Pulling stills out, and turning them into a loop.
//
//  The GIF is not written here. `swift-image-forge` already writes animated
//  GIF, APNG and animated HEIF from a list of frames, with the per-frame
//  delay handling that keeps a fast loop from replaying at a crawl; this
//  file's job is to produce the frames and hand them over. Writing a second
//  GIF encoder next to a working one is how a fleet ends up fixing the same
//  bug twice.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageForge

/// Takes stills out of a movie.
public enum Frames {

    /// How much memory a run of frames is allowed to hold at once.
    ///
    /// MEASURED: 90 frames of a *640×360* clip is 79 MB as BGRA. The same
    /// arithmetic on ten seconds of 4K comes to roughly ten gigabytes,
    /// which is why anything that holds every frame at once — reversing,
    /// above all — asks this first and refuses rather than taking the
    /// machine down with it.
    public static let defaultMemoryBudget = 2 * 1_073_741_824

    /// What holding a run of frames uncompressed would cost, in bytes.
    ///
    /// - Parameters:
    ///   - size: The frame size.
    ///   - count: How many frames.
    /// - Returns: The cost in bytes, at four bytes a pixel.
    public static func memoryCost(size: CGSize, count: Int) -> Int {
        Int(size.width * size.height) * 4 * max(0, count)
    }

    /// Stills at given times.
    ///
    /// - Parameters:
    ///   - url: The movie to read.
    ///   - times: When to grab, in seconds.
    ///   - maxPixelSize: Bound the longest side of each still.
    /// - Returns: One frame per time, in order, with the time it came from.
    /// - Throws: ``VideoForgeError`` when the movie has no video.
    public static func at(_ url: URL, times: [Double],
                          maxPixelSize: Int? = nil) async throws -> [(seconds: Double, image: CGImage)] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw VideoForgeError.noVideoTrack(url)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Exact times, not "near enough": a caller asking for the frame at
        // 4.000s and silently getting the one at 3.500s has no way to tell.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxPixelSize {
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        }

        var frames: [(Double, CGImage)] = []
        for seconds in times {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            frames.append((seconds, image))
        }
        guard !frames.isEmpty else {
            throw VideoForgeError.emptyRange("the times asked for")
        }
        return frames
    }

    /// Stills at a steady rate through the movie.
    ///
    /// - Parameters:
    ///   - url: The movie to read.
    ///   - fps: How many stills per second of footage.
    ///   - trim: A stretch to take them from, or nil for all of it.
    ///   - maxPixelSize: Bound the longest side of each still.
    ///   - budget: Refuse rather than hold more than this many bytes.
    /// - Returns: The frames, in order.
    /// - Throws: ``VideoForgeError/reverseTooLarge(needs:budget:)`` when the
    ///   run would not fit in memory.
    public static func every(_ url: URL, fps: Double, trim: TrimSpec? = nil,
                             maxPixelSize: Int? = nil,
                             budget: Int = defaultMemoryBudget) async throws -> [(seconds: Double, image: CGImage)] {
        let info = try await Probe.describe(url)
        guard info.hasVideo else { throw VideoForgeError.noVideoTrack(url) }
        guard fps > 0 else { throw VideoForgeError.emptyRange("a rate of \(fps) frames a second") }

        let start = trim?.start ?? 0
        let length = trim?.duration ?? max(0, info.duration - start)
        let count = max(1, Int(length * fps))

        let side = maxPixelSize.map(CGFloat.init)
        let size = side.map { CGSize(width: $0, height: $0) } ?? info.size
        let cost = memoryCost(size: size, count: count)
        guard cost <= budget else {
            throw VideoForgeError.reverseTooLarge(needs: cost, budget: budget)
        }

        let times = (0..<count).map { start + Double($0) / fps }
        return try await at(url, times: times, maxPixelSize: maxPixelSize)
    }

    /// Writes an animation from a stretch of a movie.
    ///
    /// The frames are pulled at `fps` and handed to
    /// [ImageForge](https://github.com/arraypress/swift-image-forge), which
    /// owns every animated format this can write — GIF, APNG and animated
    /// HEIF — and the per-frame delays they need.
    ///
    /// - Parameters:
    ///   - url: The movie to read.
    ///   - destination: Where to write.
    ///   - format: `.gif`, `.png` for an APNG, or `.heicSequence`.
    ///   - fps: Frames per second of the loop.
    ///   - trim: The stretch to take, or nil for all of it.
    ///   - maxPixelSize: Bound the longest side.
    ///   - animation: Loop count, reversal, ping-pong, stride.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: How many bytes were written.
    /// - Throws: Any ``VideoForgeError``, or the image library's own.
    @discardableResult
    public static func animate(_ url: URL, to destination: URL,
                               format: ImageFormat = .gif,
                               fps: Double = 12,
                               trim: TrimSpec? = nil,
                               maxPixelSize: Int? = 480,
                               animation: AnimationSpec = .default,
                               overwrites: Bool = false) async throws -> Int {
        try VideoForge.check(destination, overwrites: overwrites)
        let grabbed = try await every(url, fps: fps, trim: trim, maxPixelSize: maxPixelSize)
        let frames = grabbed.map { ImageFrame(image: $0.image, duration: 1 / fps) }

        var spec = animation
        if spec.frameDuration == nil { spec.frameDuration = 1 / fps }
        let data = try ImageEncoder.encode(frames: frames, format: format,
                                           spec: EncodeSpec(format: format), animation: spec)
        return try ImageEncoder.write(data, to: destination, overwrites: overwrites)
    }

    /// Writes every frame of a stretch as separate image files.
    ///
    /// - Parameters:
    ///   - url: The movie to read.
    ///   - directory: Where to write them.
    ///   - fps: How many stills per second of footage.
    ///   - trim: The stretch to take, or nil for all of it.
    ///   - format: The image format to write.
    ///   - maxPixelSize: Bound the longest side.
    ///   - overwrites: Whether existing files may be replaced.
    /// - Returns: The files written, in order.
    /// - Throws: Any ``VideoForgeError``.
    @discardableResult
    public static func write(_ url: URL, into directory: URL,
                             fps: Double = 1, trim: TrimSpec? = nil,
                             format: ImageFormat = .png,
                             maxPixelSize: Int? = nil,
                             overwrites: Bool = false) async throws -> [URL] {
        let grabbed = try await every(url, fps: fps, trim: trim, maxPixelSize: maxPixelSize)
        let stem = url.deletingPathExtension().lastPathComponent

        return try grabbed.enumerated().map { index, frame in
            let destination = directory
                .appendingPathComponent(String(format: "%@-%04d", stem, index + 1))
                .appendingPathExtension(format.fileExtension)
            let data = try ImageEncoder.encode(frame.image, format: format,
                                               spec: EncodeSpec(format: format))
            try ImageEncoder.write(data, to: destination, overwrites: overwrites)
            return destination
        }
    }
}
