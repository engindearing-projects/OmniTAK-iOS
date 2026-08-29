//
//  InfoRow.swift
//  OmniTAKMobile
//
//  Shared label/value row + rounded-corner helpers. Extracted from
//  MarkerInfoPanel.swift when the dead EnhancedCoTMarker panel was
//  deleted — these pieces are used by EmergencyBeaconView,
//  ConnectionStatusWidget, and RoutePlanningView.
//

import SwiftUI

// MARK: - Info Row Component

struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .white

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.2))
    }
}

// MARK: - View Extension for Rounded Corners

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Color → UIColor bridge (extracted from CustomMarkerAnnotation.swift)

extension Color {
    var uiColor: UIColor {
        if #available(iOS 14.0, *) {
            return UIColor(self)
        } else {
            let components = self.cgColor?.components ?? [0, 0, 0, 1]
            return UIColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
        }
    }
}
