//
//  StatusStripStyleTests.swift
//  OmniTAKMobileTests
//
//  The status strip's text could not be read on the light street style (grey server name at
//  1.5 to 1 on a pale map) and was marginal on satellite. These pin its colours and backing.
//

import XCTest
@testable import OmniTAK

final class StatusStripStyleTests: XCTestCase {

    private let white = StatusStripStyle.RGB(r: 1, g: 1, b: 1)
    private let black = StatusStripStyle.RGB(r: 0, g: 0, b: 0)
    /// The land colour of the light street style, and a bright satellite scene (snow, sand, a roof).
    private let paleMap = StatusStripStyle.RGB(r: 0.93, g: 0.94, b: 0.94)
    private let brightSatellite = StatusStripStyle.RGB(r: 0.85, g: 0.82, b: 0.74)

    func testTheContrastRatioIsTheWCAGOne() {
        XCTAssertEqual(StatusStripStyle.contrast(white.luminance, black.luminance), 21, accuracy: 1e-9)
        XCTAssertEqual(StatusStripStyle.contrast(white.luminance, white.luminance), 1, accuracy: 1e-9)
        // mid grey (sRGB 0.5) is 0.2140 in luminance, so 4.0 against white
        XCTAssertEqual(StatusStripStyle.RGB(r: 0.5, g: 0.5, b: 0.5).luminance, 0.2140, accuracy: 1e-4)
    }

    func testEveryTextColourReadsAtFourPointFiveToOneOnTheWorstMapWeCanDraw() {
        // the worst map for a black backing is a white one
        for map in [white, paleMap, brightSatellite] {
            for text in StatusStripStyle.allText {
                XCTAssertGreaterThanOrEqual(StatusStripStyle.contrast(of: text, overMap: map), 4.5,
                                            "text \(text) over map \(map)")
            }
        }
    }

    func testTheLandscapeNameAndTheServerDotsAreDrawnInTheStylesColours() {
        // the "OmniTAK" name (yellow) and the dots of a server list are part of the strip too: they were
        // left in their own greens, greys and yellow, outside what is checked
        XCTAssertTrue(StatusStripStyle.allText.contains(StatusStripStyle.brand))
        XCTAssertTrue(StatusStripStyle.allText.contains(StatusStripStyle.good))
        XCTAssertTrue(StatusStripStyle.allText.contains(StatusStripStyle.quiet))
    }

    func testTheOldColoursOnTheOldBackingDidNotReadOnAPaleMap() {
        // the grey server name, the blue and the orange counts, and the green fix, on black at 50 percent
        let old: [StatusStripStyle.RGB] = [
            .init(r: 0.557, g: 0.557, b: 0.576), .init(r: 0.13, g: 0.59, b: 0.95),
            .init(r: 1.0, g: 0.63, b: 0.0), .init(r: 0.204, g: 0.78, b: 0.349),
        ]
        let worst = old.map { StatusStripStyle.contrast(of: $0, overMap: paleMap, backingOpacity: 0.5) }.min()!
        XCTAssertLessThan(worst, 2.5, "the numbers measured from the screenshot were 1.46 to 2.28")
    }

    func testTheBackingIsDarkEnoughToReadAndStillLetsTheMapShowThrough() {
        XCTAssertGreaterThanOrEqual(StatusStripStyle.backingOpacity, 0.6)
        XCTAssertLessThanOrEqual(StatusStripStyle.backingOpacity, 0.8, "no opaque black bar")
    }
}
