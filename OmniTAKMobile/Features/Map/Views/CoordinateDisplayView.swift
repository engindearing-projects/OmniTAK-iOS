import SwiftUI
import CoreLocation

// MARK: - Coordinate Display View
// ATAK-style coordinate readout for the operator's own position. It shares the
// app-wide coordinate format (Settings > Coordinate Format, persisted under the
// "coordinateDisplayFormat" key) so this chip, the cursor/center readout, and
// the Settings picker always agree. Tapping the chip exposes the full format
// list (DD, DM, DMS, MGRS, UTM, BNG, TWD97); picking one updates the shared
// setting. Format conversion is delegated to CoordinateDisplayFormat so there
// is a single conversion path across the app.

struct CoordinateDisplayView: View {
    let coordinate: CLLocationCoordinate2D?
    let isVisible: Bool

    // Single source of truth, shared with SettingsView and MapStateManager.
    @AppStorage("coordinateDisplayFormat") private var formatString: String = "MGRS"
    @State private var isExpanded: Bool = false

    private var selectedFormat: CoordinateDisplayFormat {
        CoordinateDisplayFormat(rawValue: formatString) ?? .mgrs
    }

    var body: some View {
        if isVisible, let coordinate = coordinate {
            // Display inline - parent controls positioning
            VStack(alignment: .leading, spacing: 0) {
                if isExpanded {
                    expandedCoordinateDisplay(for: coordinate)
                } else {
                    collapsedCoordinateDisplay(for: coordinate)
                }
            }
        }
    }

    private func collapsedCoordinateDisplay(for coordinate: CLLocationCoordinate2D) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#00FFFF"))

            Text(selectedFormat.shortName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(hex: "#FFFC00"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.7))
        .cornerRadius(6)
        // Issue #94 — ATAK-style red frame around the coordinate chip.
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red, lineWidth: 2))
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded = true
            }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }

    private func expandedCoordinateDisplay(for coordinate: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Format selector buttons - scrollable for better UX
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CoordinateDisplayFormat.allCases) { format in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                // Write the shared setting so the cursor/center
                                // readout and Settings picker stay in sync.
                                formatString = format.rawValue
                            }
                            // Haptic feedback
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                        }) {
                            VStack(spacing: 2) {
                                Text(format.shortName)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(selectedFormat == format ? .black : .white)

                                // Show a region tag for the localized grids.
                                if format == .bng {
                                    Text("UK")
                                        .font(.system(size: 7, weight: .medium))
                                        .foregroundColor(selectedFormat == format ? .black.opacity(0.7) : .white.opacity(0.5))
                                } else if format == .twd97 {
                                    Text("TW")
                                        .font(.system(size: 7, weight: .medium))
                                        .foregroundColor(selectedFormat == format ? .black.opacity(0.7) : .white.opacity(0.5))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedFormat == format ? Color(hex: "#FFFC00") : Color.white.opacity(0.2))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            .padding(.bottom, 4)

            // Coordinate value display
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(selectedFormat.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.gray)

                    // Special indicator for BNG
                    if selectedFormat == .bng {
                        Image(systemName: "map.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                }

                Text(selectedFormat.format(coordinate))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#00FFFF"))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
        // Issue #94 — ATAK-style red frame around the expanded coordinate panel.
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 2))
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded = false
            }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }
}

// MARK: - Preview

struct CoordinateDisplayView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray.ignoresSafeArea()

            VStack(spacing: 40) {
                // Taipei, Taiwan (TWD97 coverage)
                CoordinateDisplayView(
                    coordinate: CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645),
                    isVisible: true
                )

                // Washington DC
                CoordinateDisplayView(
                    coordinate: CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365),
                    isVisible: true
                )

                // Sydney, Australia
                CoordinateDisplayView(
                    coordinate: CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
                    isVisible: true
                )
            }
        }
    }
}
