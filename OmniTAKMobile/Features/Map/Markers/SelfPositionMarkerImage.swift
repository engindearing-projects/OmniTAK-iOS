//
//  SelfPositionMarkerImage.swift
//  OmniTAKMobile
//
//  Self-position UIImages for MKUserLocation's MKAnnotationView.
//  Two styles ship side by side so users can opt in/out of the
//  MIL-STD-2525 friendly-combat frame via a SettingsStore toggle:
//
//    - `.bullseye`  — legacy tactical bullseye (matches the Android
//      `ic_self_marker.xml` vector drawable). Default until 2026-05-12.
//    - `.milStdFriendlyCombat` — friendly combat ground frame
//      (a-f-G-U-C → SFGPUC------). Default from 2026-05-12 forward to
//      keep the operator's own pip in the same tactical iconography
//      family as friendly contact markers.
//

import UIKit

enum SelfPositionMarkerImage {

    /// Tactical accent (Compose: TacticalAccent #4ADE80) — matches
    /// `accent.primary` in DESIGN_TOKENS.md.
    private static let tacticalAccent = UIColor(red: 74/255.0, green: 222/255.0, blue: 128/255.0, alpha: 1.0)

    /// Tactical dark navy (Compose: TacticalBackground #0A1628).
    private static let tacticalDark = UIColor(red: 10/255.0, green: 22/255.0, blue: 40/255.0, alpha: 1.0)

    /// MIL-STD friendly fill — cyan/light-blue, matches the
    /// `Affiliation.friendly` Compose colour on Android.
    private static let milStdFriendlyFill = UIColor(red: 128/255.0, green: 224/255.0, blue: 255/255.0, alpha: 1.0)

    /// MIL-STD friendly stroke — saturated blue, NATO friendly frame.
    private static let milStdFriendlyStroke = UIColor(red: 0/255.0, green: 102/255.0, blue: 204/255.0, alpha: 1.0)

    /// 32×32 bullseye: dark outer ring → green fill → dark inner dot.
    /// Same proportions as Android `ic_self_marker.xml`.
    static let bullseye: UIImage = {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            // Outer dark ring (full bounds)
            tacticalDark.setFill()
            UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 28, height: 28)).fill()

            // Tactical-accent green fill (inset 4 from edge)
            tacticalAccent.setFill()
            UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 24, height: 24)).fill()

            // Inner dark dot (5pt radius, centered)
            tacticalDark.setFill()
            UIBezierPath(ovalIn: CGRect(x: 11, y: 11, width: 10, height: 10)).fill()
        }
    }()

    /// Issue #66 — 40×40 north-pointing equilateral arrow (triangle) for the
    /// heading-aware puck style. The arrow points north in the image coordinate
    /// system; Mapbox rotates the puck via `puckBearing = .heading` so it always
    /// indicates the device's actual heading. The anchor is the geometric center
    /// so Mapbox keeps the tip on the GPS coordinate regardless of rotation.
    ///
    /// Call `arrowMarker(heading:)` to get the image — the heading parameter is
    /// ignored here (Mapbox rotates for us) but kept so callers can pass it for
    /// potential future Cesium billboard use.
    static func arrowMarker(heading: Double? = nil) -> UIImage {
        let size = CGSize(width: 40, height: 40)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            // Equilateral-ish north-pointing triangle: tip at top center,
            // base at ~70% down from top. Center of mass is at ~50% height
            // so Mapbox's default center anchor keeps the tip above the coordinate.
            let cx = size.width / 2
            let tip = CGPoint(x: cx, y: 3)          // top tip
            let baseLeft  = CGPoint(x: 5, y: 37)    // bottom-left
            let baseRight = CGPoint(x: 35, y: 37)   // bottom-right

            let path = UIBezierPath()
            path.move(to: tip)
            path.addLine(to: baseRight)
            path.addLine(to: baseLeft)
            path.close()

            // Fill with tactical accent green, stroke with dark navy.
            tacticalAccent.setFill()
            path.fill()
            tacticalDark.setStroke()
            path.lineWidth = 2.0
            path.stroke()

            // Small center dot to anchor the GPS coordinate visually.
            let centerDotRect = CGRect(x: cx - 3, y: 22, width: 6, height: 6)
            tacticalDark.setFill()
            UIBezierPath(ovalIn: centerDotRect).fill()
        }
    }

    /// 36×36 friendly-combat ground frame: cyan fill, saturated-blue
    /// stroke, simple rectangle (no echelon, no function modifier).
    /// Matches the SFGPUC------ family of MIL-STD-2525B symbols and
    /// pairs visually with the Android bitmap produced by
    /// `MilStdIconCache.bitmapFor("a-f-G-U-C")`.
    static let milStdFriendlyCombat: UIImage = {
        let size = CGSize(width: 36, height: 36)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Inset 4pt so the stroke doesn't get clipped at the edges.
            let frame = CGRect(x: 5, y: 9, width: 26, height: 18)
            let path = UIBezierPath(rect: frame)
            milStdFriendlyFill.setFill()
            path.fill()
            milStdFriendlyStroke.setStroke()
            path.lineWidth = 2.5
            path.stroke()

            // Inner center dot anchors the pip to the GPS coordinate.
            tacticalDark.setFill()
            UIBezierPath(ovalIn: CGRect(x: 16, y: 16, width: 4, height: 4)).fill()
        }
    }()
}
