import SwiftUI
import CoreLocation

// MARK: - Compass Overlay View
// ATAK-style rotating compass showing current map bearing.
// Tapping the collapsed compass resets the map to north (issue #73).
// The `isNorthLocked` flag is shown as a lock badge when active (issue #72).

struct CompassOverlayView: View {
    let heading: CLLocationDirection? // 0-360 degrees, 0 = North
    let isVisible: Bool
    /// Current map bearing (degrees CW from north). Drives the compass
    /// needle when provided; falls back to device heading otherwise.
    var mapBearing: Double = 0
    /// True while the north-lock is engaged (issue #72).
    var isNorthLocked: Bool = false
    /// Called when the operator taps the collapsed compass to snap north.
    var onResetNorth: (() -> Void)? = nil

    @State private var displayHeading: Double = 0
    @State private var isExpanded: Bool = false

    var body: some View {
        if isVisible {
            VStack {
                HStack {
                    Spacer()
                    if isExpanded {
                        expandedCompassView
                    } else {
                        collapsedCompassView
                    }
                }
                .padding(.trailing, 16)
                .padding(.top, 60)
                Spacer()
            }
        }
    }

    private var collapsedCompassView: some View {
        ZStack {
            // Small compass indicator - 60x60
            Circle()
                .fill(Color.black.opacity(0.7))
                .frame(width: 60, height: 60)

            Circle()
                .stroke(isNorthLocked ? Color.cyan.opacity(0.6) : Color(hex: "#FFFC00").opacity(0.3), lineWidth: 1.5)
                .frame(width: 60, height: 60)

            // Simplified compass rose — rotates by map bearing
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 48, height: 48)

                // North indicator (red)
                VStack(spacing: 0) {
                    Triangle()
                        .fill(Color.red)
                        .frame(width: 8, height: 12)
                    Spacer()
                }
                .frame(height: 42)

                // South indicator (white)
                VStack(spacing: 0) {
                    Spacer()
                    Triangle()
                        .fill(Color.white)
                        .frame(width: 6, height: 8)
                        .rotationEffect(.degrees(180))
                }
                .frame(height: 42)

                // East-West line
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 42, height: 1)
            }
            // Use map bearing (not device heading) so the needle tracks
            // which direction the map is rotated, not where the device points.
            .rotationEffect(.degrees(-mapBearing))
            .animation(.easeInOut(duration: 0.3), value: mapBearing)

            // Center dot
            Circle()
                .fill(Color(hex: "#FFFC00"))
                .frame(width: 6, height: 6)

            // Map bearing text below the circle
            VStack {
                Spacer()
                Text(bearingText)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isNorthLocked ? Color.cyan : Color(hex: "#FFFC00"))
                    .offset(y: 34)
            }

            // North-lock badge — small lock icon in top-right corner
            if isNorthLocked {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.cyan)
                            .offset(x: 2, y: -2)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: 60, height: 60)
        .onTapGesture {
            // Tap snaps map to north and collapses any expanded state (issue #73)
            onResetNorth?()
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded = false
            }
        }
        .onChange(of: heading) { newHeading in
            if let newHeading = newHeading {
                displayHeading = newHeading
            }
        }
    }

    private var expandedCompassView: some View {
        ZStack {
            // Outer container with ATAK styling
            Circle()
                .fill(Color.black.opacity(0.7))
                .frame(width: 100, height: 100)

            Circle()
                .stroke(isNorthLocked ? Color.cyan.opacity(0.6) : Color(hex: "#FFFC00").opacity(0.3), lineWidth: 2)
                .frame(width: 100, height: 100)

            // Compass rose — rotates by map bearing
            ZStack {
                // Cardinal directions background circle
                Circle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 80, height: 80)

                // North indicator (red)
                VStack(spacing: 0) {
                    Triangle()
                        .fill(Color.red)
                        .frame(width: 12, height: 16)
                    Spacer()
                }
                .frame(height: 70)

                // South indicator (white)
                VStack(spacing: 0) {
                    Spacer()
                    Triangle()
                        .fill(Color.white)
                        .frame(width: 8, height: 12)
                        .rotationEffect(.degrees(180))
                }
                .frame(height: 70)

                // East-West line
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 70, height: 1)

                // Cardinal direction letters
                // Note: Using 1x1 frames instead of 0x0 to avoid "clip: empty path" warnings
                VStack {
                    Text("N")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.red)
                        .offset(y: -32)

                    Spacer()

                    Text("S")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(y: 32)
                }
                .frame(height: 1)

                HStack {
                    Text("W")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(x: -32)

                    Spacer()

                    Text("E")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(x: 32)
                }
                .frame(width: 1)
            }
            .rotationEffect(.degrees(-mapBearing))
            .animation(.easeInOut(duration: 0.3), value: mapBearing)

            // Center dot
            Circle()
                .fill(Color(hex: "#FFFC00"))
                .frame(width: 8, height: 8)

            // Map bearing display at bottom
            VStack {
                Spacer()
                Text(bearingText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(isNorthLocked ? Color.cyan : Color(hex: "#FFFC00"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(4)
                    .offset(y: 52)
            }
        }
        .frame(width: 100, height: 100)
        .onTapGesture {
            // Tap on expanded view snaps to north (same as collapsed tap)
            onResetNorth?()
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded = false
            }
        }
        .onChange(of: heading) { newHeading in
            if let newHeading = newHeading {
                displayHeading = newHeading
            }
        }
    }

    /// Formatted map bearing — shows "000°" when north-locked (issue #73).
    private var bearingText: String {
        let normalized = Int(mapBearing.truncatingRemainder(dividingBy: 360).rounded())
        let clamped = (normalized + 360) % 360
        return String(format: "%03d°", clamped)
    }

    private var headingText: String {
        guard let heading = heading else { return "---°" }

        let normalized = Int(heading.rounded()) % 360
        return String(format: "%03d°", normalized)
    }

    private var cardinalDirection: String {
        guard let heading = heading else { return "---" }

        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((heading + 22.5) / 45.0) % 8
        return directions[index]
    }
}

// MARK: - Triangle Shape for Compass Indicators

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

struct CompassOverlayView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray.ignoresSafeArea()

            VStack(spacing: 40) {
                CompassOverlayView(heading: 0, isVisible: true)
                CompassOverlayView(heading: 45, isVisible: true)
                CompassOverlayView(heading: 180, isVisible: true)
                CompassOverlayView(heading: 270, isVisible: true)
            }
        }
    }
}

