//
//  SceneScan.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  One pass over a video's picture that finds where the shots change: every
//  frame (up to 30 a second) decoded small and reduced to a colour
//  histogram, and an image fingerprint (Vision's feature print) every
//  quarter-second for dissolves. The rules are SceneCuts'.
//

import AVFoundation
import CoreVideo
import Foundation
import Vision

/// Finds the shots of a video.
public enum Scenes {

    /// Frames are read at this size: enough for a histogram and a
    /// fingerprint, and decoding to it is the hardware's job.
    static let readWidth = 256
    static let readHeight = 144
    /// Faster footage is read every few frames, down to about this rate.
    static let maximumRate = 30.0

    /// Where the picture changes to another shot.
    ///
    /// ```swift
    /// let report = try await Scenes.detect(url)
    /// report.changes      // [cut at 2.5, cut at 7.5, dissolve at 12.4 …]
    /// report.scenes       // [0..<2.5, 2.5..<7.5, …]
    /// ```
    ///
    /// Hard cuts land on the first frame of the new shot; dissolves on
    /// their middle. Camera moves, zooms, lighting changes and flashes are
    /// not changes. A dissolve between two pictures that look alike can be
    /// missed. About 1 ms a frame for 1080p H.264 on Apple silicon.
    ///
    /// - Parameters:
    ///   - url: The video.
    ///   - progress: Called now and then with the fraction read, 0–1.
    /// - Throws: ``VideoForgeError/noVideoTrack(_:)``,
    ///   ``VideoForgeError/unreadable(_:reason:)``, or cancellation.
    public static func detect(_ url: URL,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> SceneReport {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoForgeError.noVideoTrack(url)
        }
        let duration = try await asset.load(.duration).seconds
        let nominal = Double(try await track.load(.nominalFrameRate))
        let stride = nominal > maximumRate ? Int((nominal / maximumRate).rounded(.up)) : 1
        let rate = nominal > 0 ? nominal / Double(stride) : maximumRate

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw VideoForgeError.unreadable(url, reason: error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: readWidth, kCVPixelBufferHeightKey as String: readHeight,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoForgeError.unreadable(url, reason: "its picture cannot be decoded") }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoForgeError.unreadable(url, reason: reader.error?.localizedDescription ?? "its picture cannot be read")
        }

        var times: [Double] = []
        var histograms: [[Float]] = []
        var prints = FingerprintRing<VNFeaturePrintObservation>(distance: fingerprintDistance)
        var spans: [(time: Double, distance: Double)] = []
        var nextPrint = 0.0
        var decoded = 0
        var lastReport = 0.0
        while let sample = output.copyNextSampleBuffer() {
            defer { decoded += 1 }
            guard decoded % stride == 0, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            if decoded % (stride * 64) == 0 { try Task.checkCancellation() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            histograms.append(histogram(of: pixels))
            times.append(time)
            if time + 1e-6 >= nextPrint {
                nextPrint = ((time / SceneCuts.printStep).rounded(.down) + 1) * SceneCuts.printStep
                if let print = fingerprint(of: pixels), let span = prints.add(print, at: time) { spans.append(span) }
            }
            if let progress, duration > 0, time - lastReport >= 2 {
                lastReport = time
                progress(min(1, time / duration))
            }
        }
        if reader.status == .failed {
            throw VideoForgeError.unreadable(url, reason: reader.error?.localizedDescription ?? "its picture stopped decoding partway")
        }
        let cuts = SceneCuts.cuts(times: times, histograms: histograms, rate: rate)
        let dissolves = SceneCuts.dissolves(spans: spans, cuts: cuts)
        progress?(1)
        return SceneReport(duration: duration, framesRead: times.count,
                           changes: (cuts + dissolves).sorted { $0.time < $1.time })
    }

    /// A frame's colour histogram.
    static func histogram(of pixels: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return [] }
        return SceneCuts.histogram(base.assumingMemoryBound(to: UInt8.self),
                                   width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))
    }

    /// How far apart two feature prints are; nil if Vision cannot say.
    static func fingerprintDistance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Double? {
        var value: Float = 0
        guard (try? a.computeDistance(&value, to: b)) != nil else { return nil }
        return Double(value)
    }

    /// A frame's Vision feature print, revision 2 — the revision the
    /// dissolve threshold was measured with.
    static func fingerprint(of pixels: CVPixelBuffer) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        return request.results?.first
    }
}

/// The last six fingerprints, a quarter-second apart, and the dissolve
/// measure they give: the picture half a second before against half a second
/// after, the smaller of two such pairs a quarter-second apart — so one odd
/// frame (a flash) can spoil only one of them. Generic over the print so the
/// rule can be tested without Vision.
struct FingerprintRing<Print> {
    let distance: (Print, Print) -> Double?
    private var prints: [(time: Double, print: Print)] = []

    init(distance: @escaping (Print, Print) -> Double?) {
        self.distance = distance
    }

    /// Adds a print; once six are held (k-2 … k+3), returns the smaller of
    /// (k-2, k+2) and (k-1, k+3), timed between their centres k and k+1.
    mutating func add(_ print: Print, at time: Double) -> (time: Double, distance: Double)? {
        prints.append((time, print))
        if prints.count > 6 { prints.removeFirst() }
        guard prints.count == 6,
              let first = distance(prints[0].print, prints[4].print),
              let second = distance(prints[1].print, prints[5].print) else { return nil }
        return ((prints[2].time + prints[3].time) / 2, min(first, second))
    }
}
