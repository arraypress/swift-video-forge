//
//  OverlayAlphaTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  An overlay's own transparency: up to vid 0.12.0 the overlay was blended
//  onto the main frame through the fade-and-rounding mask alone, so every
//  transparent pixel of a ProRes 4444 overlay came out black. Drawn here
//  without a file: a blue frame, a red overlay whose right half is clear.
//

import CoreImage
import XCTest
@testable import VideoForge

final class OverlayAlphaTests: XCTestCase {

    let frame = CGSize(width: 64, height: 64)
    let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))

    /// 32×32: opaque red on the left, clear on the right.
    var halfClear: CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 32))
        return red.composited(over: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)))
    }

    /// The RGB at a point counted from the TOP LEFT, 0–255.
    func pixel(_ image: CIImage, x: Int, y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        context.render(image, toBitmap: &bytes, rowBytes: 4,
                       bounds: CGRect(x: x, y: Int(frame.height) - 1 - y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return bytes.prefix(3).map(Int.init)
    }

    func testTheClearPartOfAnOverlayShowsTheFrameUnderneath() {
        let drawn = OverlayDrawing.composite(halfClear, over: blue, in: CGRect(x: 0, y: 0, width: 32, height: 32),
                                             frame: frame, radius: 0, opacity: 1)
        XCTAssertEqual(pixel(drawn, x: 8, y: 16), [255, 0, 0], "the opaque half is the overlay")
        XCTAssertEqual(pixel(drawn, x: 24, y: 16), [0, 0, 255], "the clear half shows the frame, not black")
        XCTAssertEqual(pixel(drawn, x: 48, y: 48), [0, 0, 255], "outside the overlay is untouched")
    }

    func testFadeAndRoundingStillApplyToTheOpaquePart() {
        let faded = OverlayDrawing.composite(halfClear, over: blue, in: CGRect(x: 0, y: 0, width: 32, height: 32),
                                             frame: frame, radius: 0, opacity: 0.5)
        let mid = pixel(faded, x: 8, y: 16)
        XCTAssert((100...155).contains(mid[0]) && (100...155).contains(mid[2]), "half faded is half each: \(mid)")
        let rounded = OverlayDrawing.composite(halfClear, over: blue, in: CGRect(x: 0, y: 0, width: 32, height: 32),
                                               frame: frame, radius: 12, opacity: 1)
        XCTAssertEqual(pixel(rounded, x: 0, y: 0), [0, 0, 255], "a rounded corner shows the frame")
    }
}
