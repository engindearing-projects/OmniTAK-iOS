import SwiftUI
import MapKit
import CoreLocation

// MARK: - Scale Bar View
// A line whose on-screen length is exactly the distance printed above it.
// The length comes from the active map engine's real ground scale (metres per
// screen point); the 1/2/5 rounding and the unit live in `MapScale`.

struct ScaleBarView: View {
    /// Ground metres per screen point at the middle of the map, from whichever
    /// engine is showing. nil while the engine has no ground to measure (the
    /// globe's horizon, space): no bar is drawn then rather than a wrong one.
    /// When the map is tilted the scale also changes up and down the screen, so
    /// the bar is exact for ground at the middle and reads long for the nearer
    /// ground it is drawn over.
    let metersPerPoint: Double?
    let isVisible: Bool
    /// #182 — compact landscape layout. The portrait bottom offset (225, tuned
    /// to sit above the GPS cluster + full-width bar) lifts the scale bar near
    /// the top on the short landscape canvas, so shrink the reservation.
    var compact: Bool = false

    /// Same key `UnitPreferences` stores, read here so the bar redraws the
    /// moment the operator changes Settings > Units.
    @AppStorage("unitSystem") private var unitSystem: UnitSystem = .metric

    /// The longest the bar is ever drawn, in points.
    static let maxBarWidth: CGFloat = 110
    /// Room either side of the bar so the end ticks and their outline are not clipped.
    private static let tickInset: CGFloat = 3
    private static let barHeight: CGFloat = 9

    var body: some View {
        if isVisible,
           let bar = MapScale.bar(metersPerPoint: metersPerPoint, maxWidth: Self.maxBarWidth, unitSystem: unitSystem) {
            VStack {
                Spacer()
                HStack {
                    scaleBar(width: bar.width, label: bar.label)
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.bottom, compact ? 110 : 225)
            }
            .allowsHitTesting(false)
        }
    }

    /// Label above, then a baseline with a tick at each end. The ticks are
    /// centred `width` points apart, so that gap is the labelled distance.
    private func scaleBar(width: CGFloat, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .mapLabelOutline()
                .padding(.leading, Self.tickInset)

            Canvas { context, size in
                let left = Self.tickInset
                let right = Self.tickInset + width
                var line = Path()
                line.move(to: CGPoint(x: left, y: 0))
                line.addLine(to: CGPoint(x: left, y: size.height))
                line.move(to: CGPoint(x: left, y: size.height - 1))
                line.addLine(to: CGPoint(x: right, y: size.height - 1))
                line.move(to: CGPoint(x: right, y: 0))
                line.addLine(to: CGPoint(x: right, y: size.height))
                // A dark outline under a white stroke reads on satellite and on the light street style
                context.stroke(line, with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: 4))
                context.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 2))
            }
            .frame(width: width + 2 * Self.tickInset, height: Self.barHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map scale")
        .accessibilityValue(label)
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
