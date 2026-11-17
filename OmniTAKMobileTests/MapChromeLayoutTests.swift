//
//  MapChromeLayoutTests.swift
//  OmniTAKMobileTests
//
//  The map's floating controls used to be placed with numbers tuned for the bottom bar alone: the
//  centre-on-me button sat partly under the bar, the first-run tip lay on the position box, and on a
//  phone held on its side the scale bar, the zoom buttons and the centre-on-me button were stacked
//  on each other. These pin the layout for every screen that matters: nothing overlaps anything.
//

import XCTest
import CoreGraphics
@testable import OmniTAK

final class MapChromeLayoutTests: XCTestCase {

    /// A screen to lay out: its size, its bottom safe area, and the bottom bar's frame.
    private struct Screen {
        var name: String
        var window: CGSize
        var safeBottom: CGFloat
        /// The side safe areas (a phone held on its side has about 60 pt each).
        var safeSide: CGFloat = 0
        /// The bar pill's size. In portrait it spans the window (14 pt in from each side).
        var pill: CGSize
        /// The first-run tip's height and the gap under it (0 when it is not shown).
        var tip: CGFloat = 0

        /// The bar with its tip, in window coordinates, bottom-centred, 4 pt above the safe area
        /// (the padding under it is not part of what is measured).
        var bar: CGRect {
            let height = pill.height + (tip > 0 ? tip + 8 : 0)
            return CGRect(x: (window.width - pill.width) / 2, y: window.height - safeBottom - 4 - height,
                          width: pill.width, height: height)
        }
    }

    private let iPhone17 = Screen(name: "iPhone 17 portrait", window: CGSize(width: 402, height: 874), safeBottom: 34,
                                  pill: CGSize(width: 402 - 28, height: 62))
    // the landscape pill is content-sized: about 230 pt wide (measured on a phone, from a screenshot)
    private let iPhone17Landscape = Screen(name: "iPhone 17 landscape", window: CGSize(width: 874, height: 402), safeBottom: 21,
                                           safeSide: 62, pill: CGSize(width: 230, height: 62))
    private let iPhoneSE = Screen(name: "iPhone SE (3rd generation) portrait", window: CGSize(width: 375, height: 667), safeBottom: 0,
                                  pill: CGSize(width: 375 - 28, height: 62))
    private let iPhoneSELandscape = Screen(name: "iPhone SE (3rd generation) landscape", window: CGSize(width: 667, height: 375), safeBottom: 0,
                                           pill: CGSize(width: 230, height: 62))
    private let smallestPhone = Screen(name: "320 pt wide portrait", window: CGSize(width: 320, height: 568), safeBottom: 0,
                                       pill: CGSize(width: 320 - 28, height: 62))
    private let iPadPortrait = Screen(name: "iPad portrait", window: CGSize(width: 834, height: 1194), safeBottom: 20,
                                      pill: CGSize(width: 834 - 28, height: 62))
    private let iPadLandscape = Screen(name: "iPad landscape", window: CGSize(width: 1194, height: 834), safeBottom: 20,
                                       pill: CGSize(width: 1194 - 28, height: 62))

    private var screens: [Screen] {
        [iPhone17, iPhone17Landscape, iPhoneSE, iPhoneSELandscape, smallestPhone, iPadPortrait, iPadLandscape]
    }

    /// Every drawn thing as a rect, in window coordinates (y down), for one placement.
    private func rects(_ p: MapChromeLayout.Placement, on s: Screen, cardHeight: CGFloat = 110) -> [(String, CGRect)] {
        func rect(_ x: CGFloat, bottom: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x, y: s.window.height - bottom - h, width: w, height: h)
        }
        var all: [(String, CGRect)] = [
            ("bar", s.bar),
            ("centre on me", rect(s.safeSide + 12, bottom: p.locateBottom, 44, MapChromeLayout.locateButton)),
            ("zoom buttons", rect(s.safeSide + 20, bottom: p.zoomBlockBottom + MapChromeLayout.zoomBlockPadding, 32, MapChromeLayout.zoomButtons)),
            ("scale bar", rect(s.safeSide + 16, bottom: p.scaleBarBottom, 116, MapChromeLayout.scaleBar)),
            ("position box", rect(s.window.width - s.safeSide - MapChromeLayout.rightMargin - cardWidth(s), bottom: p.cardBottom,
                                  cardWidth(s), cardHeight)),
        ]
        if let logo = p.logoBottom { all.append(("logo", rect(s.safeSide + 8, bottom: logo, 90, 24))) }
        if let attribution = p.attributionBottom {
            all.append(("attribution", rect(s.window.width - s.safeSide - 8 - 28, bottom: attribution, 28, 28)))
        }
        return all
    }

    private func cardWidth(_ s: Screen) -> CGFloat {
        MapChromeLayout.cardWidth(availableWidth: s.window.width - 2 * s.safeSide)
    }

    private func place(_ s: Screen, ornaments: Bool) -> MapChromeLayout.Placement {
        MapChromeLayout.placement(bar: s.bar, window: s.window, safeBottom: s.safeBottom,
                                  safeLeft: s.safeSide, safeRight: s.safeSide, ornaments: ornaments)
    }

    private func assertNothingOverlaps(_ p: MapChromeLayout.Placement, on s: Screen, file: StaticString = #filePath, line: UInt = #line) {
        let all = rects(p, on: s)
        for i in all.indices {
            for j in all.indices where j > i {
                XCTAssertFalse(all[i].1.intersects(all[j].1),
                               "\(s.name), tip \(s.tip > 0): \(all[i].0) \(all[i].1) overlaps \(all[j].0) \(all[j].1)",
                               file: file, line: line)
            }
        }
    }

    // MARK: - Nothing overlaps anything

    func testNothingOverlapsAnythingOnAnyScreenWithOrWithoutTheTipOnEitherEngine() {
        for screen in screens {
            for tip in [CGFloat(0), 34] {
                for ornaments in [false, true] {
                    var s = screen
                    s.tip = tip
                    assertNothingOverlaps(place(s, ornaments: ornaments), on: s)
                }
            }
        }
    }

    func testTheCentreOnMeButtonIsClearOfTheBarInPortrait() {
        // it used to sit 10 pt under the bar's top edge
        let p = MapChromeLayout.placement(bar: iPhone17.bar, window: iPhone17.window, safeBottom: 34, ornaments: false)
        let barTop = iPhone17.window.height - iPhone17.bar.minY
        XCTAssertGreaterThanOrEqual(p.locateBottom, barTop + MapChromeLayout.gap)
        XCTAssertGreaterThanOrEqual(p.cardBottom, barTop + MapChromeLayout.gap)
    }

    func testThePositionBoxStopsShortOfTheLeftColumnAndNeverStretchesAcrossALandscapeScreen() {
        XCTAssertEqual(MapChromeLayout.cardWidth(availableWidth: 402), 246)   // 402 - 132 - 8 - 16
        XCTAssertEqual(MapChromeLayout.cardWidth(availableWidth: 750), 300)   // capped: it was 746 wide
        XCTAssertEqual(MapChromeLayout.cardWidth(availableWidth: 320), 164)
        XCTAssertEqual(MapChromeLayout.cardWidth(availableWidth: 200), 160, "never narrower than the readable minimum")
    }

    func testOnAPhoneHeldOnItsSideThePositionBoxClearsTheBarThatItsSafeAreaPutsItOver() {
        // seen in a screenshot: the box (496 to 796 pt) was put at the corner because it was thought to
        // start at 558, past the 329 to 553 pill. The side safe area moves it in by 62 pt, over the pill.
        let s = iPhone17Landscape
        let p = place(s, ornaments: false)
        let barTop = s.window.height - s.bar.minY
        XCTAssertGreaterThanOrEqual(p.cardBottom, barTop + MapChromeLayout.gap)
        let box = rects(p, on: s).first { $0.0 == "position box" }!.1
        XCTAssertEqual(box.minX, 496, accuracy: 1e-9)
        XCTAssertFalse(box.intersects(s.bar))
    }

    func testTheTipMovesEverythingItWouldCoverUpByItsOwnHeight() {
        var withTip = iPhone17
        withTip.tip = 34
        let without = MapChromeLayout.placement(bar: iPhone17.bar, window: iPhone17.window, safeBottom: 34, ornaments: false)
        let with = MapChromeLayout.placement(bar: withTip.bar, window: withTip.window, safeBottom: 34, ornaments: false)
        let moved = withTip.bar.height - iPhone17.bar.height
        XCTAssertEqual(with.locateBottom - without.locateBottom, moved, accuracy: 1e-9)
        XCTAssertEqual(with.zoomBlockBottom - without.zoomBlockBottom, moved, accuracy: 1e-9)
        XCTAssertEqual(with.scaleBarBottom - without.scaleBarBottom, moved, accuracy: 1e-9)
        XCTAssertEqual(with.cardBottom - without.cardBottom, moved, accuracy: 1e-9)
    }

    // MARK: - The stack

    func testTheLeftColumnIsStackedWithOneGapBetweenEachControl() {
        for screen in screens {
            let p = place(screen, ornaments: false)
            let zoomButtonsBottom = p.zoomBlockBottom + MapChromeLayout.zoomBlockPadding
            XCTAssertEqual(zoomButtonsBottom - (p.locateBottom + MapChromeLayout.locateButton), MapChromeLayout.gap, accuracy: 1e-9, screen.name)
            XCTAssertEqual(p.scaleBarBottom - (zoomButtonsBottom + MapChromeLayout.zoomButtons), MapChromeLayout.gap, accuracy: 1e-9, screen.name)
        }
    }

    func testThe2DMapsLogoAndAttributionGetARowOfTheirOwnUnderTheControls() {
        let flat = MapChromeLayout.placement(bar: iPhone17.bar, window: iPhone17.window, safeBottom: 34, ornaments: false)
        let map = MapChromeLayout.placement(bar: iPhone17.bar, window: iPhone17.window, safeBottom: 34, ornaments: true)
        XCTAssertNil(flat.logoBottom)
        XCTAssertNil(flat.attributionBottom)
        let row = MapChromeLayout.ornamentRow + MapChromeLayout.gap
        XCTAssertEqual(map.locateBottom - flat.locateBottom, row, accuracy: 1e-9)
        XCTAssertEqual(map.cardBottom - flat.cardBottom, row, accuracy: 1e-9)
        // the logo and the attribution sit where the controls would have started: on the bar's top edge, with a gap
        XCTAssertEqual(try XCTUnwrap(map.logoBottom), flat.locateBottom, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(map.attributionBottom), flat.cardBottom, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(map.logoBottom), iPhone17.window.height - iPhone17.bar.minY)
    }

    // MARK: - A phone held on its side

    func testOnAPhoneHeldOnItsSideTheBarsMeasuredTipDoesNotLiftTheCornerControls() {
        // the bar is a pill in the middle and the left corner is free, so the tip (above the pill)
        // must not push the scale bar towards the aircraft pill at the top
        var tipped = iPhone17Landscape
        tipped.tip = 34
        let a = place(iPhone17Landscape, ornaments: false)
        let b = place(tipped, ornaments: false)
        XCTAssertEqual(a.locateBottom, b.locateBottom)
        XCTAssertEqual(a.scaleBarBottom, b.scaleBarBottom)
    }

    func testOnAPhoneHeldOnItsSideTheColumnStaysBelowTheTopOfTheScreen() {
        // the status strip and the aircraft pill take the top 120 pt
        for screen in [iPhone17Landscape, iPhoneSELandscape] {
            for tip in [CGFloat(0), 34] {
                var s = screen
                s.tip = tip
                let p = place(s, ornaments: true)
                let columnTop = s.window.height - (p.scaleBarBottom + MapChromeLayout.scaleBar)
                XCTAssertGreaterThanOrEqual(columnTop, 120, "\(s.name), tip \(tip)")
            }
        }
    }

    func testTheZoomAndLocateButtonsNoLongerSitOnEachOther() {
        // landscape before: zoom block bottom 64, locate 56, scale bar 110
        let p = place(iPhone17Landscape, ornaments: false)
        XCTAssertGreaterThan(p.zoomBlockBottom + MapChromeLayout.zoomBlockPadding, p.locateBottom + MapChromeLayout.locateButton)
        XCTAssertGreaterThan(p.scaleBarBottom, p.zoomBlockBottom + MapChromeLayout.zoomBlockPadding + MapChromeLayout.zoomButtons)
    }

    // MARK: - Before the bar is measured

    func testBeforeTheBarIsMeasuredTheControlsAssumeAPortraitPhonesBar() {
        let p = MapChromeLayout.placement(bar: nil, window: iPhone17.window, safeBottom: 34, ornaments: false)
        XCTAssertEqual(p.locateBottom, MapChromeLayout.unmeasuredBarClearance + MapChromeLayout.gap)
        XCTAssertEqual(MapChromeLayout.barClearance(bar: nil, window: iPhone17.window), MapChromeLayout.unmeasuredBarClearance)
    }

    func testABarFrameBelowTheWindowGivesNoNegativeClearance() {
        let below = CGRect(x: 0, y: 900, width: 402, height: 60)
        XCTAssertEqual(MapChromeLayout.barClearance(bar: below, window: CGSize(width: 402, height: 874)), 0)
    }
}
