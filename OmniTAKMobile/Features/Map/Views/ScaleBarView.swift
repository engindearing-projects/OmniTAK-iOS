import SwiftUI
import MapKit
import CoreLocation

// MARK: - Scale Bar View
// A line whose on-screen length is exactly the distance printed above it.
// The length comes from the active map engine's real ground scale (metres per
// screen point); the 1/2/5 rounding and the unit live in `MapScale`.

struct ScaleBarView: View {
    /// Ground metres per screen point AT THE BAR, from whichever engine is
    /// showing: the ground distance between the two screen points 50 pt either side
    /// of `onAnchorChange`'s anchor on the bar line's row, over the distance between
    /// them. nil while the engine has no ground to measure there (above the globe's
    /// horizon, space): no bar is drawn then rather than a wrong one.
    /// This is deliberately not the scale at the middle of the screen. On a tilted
    /// map the ground the bar lies on is nearer the camera than the ground at the
    /// centre, so a line measured across the middle of the screen will not match the
    /// bar. Do not move the sample back to the centre.
    let metersPerPoint: Double?
    let isVisible: Bool
    /// How far the bottom of the bar's row is above the bottom edge of the screen. The map
    /// screen stacks it above the zoom and centre-on-me buttons (see MapChromeLayout).
    var bottomInset: CGFloat = 225
    /// Called with the scale anchor, in the map view's own coordinate space,
    /// whenever the bar's place on screen changes: the middle of its maximum width,
    /// on its line's row. It is read from the bar's own frame, so it stays right in
    /// portrait, landscape, the compact layout and on an iPad. nil when the bar is
    /// not on screen.
    var onAnchorChange: (CGPoint?) -> Void = { _ in }

    /// Same key `UnitPreferences` stores, read here so the bar redraws the
    /// moment the operator changes Settings > Units.
    @AppStorage("unitSystem") private var unitSystem: UnitSystem = .metric

    /// The longest the bar is ever drawn, in points.
    static let maxBarWidth: CGFloat = 110
    /// Room either side of the bar so the end ticks and their outline are not clipped.
    private static let tickInset: CGFloat = 3
    private static let barHeight: CGFloat = 9
    /// The bar line is drawn this far above the bottom of its row.
    static let baselineInset: CGFloat = 1
    /// The row the bar line is drawn in. As wide as the longest bar, so where it is
    /// (and so the scale anchor) does not depend on how long the bar is right now,
    /// and it stays in place while the bar is hidden.
    private static let rowWidth: CGFloat = maxBarWidth + 2 * tickInset

    var body: some View {
        Group {
            if isVisible {
                VStack {
                    Spacer()
                    HStack {
                        scaleBar(MapScale.bar(metersPerPoint: metersPerPoint, maxWidth: Self.maxBarWidth, unitSystem: unitSystem))
                        Spacer()
                    }
                    .padding(.leading, 16)
                    .padding(.bottom, bottomInset)
                }
                .allowsHitTesting(false)
                // The map fills the whole screen, safe areas included. Its frame is
                // measured next to the bar's so the anchor is in the map's own space.
                .background(
                    GeometryReader { map in
                        Color.clear.preference(key: ScaleBarPlacementKey.self,
                                               value: ScaleBarPlacement(map: map.frame(in: .global)))
                    }
                    .ignoresSafeArea()
                )
            }
        }
        .onPreferenceChange(ScaleBarPlacementKey.self) { placement in
            onAnchorChange(placement.anchor)
        }
    }

    /// Label above, then a baseline with a tick at each end. The ticks are
    /// centred `width` points apart, so that gap is the labelled distance.
    /// The row the line is drawn in is always there, bar or no bar.
    private func scaleBar(_ bar: (width: CGFloat, label: String)?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let bar {
                Text(bar.label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .mapLabelOutline()
                    .padding(.leading, Self.tickInset)
            }

            ZStack(alignment: .leading) {
                if let bar {
                    Canvas { context, size in
                        let left = Self.tickInset
                        let right = Self.tickInset + bar.width
                        var line = Path()
                        line.move(to: CGPoint(x: left, y: 0))
                        line.addLine(to: CGPoint(x: left, y: size.height))
                        line.move(to: CGPoint(x: left, y: size.height - Self.baselineInset))
                        line.addLine(to: CGPoint(x: right, y: size.height - Self.baselineInset))
                        line.move(to: CGPoint(x: right, y: 0))
                        line.addLine(to: CGPoint(x: right, y: size.height))
                        // A dark outline under a white stroke reads on satellite and on the light street style
                        context.stroke(line, with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: 4))
                        context.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 2))
                    }
                    .frame(width: bar.width + 2 * Self.tickInset, height: Self.barHeight)
                }
            }
            .frame(width: Self.rowWidth, height: Self.barHeight, alignment: .leading)
            .background(
                GeometryReader { row in
                    Color.clear.preference(key: ScaleBarPlacementKey.self,
                                           value: ScaleBarPlacement(row: row.frame(in: .global)))
                }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map scale")
        .accessibilityValue(bar?.label ?? "")
        .accessibilityHidden(bar == nil)
    }
}

/// The bar's row and the map's frame, both in the global space, so one can be
/// read in the other whatever the global space's origin is.
private struct ScaleBarPlacement: Equatable {
    var row: CGRect?
    var map: CGRect?

    /// The scale anchor in the map's own space; nil until both frames are known.
    var anchor: CGPoint? {
        guard let row, let map else { return nil }
        return MapScale.anchor(barRow: row, in: map, baselineInset: ScaleBarView.baselineInset)
    }
}

private struct ScaleBarPlacementKey: PreferenceKey {
    static var defaultValue = ScaleBarPlacement()

    static func reduce(value: inout ScaleBarPlacement, nextValue: () -> ScaleBarPlacement) {
        let next = nextValue()
        if let row = next.row { value.row = row }
        if let map = next.map { value.map = map }
    }
}

private extension View {
    /// A thin dark edge around light text so it stays readable on any map style.
    func mapLabelOutline() -> some View {
        self
            .shadow(color: .black.opacity(0.85), radius: 0, x: 1, y: 0)
            .shadow(color: .black.opacity(0.85), radius: 0, x: -1, y: 0)
            .shadow(color: .black.opacity(0.85), radius: 0, x: 0, y: 1)
            .shadow(color: .black.opacity(0.85), radius: 0, x: 0, y: -1)
    }
}

// MARK: - Grid Overlay View
// MGRS-style grid that scales with map zoom level
// Grid squares represent actual geographic distances

struct GridOverlayView: View {
    let region: MKCoordinateRegion
    let isVisible: Bool

    var body: some View {
        if isVisible {
            GeometryReader { geometry in
                Canvas { context, size in
                    drawGrid(context: context, size: size, geometry: geometry)
                }
            }
            .allowsHitTesting(false)
        } else {
            EmptyView()
        }
    }

    // Calculate appropriate grid spacing in meters based on zoom level
    private func getGridSpacingMeters() -> Double {
        // Calculate the width of visible area in meters
        let center = region.center
        let span = region.span

        let point1 = CLLocation(
            latitude: center.latitude,
            longitude: center.longitude - span.longitudeDelta / 2
        )
        let point2 = CLLocation(
            latitude: center.latitude,
            longitude: center.longitude + span.longitudeDelta / 2
        )

        let visibleWidthMeters = point1.distance(from: point2)

        // Choose grid spacing based on visible area
        // Aim for roughly 5-15 grid lines across the screen
        if visibleWidthMeters > 500000 {
            return 100000  // 100km grid
        } else if visibleWidthMeters > 50000 {
            return 10000   // 10km grid
        } else if visibleWidthMeters > 5000 {
            return 1000    // 1km grid
        } else if visibleWidthMeters > 500 {
            return 100     // 100m grid
        } else {
            return 10      // 10m grid
        }
    }

    // Convert meters to pixels at current zoom level
    private func metersToPixels(_ meters: Double, screenWidth: CGFloat) -> CGFloat {
        let center = region.center
        let span = region.span

        let point1 = CLLocation(
            latitude: center.latitude,
            longitude: center.longitude - span.longitudeDelta / 2
        )
        let point2 = CLLocation(
            latitude: center.latitude,
            longitude: center.longitude + span.longitudeDelta / 2
        )

        let visibleWidthMeters = point1.distance(from: point2)
        guard visibleWidthMeters > 0 else { return 50 }

        return CGFloat(meters / visibleWidthMeters) * screenWidth
    }

    private func drawGrid(context: GraphicsContext, size: CGSize, geometry: GeometryProxy) {
        let gridColor = Color(hex: "#FFFC00").opacity(0.3)

        // Calculate grid spacing in pixels based on geographic distance
        let gridSpacingMeters = getGridSpacingMeters()
        let gridSpacingPixels = metersToPixels(gridSpacingMeters, screenWidth: size.width)

        // Ensure minimum spacing for visibility
        let effectiveSpacing = max(gridSpacingPixels, 20)

        // Draw vertical lines
        var x: CGFloat = 0
        while x <= size.width {
            let path = Path { p in
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(path, with: .color(gridColor), lineWidth: 1)
            x += effectiveSpacing
        }

        // Draw horizontal lines
        var y: CGFloat = 0
        while y <= size.height {
            let path = Path { p in
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(gridColor), lineWidth: 1)
            y += effectiveSpacing
        }

        drawGridLabels(context: context, size: size, gridSpacingMeters: gridSpacingMeters)
    }

    private func drawGridLabels(context: GraphicsContext, size: CGSize, gridSpacingMeters: Double) {
        let labelColor = Color(hex: "#FFFC00").opacity(0.5)
        let zone = Int((region.center.longitude + 180) / 6) + 1
        let latBand = getLatitudeBand(region.center.latitude)

        // Format grid spacing for display
        let spacingLabel: String
        if gridSpacingMeters >= 1000 {
            spacingLabel = "\(Int(gridSpacingMeters / 1000))km"
        } else {
            spacingLabel = "\(Int(gridSpacingMeters))m"
        }

        let label = "\(zone)\(latBand) \(spacingLabel)"

        context.drawLayer { ctx in
            let text = Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(labelColor)
            ctx.draw(text, at: CGPoint(x: 30, y: 20))
        }
    }

    private func getLatitudeBand(_ latitude: Double) -> String {
        let bands = ["C", "D", "E", "F", "G", "H", "J", "K", "L", "M", "N", "P", "Q", "R", "S", "T", "U", "V", "W", "X"]
        let index = Int((latitude + 80) / 8)
        if index < 0 || index >= bands.count { return "X" }
        return bands[index]
    }
}
