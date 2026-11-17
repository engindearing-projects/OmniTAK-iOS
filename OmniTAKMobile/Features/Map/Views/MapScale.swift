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
//  Where the scale is taken matters as much as the rounding. The bar sits in the
//  bottom-left corner, and on a tilted view the ground there is nearer the camera
//  than the ground at the middle of the screen, so a scale taken at the middle
//  makes the bar read long for the ground it lies on (16 % long on the globe at
//  its default tilt, 27 % on the 2D map). The scale is therefore measured on the
//  bar's own row: the ground distance between the two screen points 50 pt either
//  side of the scale anchor, divided by the real distance between those points.
//  The anchor is the middle of the bar's maximum width, on the bar line's row,
//  and comes from the bar's own frame (see `ScaleBarView`). A line measured
//  across the middle of a tilted screen therefore does NOT match the bar, by
//  design: do not move the sample back to the center.
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

// MARK: - Where the bar is measured

extension MapScale {
    /// Half the baseline the ground scale is measured over, in points (CSS px on the globe).
    static let sampleHalfSpan: CGFloat = 50

    /// The two screen points the ground scale is measured between, on one row.
    struct Sample: Equatable {
        let left: CGPoint
        let right: CGPoint
        /// How far apart they really are, in points. The ground distance is divided
        /// by this, not by 100: near an edge the points are pulled onto the map and
        /// the baseline gets shorter.
        var span: CGFloat { right.x - left.x }
    }

    /// The two points to measure between: `sampleHalfSpan` either side of the scale
    /// anchor, on the anchor's row, both kept on the map.
    ///
    /// - Parameters:
    ///   - anchor: the scale anchor in the map view's own coordinate space, or nil
    ///     until the bar has been laid out, which measures at the middle of the map.
    ///   - mapSize: the map view's size in points.
    /// - Returns: nil when the map has no size yet or the anchor is not a number.
    static func sample(anchor: CGPoint?, mapSize: CGSize) -> Sample? {
        guard mapSize.width > 0, mapSize.height > 0,
              mapSize.width.isFinite, mapSize.height.isFinite else { return nil }
        let point = anchor ?? CGPoint(x: mapSize.width / 2, y: mapSize.height / 2)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let x = min(max(point.x, 0), mapSize.width)
        let y = min(max(point.y, 0), mapSize.height)
        let left = max(x - sampleHalfSpan, 0)
        let right = min(x + sampleHalfSpan, mapSize.width)
        guard right > left else { return nil }
        return Sample(left: CGPoint(x: left, y: y), right: CGPoint(x: right, y: y))
    }

    /// Ground metres per screen point from the ground distance between a sample's
    /// two points. nil when there is no honest distance.
    static func metersPerPoint(groundDistance: Double?, over sample: Sample) -> Double? {
        guard let groundDistance, groundDistance.isFinite, groundDistance > 0, sample.span > 0 else { return nil }
        return groundDistance / Double(sample.span)
    }

    /// The scale at the bar for an engine that can measure ground distance between
    /// two screen points.
    ///
    /// - Parameters:
    ///   - anchor: the scale anchor, nil until the bar's place is known.
    ///   - mapSize: the map view's size in points.
    ///   - fallback: the scale to use until an anchor is known (the 2D map's tile
    ///     formula at the camera center).
    ///   - groundDistance: metres of ground between two screen points of the map,
    ///     nil unless both are on the ground (not above the horizon, not off the globe).
    /// - Returns: nil (no bar) when a point is not on the ground. Once an anchor
    ///   is known the fallback is never used: a bar measured somewhere else is the
    ///   very error this exists to remove.
    static func metersPerPoint(anchor: CGPoint?,
                               mapSize: CGSize,
                               fallback: () -> Double?,
                               groundDistance: (CGPoint, CGPoint) -> Double?) -> Double? {
        guard let anchor else { return fallback() }
        guard let sample = sample(anchor: anchor, mapSize: mapSize) else { return nil }
        return metersPerPoint(groundDistance: groundDistance(sample.left, sample.right), over: sample)
    }

    /// The scale anchor, in the map's coordinate space, from the frames of the bar's
    /// row and of the map, both measured in one common space.
    ///
    /// - Parameters:
    ///   - barRow: the row the bar line is drawn in, as wide as the longest bar, so
    ///     the anchor does not move when the bar gets shorter or longer.
    ///   - map: the map view's frame.
    ///   - baselineInset: how far above the bottom of the row the bar line is drawn.
    static func anchor(barRow: CGRect, in map: CGRect, baselineInset: CGFloat) -> CGPoint {
        CGPoint(x: barRow.midX - map.minX, y: barRow.maxY - baselineInset - map.minY)
    }
}
