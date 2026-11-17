//
//  MapScale.swift
//  OmniTAKMobile
//
//  The maths behind the bottom-left scale bar, kept free of any map view so it
//  can be tested on its own.
//
//  The old readout rounded the visible width UP to 1/2/5/10 x 10^n and printed
//  that number next to a box whose size had nothing to do with it. Here the
//  distance is rounded DOWN so it fits, and the bar is drawn at exactly the
//  width that distance covers on screen: what the label says is what the line
//  measures.
//

import CoreGraphics
import Foundation

enum MapScale {
    /// A bar that would stand for more than this is hidden. At that zoom the
    /// ground scale changes too much across the screen to mean anything.
    static let longestBarMeters: Double = 2_000_000

    private static let metersPerMile = 1_609.344
    private static let metersPerFoot = 0.3048
    /// Below this a 1/2/5 step cannot be written with one decimal ("0.05 m"
    /// would print as "0.1 m"), so there is no honest label and no bar.
    private static let smallestValue = 0.1

    /// The scale bar for a map that shows `metersPerPoint` metres of ground in
    /// each screen point.
    ///
    /// - Parameters:
    ///   - metersPerPoint: ground metres per screen point at the bar, from the
    ///     active map engine. nil when the engine has no ground under the sample.
    ///   - maxWidth: the longest the bar may be drawn, in points.
    ///   - unitSystem: metres and kilometres, or feet and miles.
    /// - Returns: the bar's width in points (never more than `maxWidth`, and at
    ///   least 40 % of it) and its label, or nil when there is nothing true to show.
    static func bar(metersPerPoint: Double?, maxWidth: CGFloat, unitSystem: UnitSystem) -> (width: CGFloat, label: String)? {
        guard let metersPerPoint, metersPerPoint.isFinite, metersPerPoint > 0, maxWidth > 0 else { return nil }

        let room = metersPerPoint * Double(maxWidth)
        guard room.isFinite else { return nil }

        let unit: (meters: Double, symbol: String)
        switch unitSystem {
        case .metric:
            unit = room >= 1_000 ? (1_000, "km") : (1, "m")
        case .imperial:
            unit = room >= metersPerMile ? (metersPerMile, "mi") : (metersPerFoot, "ft")
        }

        guard let value = largestStep(notOver: room / unit.meters), value >= smallestValue else { return nil }

        let distance = value * unit.meters
        guard distance <= longestBarMeters else { return nil }

        let width = min(CGFloat(distance / metersPerPoint), maxWidth)
        return (width, label(value: value, symbol: unit.symbol))
    }

    /// The largest of 1, 2 or 5 x 10^n that is not over `limit` (> 0).
    private static func largestStep(notOver limit: Double) -> Double? {
        guard limit > 0, limit.isFinite else { return nil }
        var magnitude = pow(10, floor(log10(limit)))
        // log10 can land one power off at the edges; settle it on the real comparison.
        if magnitude * 10 <= limit { magnitude *= 10 }
        if magnitude > limit { magnitude /= 10 }
        let mantissa = limit / magnitude
        let step: Double = mantissa >= 5 ? 5 : (mantissa >= 2 ? 2 : 1)
        return step * magnitude
    }

    /// Whole numbers ("200 m", "5 km"), one decimal under 1 ("0.5 m").
    private static func label(value: Double, symbol: String) -> String {
        let number = value >= 1 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(number) \(symbol)"
    }
}
