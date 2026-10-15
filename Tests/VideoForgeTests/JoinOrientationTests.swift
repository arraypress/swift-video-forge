//
//  JoinOrientationTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Joining clips turned different ways. Up to 0.5.0 the joined track took
//  the FIRST clip's transform, so a phone's portrait clip after a landscape
//  one lay on its side, and a portrait first clip turned every landscape
//  clip after it. The rule now (see Placing): the join is shown the way its
//  first clip is; each clip is turned upright by its own transform and
//  fitted inside, black around it. The truth for each clip is what
//  AVFoundation shows for that clip on its own.
//

import AVFoundation
import XCTest
@testable import VideoForge

final class JoinOrientationTests: XCTestCase {

    var directory: URL!
    var landscape: URL!, portrait: URL!, upsideDown: URL!

    /// A phone held upright: stored sideways, a quarter turn clockwise.
    let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
    let halfTurn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 320, ty: 180)

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        landscape = directory.appendingPathComponent("landscape.mov")
        portrait = directory.appendingPathComponent("portrait.mov")
        upsideDown = directory.appendingPathComponent("upside-down.mov")
        try await TestClips.writeQuadrants(to: landscape, transform: .identity)
        try await TestClips.writeQuadrants(to: portrait, transform: quarterTurn)
        try await TestClips.writeQuadrants(to: upsideDown, transform: halfTurn)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Column `index` of every row of a grid.
    func column(_ grid: String, _ index: Int) -> String {
        String(grid.split(separator: " ").map { Array($0)[index] })
    }

    func testTheClipsReallyAreTurned() async throws {
        let shown = try await TestClips.shownGrid(of: landscape, at: 0.5)
        XCTAssertEqual(shown, "RRGG RRGG BBWW BBWW")
        let turned = try await TestClips.shownGrid(of: portrait, at: 0.5)
        XCTAssertEqual(turned, "BBRR BBRR WWGG WWGG", "the quarter turn is clockwise")
        let flipped = try await TestClips.shownGrid(of: upsideDown, at: 0.5)
        XCTAssertEqual(flipped, "WWBB WWBB GGRR GGRR")
    }

    func testEachClipKeepsItsOwnTurnInALandscapeJoin() async throws {
        for (name, export) in [("session", ExportSpec()), ("writer", ExportSpec(frameRate: 24))] {
            let joined = out("landscape-first-\(name).mov")
            let result = try await VideoForge.join([landscape, portrait, upsideDown], to: joined, export: export)
            XCTAssertEqual(result.after.size, CGSize(width: 320, height: 180), name)

            let first = try await TestClips.shownGrid(of: joined, at: 0.5)
            let expectedFirst = try await TestClips.shownGrid(of: landscape, at: 0.5)
            XCTAssertEqual(first, expectedFirst, name)
            let third = try await TestClips.shownGrid(of: joined, at: 2.5)
            let expectedThird = try await TestClips.shownGrid(of: upsideDown, at: 0.5)
            XCTAssertEqual(third, expectedThird, "\(name): the third clip took another clip's turn")

            // The portrait clip, upright and pillarboxed: black either side,
            // its own picture in the middle.
            let middle = try await TestClips.shownGrid(of: joined, at: 1.5, columns: 8, rows: 4)
            let upright = try await TestClips.shownGrid(of: portrait, at: 0.5, columns: 2, rows: 4)
            for index in [0, 1, 2, 5, 6, 7] {
                XCTAssertEqual(column(middle, index), "....", "\(name): column \(index) of \(middle)")
            }
            XCTAssertEqual(column(middle, 3), column(upright, 0), "\(name): \(middle) vs \(upright)")
            XCTAssertEqual(column(middle, 4), column(upright, 1), "\(name): \(middle) vs \(upright)")
        }
    }

    func testAPortraitFirstClipMakesAPortraitJoin() async throws {
        let joined = out("portrait-first.mov")
        let result = try await VideoForge.join([portrait, landscape], to: joined)
        XCTAssertEqual(result.after.size, CGSize(width: 180, height: 320), "shown the way the first clip is")

        let first = try await TestClips.shownGrid(of: joined, at: 0.5)
        let expectedFirst = try await TestClips.shownGrid(of: portrait, at: 0.5)
        XCTAssertEqual(first, expectedFirst)

        // The landscape clip, letterboxed: black above and below.
        let second = try await TestClips.shownGrid(of: joined, at: 1.5, columns: 4, rows: 8)
        let rows = second.split(separator: " ").map(String.init)
        XCTAssertEqual(Array(rows[0...2]) + Array(rows[5...7]), Array(repeating: "....", count: 6), second)
        XCTAssertEqual(rows[3], "RRGG", second)
        XCTAssertEqual(rows[4], "BBWW", second)
    }

    /// Clips turned alike take the old road — the track carries their
    /// shared turn — and come out upright all the way through.
    func testClipsTurnedAlikeStayUpright() async throws {
        let twin = out("portrait-2.mov")
        try await TestClips.writeQuadrants(to: twin, transform: quarterTurn)
        let joined = out("portraits.mov")
        let result = try await VideoForge.join([portrait, twin], to: joined)
        XCTAssertEqual(result.after.size, CGSize(width: 180, height: 320))
        for at in [0.5, 1.5] {
            let shown = try await TestClips.shownGrid(of: joined, at: at)
            XCTAssertEqual(shown, "BBRR BBRR WWGG WWGG")
        }
    }

    func testPlacingIsNeededOnlyForDifferentTurnsOrShapes() {
        let wide = CGSize(width: 1920, height: 1080), tall = CGSize(width: 1080, height: 1920)
        XCTAssertFalse(Placing.needsPlacing(transforms: [.identity, .identity], shownSizes: [wide, wide]))
        XCTAssertFalse(Placing.needsPlacing(transforms: [.identity, .identity],
                                            shownSizes: [wide, CGSize(width: 1280, height: 720)]),
                       "a smaller clip of the same shape is only scaled")
        XCTAssertTrue(Placing.needsPlacing(transforms: [.identity, quarterTurn], shownSizes: [wide, tall]))
        XCTAssertTrue(Placing.needsPlacing(transforms: [quarterTurn, quarterTurn.translatedBy(x: 0, y: 0).concatenating(
            CGAffineTransform(scaleX: -1, y: 1))], shownSizes: [tall, tall]), "a mirror is a different turn")
        XCTAssertTrue(Placing.needsPlacing(transforms: [.identity, .identity],
                                           shownSizes: [wide, CGSize(width: 640, height: 480)]),
                      "a 4:3 clip in a 16:9 join is fitted, not stretched")
    }
}
