//
//  LabelSize.swift
//  OmniTAKMobile
//
//  #135 - the "Label size" setting: how big the names under map markers and the
//  position box are drawn, as a whole percent of the size the app has always used,
//  on top of the phone's own text size.
//
//  Everything here is a pure rule (no map, no view state) so it can be unit tested:
//  the choices and what a stored value reads as, the size function, the phone text
//  size scale, the label geometry that follows one factor, and the hit region of a
//  placed marker's name.
//

import Foundation
import SwiftUI
import UIKit
import MapboxMaps

enum LabelSize {

    // MARK: - The setting

    /// The choices Settings offers, smallest first.
    static let choices: [Int] = [80, 100, 120, 140, 160]

    /// The size the app has always drawn. A fresh install and a missing stored value
    /// use it, so an upgrade changes nothing until the operator picks another size.
    static let defaultPercent = 100

    /// UserDefaults key. A whole percent, the same key and values as Android's
    /// `label_scale_percent`.
    static let storageKey = "label_scale_percent"

    /// The choice nearest to `percent`. A stored number that is not one of the
    /// choices (a hand edit, a bad import) reads as the closest one, so 0 or a
    /// negative number reads as 80 and 999 reads as 160: never unreadably small or
    /// huge. A value exactly halfway between two choices rounds up (90 reads as 100).
    static func nearestChoice(_ percent: Int) -> Int {
        guard let smallest = choices.first, let largest = choices.last else { return defaultPercent }
        // Checked first so the distance below can never overflow on Int.min / Int.max.
        if percent <= smallest { return smallest }
        if percent >= largest { return largest }
        return choices.min { a, b in
            let da = abs(a - percent), db = abs(b - percent)
            return da != db ? da < db : a > b
        } ?? defaultPercent
    }

    /// The Settings picker's binding to the stored percent (`@AppStorage` under
    /// `storageKey`). It always reads as one of the choices, so the picker never shows
    /// "nothing selected" for a stored value that is not one, and it only ever writes a
    /// choice. A stored value that is not an Int reads the way `@AppStorage` reads an
    /// Int first (text that is not a number is 0, a fraction is cut), then this applies:
    /// so such a value reads as 80 or as the nearest choice, never as the default.
    static func choiceBinding(for stored: Binding<Int>) -> Binding<Int> {
        Binding(get: { nearestChoice(stored.wrappedValue) },
                set: { stored.wrappedValue = nearestChoice($0) })
    }

    /// The multiplier for `percent`: 1.0 at 100.
    static func scale(of percent: Int) -> Double {
        Double(nearestChoice(percent)) / 100
    }

    // MARK: - Size

    /// The size to draw a label at: the design size x the phone's text size scale x
    /// the label size. `phoneFontScale` is 1 at the phone's default text size; a value
    /// that is not positive and finite counts as 1.
    static func size(designSize: Double, phoneFontScale: Double, percent: Int) -> Double {
        designSize * usable(phoneFontScale) * scale(of: percent)
    }

    /// `size` for a design size of 1: the one multiplier every dimension of a label
    /// follows.
    static func factor(phoneFontScale: Double, percent: Int) -> Double {
        size(designSize: 1, phoneFontScale: phoneFontScale, percent: percent)
    }

    /// A multiplier that cannot make a label vanish or blow up: anything that is not
    /// positive and finite counts as 1.
    static func usable(_ scale: Double) -> Double {
        scale > 0 && scale.isFinite ? scale : 1
    }

    // MARK: - The phone's text size

    /// The curve the phone's text size is read from: the one body text follows
    /// (`UIFontMetrics.default`). Measured on iOS 26.5: 1.0 at the default size,
    /// 0.86 at the smallest and 2.8 at the largest accessibility size. The caption
    /// styles climb faster (3.2 to 3.7 at the largest); Android's largest is 2.0.
    private static let metrics = UIFontMetrics.default

    /// The most the phone's text size counts for, as a multiplier. Android's largest
    /// font setting is 2.0. On iOS the body curve goes on to 2.8 at the largest
    /// accessibility size, where a position box at 160% would fill half the screen.
    static let maxPhoneFontScale = 2.0

    /// How much the phone's text size setting scales a small label: 1.0 at the default
    /// size ("Large"), below 1 for the smaller sizes, above 1 for the larger ones, and
    /// never above `maxPhoneFontScale`.
    static func phoneFontScale(for category: UIContentSizeCategory) -> Double {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let scaled = Double(metrics.scaledValue(for: 100, compatibleWith: traits)) / 100
        return min(usable(scaled), maxPhoneFontScale)
    }

    /// `phoneFontScale(for:)` from the size SwiftUI reports in the environment.
    static func phoneFontScale(for size: DynamicTypeSize) -> Double {
        phoneFontScale(for: contentSizeCategory(for: size))
    }

    /// The UIKit name of a SwiftUI Dynamic Type size.
    static func contentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

// MARK: - Label geometry

/// How one kind of map label is drawn at a given factor (the phone's text size x the
/// Label size). Mapbox lays the text out from three numbers: its size in points, its
/// offset from the marker's coordinate in ems, and the width of the dark halo.
///
/// The text size and the halo follow the factor. The offset is held at the same
/// number of POINTS at every size, so it is divided by the factor: a bigger name
/// grows downward from the same place and never reaches the icon, and a smaller one
/// does not sink into it. At a factor of 1 every number is exactly the one the app
/// drew before the setting existed.
struct MapLabelStyle: Equatable {
    /// Mapbox text size, in points.
    let textSize: Double
    /// Mapbox text offset (down), in ems of `textSize`.
    let offsetEm: Double
    /// Mapbox halo width, in points.
    let haloWidth: Double

    init(designTextSize: Double, designOffsetEm: Double, designHaloWidth: Double, factor: Double) {
        let f = LabelSize.usable(factor)
        textSize = designTextSize * f
        offsetEm = designOffsetEm / f
        haloWidth = designHaloWidth * f
    }

    /// Distance from the marker's coordinate to the top of the name, in points.
    /// The same at every factor.
    var gapPoints: Double { textSize * offsetEm }

    /// A contact's name (and the age under it): 11 pt, top 16.5 pt below the point.
    static func contact(factor: Double) -> MapLabelStyle {
        MapLabelStyle(designTextSize: ContactMarkerRender.labelTextSize,
                      designOffsetEm: ContactMarkerRender.labelOffsetEm,
                      designHaloWidth: 1.0, factor: factor)
    }

    /// The name of a marker the operator dropped: 11 pt, top 13.2 pt below the point.
    static func placedMarker(factor: Double) -> MapLabelStyle {
        MapLabelStyle(designTextSize: 11, designOffsetEm: 1.2, designHaloWidth: 1.0, factor: factor)
    }

    /// An ADS-B aircraft's callsign: 10 pt, top 12 pt below the point.
    static func aircraft(factor: Double) -> MapLabelStyle {
        MapLabelStyle(designTextSize: 10, designOffsetEm: 1.2, designHaloWidth: 1.0, factor: factor)
    }

    /// The name under an imported KML pushpin: 12 pt, top 7.2 pt below the pin's tip.
    static func kmlPin(factor: Double) -> MapLabelStyle {
        MapLabelStyle(designTextSize: 12, designOffsetEm: 0.6, designHaloWidth: 1.2, factor: factor)
    }
}

// MARK: - Names on dropped markers and aircraft

/// The Mapbox text fields of the names under a dropped marker and under an ADS-B
/// aircraft, as annotation assembly pulled out of the map coordinator so it can be
/// unit tested (the contact's own is `ContactMarkerRender.applyLabel`).
enum MapLabelRender {

    /// A marker the operator dropped: white name with a dark halo, anchored under the
    /// icon. `labelFactor` is the phone's text size x the Label size.
    static func applyPlacedMarkerName(_ name: String,
                                      to annotation: inout PointAnnotation,
                                      labelFactor: Double) {
        let style = MapLabelStyle.placedMarker(factor: labelFactor)
        annotation.textField = name
        annotation.textAnchor = .top
        annotation.textOffset = [0, style.offsetEm]
        annotation.textColor = StyleColor(.white)
        annotation.textHaloColor = StyleColor(.black)
        annotation.textHaloWidth = style.haloWidth
        annotation.textSize = style.textSize
    }

    /// An ADS-B aircraft: blue callsign with a dark halo, anchored under the icon.
    static func applyAircraftCallsign(_ text: String,
                                      to annotation: inout PointAnnotation,
                                      labelFactor: Double) {
        let style = MapLabelStyle.aircraft(factor: labelFactor)
        annotation.textField = text
        annotation.textAnchor = .top
        annotation.textOffset = [0, style.offsetEm]
        annotation.textColor = StyleColor(.systemBlue)
        annotation.textHaloColor = StyleColor(.black)
        annotation.textHaloWidth = style.haloWidth
        annotation.textSize = style.textSize
    }
}

// MARK: - Position box

/// The text sizes of the position box (callsign, coordinates, altitude, speed,
/// accuracy) at a given factor, and how wide it may grow.
struct PositionBoxStyle: Equatable {
    let callsign: Double
    let coordinates: Double
    let detail: Double

    init(factor: Double) {
        let f = LabelSize.usable(factor)
        callsign = Self.designCallsign * f
        coordinates = Self.designCoordinates * f
        detail = Self.designDetail * f
    }

    static let designCallsign = 13.0
    static let designCoordinates = 12.0
    static let designDetail = 11.0

    /// Where the box may start, measured from the left edge: the scale bar chip above
    /// the zoom and locate buttons ends about 82 pt in (the buttons themselves end at
    /// 56 pt), plus an 8 pt gap. Before #135 the box stretched across almost the whole
    /// width and sat on top of those buttons.
    static let leadingReserved = 90.0
    /// The box's own distance from the right edge.
    static let trailingPadding = 16.0

    /// The widest the box may be on a screen `screenWidth` wide: it stops short of the
    /// map buttons on the left (`leadingReserved`, their right edge plus a gap) and
    /// keeps its own distance from the right edge (`trailing`), so long lines wrap
    /// instead of running under the buttons. Never narrower than `minimum`, so a very
    /// narrow screen still shows something readable.
    static func maxWidth(screenWidth: Double, leadingReserved: Double, trailing: Double,
                         minimum: Double = 160) -> Double {
        max(minimum, screenWidth - leadingReserved - trailing)
    }
}

// MARK: - Placed marker name: hit region

/// The screen region around a dropped marker that counts as the marker: its icon, and
/// its name, so a tap or long press on the floating name reaches the marker too.
///
/// At a factor of 1 this is the rectangle the app has always used. A larger name
/// grows the region along with it: the region starts at the same place (the name
/// starts at the same distance from the icon) and extends further down and sideways.
enum PlacedMarkerLabelHit {
    /// Where the region starts below the marker's point, before the slack is added.
    private static let top = 8.0
    private static let baseHeight = 20.0
    /// A line of the 11 pt name, as the line height Mapbox gives it (1.2 em).
    private static let lineHeight = 11.0 * 1.2
    private static let widthPerCharacter = 7.0
    private static let minWidth = 40.0
    private static let maxWidth = 180.0
    private static let slackX = 8.0
    private static let slackY = 6.0

    static func rect(markerPoint p: CGPoint, nameLength: Int, factor: Double) -> CGRect {
        let f = LabelSize.usable(factor)
        let width = max(minWidth, min(maxWidth * f, Double(nameLength) * widthPerCharacter * f))
        let height = baseHeight + lineHeight * (f - 1)
        return CGRect(x: p.x - CGFloat(width / 2),
                      y: p.y + CGFloat(top),
                      width: CGFloat(width),
                      height: CGFloat(height))
            .insetBy(dx: -CGFloat(slackX), dy: -CGFloat(slackY))
    }
}
