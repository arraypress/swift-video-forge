//
//  BeautyAndBlurTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Skin smoothing and background blur, measured blind on the written file:
//  fine texture is the difference between a frame and a lightly blurred
//  copy of it, so how much a pass softened is read off the pixels, inside
//  the face or the person and outside them, against an untouched redraw.
//

import AVFoundation
import CoreGraphics
import CoreImage
import ImageForge
import Vision
import XCTest
@testable import VideoForge

final class BeautyAndBlurTests: XCTestCase {

    var directory: URL!
    var portrait: URL!
    /// The face, from Vision on the source, top-left pixels.
    var face: CGRect = .zero

    static let width = 1280, height = 720

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        portrait = directory.appendingPathComponent("portrait.mov")
        let image = try TestClips.face()
        // A busy checkerboard behind the portrait, and a fixed grain over
        // everything — the "texture" the passes soften.
        try await TestClips.writeDrawn(to: portrait, seconds: 1, width: Self.width, height: Self.height) { context, _ in
            for row in 0..<(Self.height / 8) {
                for column in 0..<(Self.width / 8) {
                    context.setFillColor(CGColor(gray: (row + column) % 2 == 0 ? 0.35 : 0.65, alpha: 1))
                    context.fill(CGRect(x: column * 8, y: row * 8, width: 8, height: 8))
                }
            }
            context.draw(image, in: CGRect(x: 640, y: 0, width: 640, height: 640))
            var state: UInt32 = 0x9E37_79B9
            for y in stride(from: 0, to: Self.height, by: 2) {
                for x in stride(from: 0, to: Self.width, by: 2) {
                    state ^= state << 13; state ^= state >> 17; state ^= state << 5
                    context.setFillColor(CGColor(gray: state & 1 == 0 ? 0 : 1, alpha: 0.06))
                    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
        let first = try await TestClips.decodedFrames(of: portrait)[0]
        let faces = try await Detectors.faces(in: try XCTUnwrap(first.image))
        face = try XCTUnwrap(faces.max { $0.rect.width < $1.rect.width }).rect
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// A frame's luma, 0–255.
    func luma(_ frame: DecodedFrame) -> [Float] {
        (0..<(frame.width * frame.height)).map { index in
            let p = frame.rgb(index % frame.width, index / frame.width)
            return 0.2126 * Float(p.r) + 0.7152 * Float(p.g) + 0.0722 * Float(p.b)
        }
    }

    /// Fine texture: each pixel less the mean of its 5×5 neighbourhood.
    func texture(_ luma: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: luma.count)
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                var sum: Float = 0
                for dy in -2...2 { for dx in -2...2 { sum += luma[(y + dy) * width + x + dx] } }
                out[y * width + x] = luma[y * width + x] - sum / 25
            }
        }
        return out
    }

    func rms(_ values: [Float], where keep: (Int, Int) -> Bool, width: Int) -> Double {
        var (sum, count) = (0.0, 0)
        for (index, value) in values.enumerated() where keep(index % width, index / width) {
            sum += Double(value * value)
            count += 1
        }
        return (sum / Double(max(1, count))).squareRoot()
    }

    func psnr(_ a: [Float], _ b: [Float], where keep: (Int, Int) -> Bool, width: Int) -> Double {
        var (sum, count) = (0.0, 0)
        for index in a.indices where keep(index % width, index / width) {
            let d = Double(a[index] - b[index])
            sum += d * d
            count += 1
        }
        return 10 * log10(255 * 255 / max(sum / Double(max(1, count)), 1e-9))
    }

    // MARK: - Beauty

    func testSmoothingSoftensTheFaceAndNothingElse() async throws {
        let (w, h) = (Self.width, Self.height)
        // An untouched redraw through the same road: what re-encoding alone does.
        let plain = out("plain.mov")
        try await VideoForge.process(portrait, to: plain, options: VideoProcessOptions(
            operations: [.blurBackground(BackgroundBlur(amount: 0))]))
        let source = luma(try await TestClips.decodedFrames(of: portrait)[15])
        let redrawn = luma(try await TestClips.decodedFrames(of: plain)[15])
        // The cheeks: the face box's lower middle, clear of eyes and mouth.
        let cheeks = CGRect(x: face.minX + face.width * 0.1, y: face.minY + face.height * 0.45,
                            width: face.width * 0.8, height: face.height * 0.15)
        let inCheeks = { (x: Int, y: Int) in cheeks.contains(CGPoint(x: x, y: y)) }
        // Well clear of the face: everything outside a box twice its size.
        let around = face.insetBy(dx: -face.width * 0.6, dy: -face.height * 0.6)
        let outside = { (x: Int, y: Int) in !around.contains(CGPoint(x: x, y: y)) }
        let before = rms(texture(redrawn, width: w, height: h), where: inCheeks, width: w)

        for smoothing in [0.5, 1.0] {
            let written = out("beauty-\(smoothing).mov")
            let done = try await VideoForge.beautify(portrait, to: written, beauty: Beauty(smoothing: smoothing))
            XCTAssertGreaterThan(done.faceSamples, 0, "the face was tracked")
            let after = luma(try await TestClips.decodedFrames(of: written)[15])
            let left = rms(texture(after, width: w, height: h), where: inCheeks, width: w) / before
            // Texture left on the cheeks: about 1 − smoothing.
            print("MEASURED beauty \(smoothing): cheeks kept \(left); outside PSNR \(psnr(source, after, where: outside, width: w)) vs \(psnr(source, redrawn, where: outside, width: w))")
            XCTAssertEqual(left, 1 - smoothing, accuracy: 0.2, "smoothing \(smoothing) left \(left) of the texture")
            // Outside the face: what a plain redraw gives, within half a dB.
            let unchanged = psnr(source, redrawn, where: outside, width: w)
            let touched = psnr(source, after, where: outside, width: w)
            XCTAssertEqual(touched, unchanged, accuracy: 0.5, "outside the face: \(touched) dB vs \(unchanged) dB")
        }
    }

    // MARK: - Background blur

    /// Where Vision finds a person in the source, accurately: inside (well
    /// inside) and outside (well outside) as per-pixel tests.
    func personRegions() async throws -> (inside: (Int, Int) -> Bool, outside: (Int, Int) -> Bool) {
        let first = try await TestClips.decodedFrames(of: portrait)[15]
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: try XCTUnwrap(first.image)).perform([request])
        let buffer = try XCTUnwrap(request.results?.first?.pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let (mw, mh) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        var mask = [UInt8](repeating: 0, count: mw * mh)
        for y in 0..<mh { for x in 0..<mw { mask[y * mw + x] = base[y * stride + x] } }
        let (w, h) = (Self.width, Self.height)
        // A pixel is "well" inside or outside when every mask sample within
        // 48 px of it agrees.
        let reach = 48
        func all(_ x: Int, _ y: Int, _ test: (UInt8) -> Bool) -> Bool {
            for dy in Swift.stride(from: -reach, through: reach, by: 8) {
                for dx in Swift.stride(from: -reach, through: reach, by: 8) {
                    let mx = min(mw - 1, max(0, (x + dx) * mw / w)), my = min(mh - 1, max(0, (y + dy) * mh / h))
                    if !test(mask[my * mw + mx]) { return false }
                }
            }
            return true
        }
        return ({ x, y in all(x, y) { $0 > 230 } }, { x, y in all(x, y) { $0 < 25 } })
    }

    /// Written as ProRes, so the pass is measured and not the encoder:
    /// through H.264 the person kept 93% of their texture — the encoder's
    /// rate control, measured by writing the same two jobs as ProRes, where
    /// they keep 100%.
    func testTheBackgroundBlursAndThePersonStaysSharp() async throws {
        let (w, h) = (Self.width, Self.height)
        let plain = out("plain.mov")
        try await VideoForge.process(portrait, to: plain, options: VideoProcessOptions(
            operations: [.blurBackground(BackgroundBlur(amount: 0))], export: ExportSpec(codec: .proRes422)))
        let written = out("blurred.mov")
        try await VideoForge.process(portrait, to: written, options: VideoProcessOptions(
            operations: [.blurBackground(BackgroundBlur())], export: ExportSpec(codec: .proRes422)))
        let regions = try await personRegions()
        let before = texture(luma(try await TestClips.decodedFrames(of: plain)[15]), width: w, height: h)
        let after = texture(luma(try await TestClips.decodedFrames(of: written)[15]), width: w, height: h)
        let outsideLeft = rms(after, where: regions.outside, width: w) / rms(before, where: regions.outside, width: w)
        let insideLeft = rms(after, where: regions.inside, width: w) / rms(before, where: regions.inside, width: w)
        print("MEASURED blur: background kept \(outsideLeft), person kept \(insideLeft)")
        XCTAssertLessThan(outsideLeft, 0.3, "the background kept \(outsideLeft) of its texture")
        XCTAssertEqual(insideLeft, 1, accuracy: 0.05, "the person kept \(insideLeft) of theirs")
    }
}
