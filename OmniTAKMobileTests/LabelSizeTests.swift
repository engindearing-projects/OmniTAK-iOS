//
//  LabelSizeTests.swift
//  OmniTAKMobileTests
//
//  #135 - the "Label size" setting: the choices and what a stored value reads as,
//  the size function, the phone text size scale, the preference round trip, and the
//  geometry of the names under markers and of the position box.
//

import XCTest
import SwiftUI
import UIKit
import CoreLocation
import MapboxMaps
@testable import OmniTAK

// MARK: - The choices, the size function, the phone's text size

final class LabelSizeRuleTests: XCTestCase {

    private let accuracy = 1e-9

    func testTheChoicesAreTheSpecifiedOnesInOrderAndIncludeTheDefault() {
        XCTAssertEqual(LabelSize.choices, [80, 100, 120, 140, 160])
        XCTAssertEqual(LabelSize.defaultPercent, 100)
        XCTAssertTrue(LabelSize.choices.contains(LabelSize.defaultPercent))
    }

    func testTheStoredKeyIsTheSameOneAndroidUses() {
        XCTAssertEqual(LabelSize.storageKey, "label_scale_percent")
    }

    func testEveryChoiceReadsAsItself() {
        for choice in LabelSize.choices {
            XCTAssertEqual(LabelSize.nearestChoice(choice), choice)
        }
    }

    func testAValueBetweenTwoChoicesReadsAsTheNearestOne() {
        let expected: [Int: Int] = [
            81: 80, 89: 80, 91: 100, 99: 100, 101: 100, 109: 100, 111: 120, 119: 120,
            121: 120, 129: 120, 131: 140, 139: 140, 141: 140, 149: 140, 151: 160, 159: 160,
        ]
        for (stored, read) in expected {
            XCTAssertEqual(LabelSize.nearestChoice(stored), read, "\(stored) reads as \(read)")
        }
    }

    func testAValueHalfwayBetweenTwoChoicesRoundsUp() {
        XCTAssertEqual(LabelSize.nearestChoice(90), 100)
        XCTAssertEqual(LabelSize.nearestChoice(110), 120)
        XCTAssertEqual(LabelSize.nearestChoice(130), 140)
        XCTAssertEqual(LabelSize.nearestChoice(150), 160)
    }

    func testZeroNegativeAndHugeValuesReadAsTheEndsNeverAsTinyOrHuge() {
        for stored in [0, -1, -100, Int.min] {
            XCTAssertEqual(LabelSize.nearestChoice(stored), 80, "\(stored) reads as 80")
        }
        for stored in [161, 999, 1000, Int.max] {
            XCTAssertEqual(LabelSize.nearestChoice(stored), 160, "\(stored) reads as 160")
        }
    }

    func testTheScaleIsThePercentOverOneHundredAndAlwaysOfAChoice() {
        XCTAssertEqual(LabelSize.scale(of: 80), 0.8, accuracy: accuracy)
        XCTAssertEqual(LabelSize.scale(of: 100), 1.0, accuracy: accuracy)
        XCTAssertEqual(LabelSize.scale(of: 120), 1.2, accuracy: accuracy)
        XCTAssertEqual(LabelSize.scale(of: 140), 1.4, accuracy: accuracy)
        XCTAssertEqual(LabelSize.scale(of: 160), 1.6, accuracy: accuracy)
        XCTAssertEqual(LabelSize.scale(of: 0), 0.8, accuracy: accuracy, "0 is not a zero-size label")
        XCTAssertEqual(LabelSize.scale(of: Int.max), 1.6, accuracy: accuracy)
    }

    func testTheSizeIsTheDesignSizeTimesThePhoneScaleTimesTheLabelSize() {
        XCTAssertEqual(LabelSize.size(designSize: 11, phoneFontScale: 1, percent: 100), 11, accuracy: accuracy)
        XCTAssertEqual(LabelSize.size(designSize: 11, phoneFontScale: 1, percent: 80), 8.8, accuracy: accuracy)
        XCTAssertEqual(LabelSize.size(designSize: 11, phoneFontScale: 1, percent: 160), 17.6, accuracy: accuracy)
        XCTAssertEqual(LabelSize.size(designSize: 11, phoneFontScale: 2, percent: 160), 35.2, accuracy: accuracy)
        XCTAssertEqual(LabelSize.size(designSize: 11, phoneFontScale: 0.5, percent: 100), 5.5, accuracy: accuracy)
        XCTAssertEqual(LabelSize.size(designSize: 10, phoneFontScale: 1.2, percent: 120), 14.4, accuracy: accuracy)
        for design in [10.0, 11.0, 12.0, 13.0] {
            for phone in [0.8, 1.0, 1.3, 2.0] {
                for choice in LabelSize.choices {
                    XCTAssertEqual(LabelSize.size(designSize: design, phoneFontScale: phone, percent: choice),
                                   design * phone * Double(choice) / 100, accuracy: accuracy)
                }
            }
        }
    }

    func testThePhoneTextSizeMultipliesIn() {
        let atDefault = LabelSize.size(designSize: 11, phoneFontScale: 1, percent: 140)
        let larger = LabelSize.size(designSize: 11, phoneFontScale: 1.5, percent: 140)
        XCTAssertEqual(larger / atDefault, 1.5, accuracy: accuracy)
    }

    func testAPhoneScaleThatIsNotUsableCountsAsOne() {
        for bad in [0.0, -1.0, -0.5, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(LabelSize.size(designSize: 11, phoneFontScale: bad, percent: 120), 13.2,
                           accuracy: accuracy, "phone scale \(bad) counts as 1")
        }
    }

    func testTheFactorIsTheSizeOfOne() {
        XCTAssertEqual(LabelSize.factor(phoneFontScale: 1, percent: 100), 1, accuracy: accuracy)
        XCTAssertEqual(LabelSize.factor(phoneFontScale: 1.25, percent: 160), 2.0, accuracy: accuracy)
        XCTAssertEqual(LabelSize.factor(phoneFontScale: 1, percent: 0), 0.8, accuracy: accuracy)
    }

    // MARK: Phone text size

    private let allCategories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]

    func testThePhoneScaleIsOneAtTheDefaultTextSize() {
        XCTAssertEqual(LabelSize.phoneFontScale(for: UIContentSizeCategory.large), 1.0, accuracy: accuracy)
        XCTAssertEqual(LabelSize.phoneFontScale(for: DynamicTypeSize.large), 1.0, accuracy: accuracy)
    }

    func testThePhoneScaleGrowsWithEveryStepOfTheTextSizeUntilTheCap() {
        let scales = allCategories.map { LabelSize.phoneFontScale(for: $0) }
        for (a, b) in zip(scales, scales.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "a larger text size is never a smaller scale: \(scales)")
            XCTAssertTrue(a < b || a == LabelSize.maxPhoneFontScale, "it grows with each step until it reaches the cap: \(scales)")
        }
        XCTAssertLessThan(scales[0], 1, "below the default size is below 1")
        XCTAssertGreaterThan(scales.last ?? 0, 1.5, "the largest size is clearly larger")
    }

    func testThePhoneScaleIsCappedAtWhatAndroidsLargestFontIs() {
        XCTAssertEqual(LabelSize.maxPhoneFontScale, 2.0)
        for category in allCategories {
            XCTAssertLessThanOrEqual(LabelSize.phoneFontScale(for: category), 2.0)
        }
        // The body curve itself goes past 2 at the largest sizes (about 2.8 on the iOS 26.5 runtime
        // this was measured on); the cap is what holds the scale at 2.
        let largest = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        let uncapped = Double(UIFontMetrics.default.scaledValue(
            for: 100, compatibleWith: UITraitCollection(preferredContentSizeCategory: largest))) / 100
        XCTAssertGreaterThan(uncapped, 2.0)
        XCTAssertEqual(LabelSize.phoneFontScale(for: largest), 2.0, accuracy: accuracy)
        // The caption curves climb faster than body; this is the body one.
        let belowCap = LabelSize.phoneFontScale(for: UIContentSizeCategory.accessibilityMedium)
        let body = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: 100, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityMedium))
        XCTAssertEqual(belowCap, Double(body) / 100, accuracy: accuracy)
    }

    func testEverySwiftUITextSizeMapsToItsUIKitCategory() {
        let table: [(DynamicTypeSize, UIContentSizeCategory)] = [
            (.xSmall, .extraSmall), (.small, .small), (.medium, .medium), (.large, .large),
            (.xLarge, .extraLarge), (.xxLarge, .extraExtraLarge), (.xxxLarge, .extraExtraExtraLarge),
            (.accessibility1, .accessibilityMedium), (.accessibility2, .accessibilityLarge),
            (.accessibility3, .accessibilityExtraLarge), (.accessibility4, .accessibilityExtraExtraLarge),
            (.accessibility5, .accessibilityExtraExtraExtraLarge),
        ]
        XCTAssertEqual(table.count, DynamicTypeSize.allCases.count)
        for (swiftUI, uiKit) in table {
            XCTAssertEqual(LabelSize.contentSizeCategory(for: swiftUI), uiKit)
            XCTAssertEqual(LabelSize.phoneFontScale(for: swiftUI), LabelSize.phoneFontScale(for: uiKit), accuracy: accuracy)
        }
    }
}

// MARK: - The preference

final class LabelSizePreferenceTests: XCTestCase {

    private let suite = "LabelSizePreferenceTests"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The setting exactly as Settings and the map hold it: `@AppStorage` under the key.
    private func storage() -> AppStorage<Int> {
        AppStorage(wrappedValue: LabelSize.defaultPercent, LabelSize.storageKey, store: defaults)
    }

    /// What the map reads.
    private func readByTheMap() -> Int {
        LabelSize.nearestChoice(storage().wrappedValue)
    }

    func testNothingStoredReadsAsTheDefault() {
        XCTAssertNil(defaults.object(forKey: LabelSize.storageKey))
        XCTAssertEqual(readByTheMap(), 100)
        XCTAssertEqual(LabelSize.choiceBinding(for: storage().projectedValue).wrappedValue, 100)
    }

    func testEveryChoiceIsStoredAsAWholePercentAndReadBack() {
        for choice in LabelSize.choices {
            let binding = LabelSize.choiceBinding(for: storage().projectedValue)
            binding.wrappedValue = choice
            XCTAssertEqual(defaults.object(forKey: LabelSize.storageKey) as? Int, choice, "stored as the whole percent")
            XCTAssertEqual(readByTheMap(), choice)
            XCTAssertEqual(LabelSize.choiceBinding(for: storage().projectedValue).wrappedValue, choice)
        }
    }

    func testAStoredNumberThatIsNotAChoiceReadsAsTheNearestOne() {
        let expected: [Int: Int] = [0: 80, -40: 80, 79: 80, 90: 100, 113: 120, 150: 160, 161: 160, 100_000: 160]
        for (stored, read) in expected {
            defaults.set(stored, forKey: LabelSize.storageKey)
            XCTAssertEqual(readByTheMap(), read, "stored \(stored) reads as \(read)")
            XCTAssertEqual(LabelSize.choiceBinding(for: storage().projectedValue).wrappedValue, read,
                           "the picker shows \(read), a choice it has")
        }
    }

    func testAStoredValueThatIsNotAnIntReadsTheWayAppStorageReadsAnInt() {
        // The setting is an Int under @AppStorage, which reads other stored types the way
        // UserDefaults.integer(forKey:) does: text that is not a number is 0 (so 80), text
        // that is a number is that number, a fraction is cut. Whatever it reads as then
        // goes through the same nearest-choice rule.
        defaults.set("garbage", forKey: LabelSize.storageKey)
        XCTAssertEqual(readByTheMap(), 80)
        defaults.set("140", forKey: LabelSize.storageKey)
        XCTAssertEqual(readByTheMap(), 140)
        defaults.set(119.6, forKey: LabelSize.storageKey)
        XCTAssertEqual(readByTheMap(), 120, "119 reads as 120")
        defaults.set(Data([1, 2, 3]), forKey: LabelSize.storageKey)
        XCTAssertEqual(readByTheMap(), 80)
        for stored in ["garbage", "140", "0", "-7"] {
            defaults.set(stored, forKey: LabelSize.storageKey)
            XCTAssertTrue(LabelSize.choices.contains(LabelSize.choiceBinding(for: storage().projectedValue).wrappedValue),
                          "the picker always has a choice selected, for stored \(stored)")
        }
    }

    func testThePickerOnlyEverWritesAChoice() {
        let binding = LabelSize.choiceBinding(for: storage().projectedValue)
        binding.wrappedValue = 0
        XCTAssertEqual(defaults.object(forKey: LabelSize.storageKey) as? Int, 80)
        binding.wrappedValue = 5000
        XCTAssertEqual(defaults.object(forKey: LabelSize.storageKey) as? Int, 160)
        binding.wrappedValue = 110
        XCTAssertEqual(defaults.object(forKey: LabelSize.storageKey) as? Int, 120)
    }
}

// MARK: - Label geometry, the contact annotation, the position box, the hit region

final class MapLabelStyleTests: XCTestCase {

    private let accuracy = 1e-9
    private let phoneScales = [0.82, 1.0, 1.12, 1.35, 1.65, 2.0, 2.2]

    private func factors() -> [Double] {
        var all: [Double] = []
        for phone in phoneScales {
            for choice in LabelSize.choices {
                all.append(LabelSize.factor(phoneFontScale: phone, percent: choice))
            }
        }
        return all
    }

    private let designs: [(name: String, make: (Double) -> MapLabelStyle, size: Double, em: Double, halo: Double)] = [
        ("contact", MapLabelStyle.contact(factor:), 11, 1.5, 1.0),
        ("placed marker", MapLabelStyle.placedMarker(factor:), 11, 1.2, 1.0),
        ("aircraft", MapLabelStyle.aircraft(factor:), 10, 1.2, 1.0),
        ("KML pin", MapLabelStyle.kmlPin(factor:), 12, 0.6, 1.2),
    ]

    func testAtTheDefaultSizeEveryNameIsDrawnAsTheAppAlwaysDrewIt() {
        for d in designs {
            let style = d.make(1)
            XCTAssertEqual(style.textSize, d.size, "\(d.name) text size")
            XCTAssertEqual(style.offsetEm, d.em, "\(d.name) offset")
            XCTAssertEqual(style.haloWidth, d.halo, "\(d.name) halo")
        }
    }

    func testTheTextAndTheHaloFollowTheFactor() {
        for d in designs {
            for f in factors() {
                let style = d.make(f)
                XCTAssertEqual(style.textSize, d.size * f, accuracy: accuracy, "\(d.name) at \(f)")
                XCTAssertEqual(style.haloWidth, d.halo * f, accuracy: accuracy, "\(d.name) halo at \(f)")
            }
        }
    }

    func testTheNameStartsTheSameDistanceBelowThePointAtEverySize() {
        for d in designs {
            let designGap = d.size * d.em
            for f in factors() {
                XCTAssertEqual(d.make(f).gapPoints, designGap, accuracy: 1e-9,
                               "\(d.name) at \(f): the gap in points does not move, so a bigger name grows away from the icon, not into it")
            }
        }
    }

    func testAContactNameNeverStartsInsideItsSymbol() {
        // The symbol is a 28 pt frame centred on the point, so its edge is 14 pt below
        // it; its outline adds about 1 pt.
        let edge = Double(ContactMarkerRender.symbolSize) / 2 + 1
        for f in factors() {
            XCTAssertGreaterThan(MapLabelStyle.contact(factor: f).gapPoints, edge, "at factor \(f)")
        }
    }

    func testAFactorThatIsNotUsableDrawsAtTheDefaultSize() {
        for bad in [0.0, -2.0, Double.nan, Double.infinity] {
            XCTAssertEqual(MapLabelStyle.contact(factor: bad), MapLabelStyle.contact(factor: 1), "factor \(bad)")
            XCTAssertEqual(PositionBoxStyle(factor: bad), PositionBoxStyle(factor: 1), "factor \(bad)")
        }
    }

    // MARK: Contact annotation

    private func marker(callsign: String = "BRAVO-2", receivedAt: Date? = nil) -> CoTMarker {
        CoTMarker(uid: "uid-1",
                  coordinate: CLLocationCoordinate2D(latitude: 38.8899, longitude: -77.034),
                  type: "a-f-G-U-C", callsign: callsign, team: "Cyan", receivedAt: receivedAt)
    }

    func testTheContactNameIsDrawnAtTheFactorAndStaysTheSameDistanceFromTheSymbol() throws {
        let m = marker()
        let image = ContactMarkerRender.symbolImage(cotType: m.type)
        let base = ContactMarkerRender.annotation(for: m, image: image)
        for f in factors() {
            let ann = ContactMarkerRender.annotation(for: m, image: image, labelFactor: f)
            let size = try XCTUnwrap(ann.textSize)
            let offsetEm = try XCTUnwrap(ann.textOffset?.last)
            XCTAssertEqual(size, 11 * f, accuracy: accuracy)
            XCTAssertEqual(size * offsetEm, 16.5, accuracy: 1e-9, "the name starts 16.5 pt below the point at every size")
            XCTAssertEqual(ann.textHaloWidth, f, "the halo follows the text")
            XCTAssertEqual(ann.textField, "BRAVO-2")
            XCTAssertEqual(ann.textAnchor, .top)
            // The symbol keeps its size and its place.
            XCTAssertEqual(ann.iconSize, base.iconSize)
            XCTAssertEqual(ann.iconAnchor, base.iconAnchor)
            XCTAssertEqual(ann.image?.image.size, base.image?.image.size)
            XCTAssertEqual(ann.image?.name, base.image?.name)
        }
    }

    func testWithoutAFactorTheContactNameIsExactlyWhatItWas() {
        let m = marker()
        let image = ContactMarkerRender.symbolImage(cotType: m.type)
        let plain = ContactMarkerRender.annotation(for: m, image: image)
        let one = ContactMarkerRender.annotation(for: m, image: image, labelFactor: 1)
        XCTAssertEqual(plain.textSize, ContactMarkerRender.labelTextSize)
        XCTAssertEqual(plain.textOffset, [0, ContactMarkerRender.labelOffsetEm])
        XCTAssertEqual(plain.textHaloWidth, 1.0)
        XCTAssertEqual(plain.textSize, one.textSize)
        XCTAssertEqual(plain.textOffset, one.textOffset)
    }

    func testThePointAgeRidesInTheSameTextFieldSoItScalesWithTheName() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let m = marker(receivedAt: now.addingTimeInterval(-120))
        let image = ContactMarkerRender.symbolImage(cotType: m.type)
        let small = ContactMarkerRender.annotation(for: m, image: image, stalenessOverlay: true, now: now, labelFactor: 0.8)
        let large = ContactMarkerRender.annotation(for: m, image: image, stalenessOverlay: true, now: now, labelFactor: 1.6)
        let age = try XCTUnwrap(CoTAge.shortLabel(receivedAt: m.receivedAt, now: now))
        XCTAssertEqual(small.textField, "BRAVO-2\n\(age)")
        XCTAssertEqual(large.textField, "BRAVO-2\n\(age)", "one text field: the age is a second line, not a second label")
        let smallSize = try XCTUnwrap(small.textSize)
        let largeSize = try XCTUnwrap(large.textSize)
        XCTAssertEqual(largeSize / smallSize, 2.0, accuracy: accuracy)
        // The fade rides along unchanged.
        XCTAssertEqual(small.textOpacity, large.textOpacity)
        XCTAssertEqual(small.iconOpacity, large.iconOpacity)
    }

    func testABlankNameStillHasNoTextAtAnySize() {
        let m = marker(callsign: "   ")
        let image = ContactMarkerRender.symbolImage(cotType: m.type)
        XCTAssertNil(ContactMarkerRender.annotation(for: m, image: image, labelFactor: 1.6).textField)
    }

    // MARK: Dropped marker and aircraft names

    private func blankAnnotation() -> PointAnnotation {
        PointAnnotation(id: "t", coordinate: CLLocationCoordinate2D(latitude: 38.9, longitude: -77.0))
    }

    func testADroppedMarkersNameAtTheDefaultSizeIsWhatItAlwaysWas() {
        var ann = blankAnnotation()
        MapLabelRender.applyPlacedMarkerName("Rally Point", to: &ann, labelFactor: 1)
        XCTAssertEqual(ann.textField, "Rally Point")
        XCTAssertEqual(ann.textAnchor, .top)
        XCTAssertEqual(ann.textOffset, [0, 1.2])
        XCTAssertEqual(ann.textColor, StyleColor(.white))
        XCTAssertEqual(ann.textHaloColor, StyleColor(.black))
        XCTAssertEqual(ann.textHaloWidth, 1.0)
        XCTAssertEqual(ann.textSize, 11)
    }

    func testADroppedMarkersNameFollowsTheFactorAndStaysTheSameDistanceFromItsIcon() throws {
        for f in factors() {
            var ann = blankAnnotation()
            MapLabelRender.applyPlacedMarkerName("Rally Point", to: &ann, labelFactor: f)
            let size = try XCTUnwrap(ann.textSize)
            let em = try XCTUnwrap(ann.textOffset?.last)
            XCTAssertEqual(size, 11 * f, accuracy: accuracy, "factor \(f)")
            XCTAssertEqual(size * em, 13.2, accuracy: 1e-9, "13.2 pt below the point at every size")
            XCTAssertEqual(ann.textHaloWidth, f)
            XCTAssertEqual(ann.textField, "Rally Point")
        }
    }

    func testAnAircraftCallsignAtTheDefaultSizeIsWhatItAlwaysWas() {
        var ann = blankAnnotation()
        MapLabelRender.applyAircraftCallsign("N123AB", to: &ann, labelFactor: 1)
        XCTAssertEqual(ann.textField, "N123AB")
        XCTAssertEqual(ann.textAnchor, .top)
        XCTAssertEqual(ann.textOffset, [0, 1.2])
        XCTAssertEqual(ann.textColor, StyleColor(.systemBlue))
        XCTAssertEqual(ann.textHaloColor, StyleColor(.black))
        XCTAssertEqual(ann.textHaloWidth, 1)
        XCTAssertEqual(ann.textSize, 10)
    }

    func testAnAircraftCallsignFollowsTheFactorAndStaysTheSameDistanceFromItsIcon() throws {
        for f in factors() {
            var ann = blankAnnotation()
            MapLabelRender.applyAircraftCallsign("N123AB", to: &ann, labelFactor: f)
            let size = try XCTUnwrap(ann.textSize)
            let em = try XCTUnwrap(ann.textOffset?.last)
            XCTAssertEqual(size, 10 * f, accuracy: accuracy, "factor \(f)")
            XCTAssertEqual(size * em, 12, accuracy: 1e-9, "12 pt below the point at every size")
            XCTAssertEqual(ann.textHaloWidth, f)
        }
    }

    // MARK: Position box

    func testThePositionBoxIsDrawnAtItsOwnSizesAtTheDefault() {
        let style = PositionBoxStyle(factor: 1)
        XCTAssertEqual(style.callsign, 13)
        XCTAssertEqual(style.coordinates, 12)
        XCTAssertEqual(style.detail, 11)
    }

    func testEveryLineOfThePositionBoxFollowsTheFactor() {
        for f in factors() {
            let style = PositionBoxStyle(factor: f)
            XCTAssertEqual(style.callsign, 13 * f, accuracy: accuracy)
            XCTAssertEqual(style.coordinates, 12 * f, accuracy: accuracy)
            XCTAssertEqual(style.detail, 11 * f, accuracy: accuracy)
        }
        let at160 = PositionBoxStyle(factor: 1.6)
        XCTAssertEqual(at160.callsign, 20.8, accuracy: accuracy)
        XCTAssertEqual(at160.coordinates, 19.2, accuracy: accuracy)
        XCTAssertEqual(at160.detail, 17.6, accuracy: accuracy)
    }

    func testThePositionBoxStopsShortOfTheMapButtonsOnTheLeft() {
        // 393 pt wide phone: 16 from the right edge, 90 reserved on the left.
        XCTAssertEqual(PositionBoxStyle.maxWidth(screenWidth: 393,
                                                 leadingReserved: PositionBoxStyle.leadingReserved,
                                                 trailing: PositionBoxStyle.trailingPadding), 287)
        XCTAssertEqual(PositionBoxStyle.maxWidth(screenWidth: 852,
                                                 leadingReserved: PositionBoxStyle.leadingReserved,
                                                 trailing: PositionBoxStyle.trailingPadding), 746)
        // The scale bar chip (82 pt) and the buttons (56 pt) are both left of where the box may start.
        XCTAssertGreaterThan(PositionBoxStyle.leadingReserved, 82)
    }

    func testThePositionBoxIsNeverNarrowerThanItsFloor() {
        XCTAssertEqual(PositionBoxStyle.maxWidth(screenWidth: 200, leadingReserved: 64, trailing: 16), 160)
        XCTAssertEqual(PositionBoxStyle.maxWidth(screenWidth: 0, leadingReserved: 64, trailing: 16), 160)
        XCTAssertEqual(PositionBoxStyle.maxWidth(screenWidth: 100, leadingReserved: 64, trailing: 16, minimum: 120), 120)
    }

    // MARK: Hit region of a placed marker's name

    func testTheNameRegionOfAPlacedMarkerIsTheOldOneAtTheDefaultSize() {
        let p = CGPoint(x: 100, y: 200)
        // Short name: the 40 pt minimum width; the region reaches 8 pt out and 6 pt up and down.
        XCTAssertEqual(PlacedMarkerLabelHit.rect(markerPoint: p, nameLength: 5, factor: 1),
                       CGRect(x: 72, y: 202, width: 56, height: 32))
        // Long name: the 180 pt cap.
        XCTAssertEqual(PlacedMarkerLabelHit.rect(markerPoint: p, nameLength: 40, factor: 1),
                       CGRect(x: 2, y: 202, width: 196, height: 32))
        // In between: 7 pt a character.
        XCTAssertEqual(PlacedMarkerLabelHit.rect(markerPoint: p, nameLength: 10, factor: 1),
                       CGRect(x: 100 - 35 - 8, y: 202, width: 70 + 16, height: 32))
    }

    func testTheNameRegionGrowsWithTheNameAndStartsInTheSamePlace() {
        let p = CGPoint(x: 100, y: 200)
        let base = PlacedMarkerLabelHit.rect(markerPoint: p, nameLength: 10, factor: 1)
        for f in factors() where f > 1 {
            let grown = PlacedMarkerLabelHit.rect(markerPoint: p, nameLength: 10, factor: f)
            XCTAssertEqual(grown.minY, base.minY, accuracy: 1e-9, "the name starts the same distance below the icon")
            XCTAssertGreaterThan(grown.maxY, base.maxY, "factor \(f): reaches down to the bigger name")
            XCTAssertGreaterThan(grown.width, base.width)
            XCTAssertEqual(grown.midX, base.midX, accuracy: 1e-9)
        }
    }

    func testTheNameRegionContainsTheWholeDrawnNameAtEverySize() {
        let p = CGPoint(x: 100, y: 200)
        for f in factors() {
            let style = MapLabelStyle.placedMarker(factor: f)
            // A name of 10 characters, about 0.55 em a character, one line of 1.2 em.
            let nameWidth = 10 * 0.55 * style.textSize
            let nameRect = CGRect(x: p.x - nameWidth / 2, y: p.y + style.gapPoints,
                                  width: nameWidth, height: style.textSize * 1.2)
            let region = PlacedMarkerLabelHit.rect(markerPoint: p, nameLength: 10, factor: f)
            XCTAssertTrue(region.contains(nameRect), "factor \(f): \(nameRect) is inside \(region)")
        }
    }
}
