//
//  StatusStripStyle.swift
//  OmniTAKMobile
//
//  The look of the map's status strip across the top: the colours of its text and how dark its
//  backing is. The strip sits on whatever map is under it, so the text has to read on the palest
//  one (the light street style) as well as on satellite imagery. It was grey, blue and orange on
//  black at 50%: 1.5 to 4 to 1 on the light street style. Pure, so the contrast can be tested.
//

import SwiftUI

enum StatusStripStyle {

    /// A colour in sRGB, 0 to 1 per channel.
    struct RGB: Equatable {
        let r: Double
        let g: Double
        let b: Double

        var color: Color { Color(red: r, green: g, blue: b) }

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
    }

    /// The strip's backing: black at this opacity, over the map. Not opaque: the map stays visible behind it.
    static let backingOpacity: Double = 0.72

    // Text, each light enough to read on the backing over the palest map.
    static let text = RGB(r: 1.00, g: 1.00, b: 1.00)
    /// Quiet text: a server that is not connected.
    static let quiet = RGB(r: 0.85, g: 0.85, b: 0.87)
    /// Messages received.
    static let received = RGB(r: 0.50, g: 0.80, b: 1.00)
    /// Messages sent.
    static let sent = RGB(r: 1.00, g: 0.78, b: 0.35)
    /// Connected, and a good position fix.
    static let good = RGB(r: 0.45, g: 0.95, b: 0.55)
    /// Partly connected, and a poor position fix.
    static let warning = RGB(r: 1.00, g: 0.85, b: 0.30)
    /// The "OmniTAK" name shown on a phone held on its side (the app's yellow).
    static let brand = RGB(r: 1.00, g: 0.988, b: 0.00)

    /// Every colour the strip draws, as text or as a status dot.
    static let allText: [RGB] = [text, quiet, received, sent, good, warning, brand]

    /// WCAG contrast ratio of two relative luminances.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The contrast of `foreground` against the strip's backing laid over `map`. The black backing is
    /// composited in sRGB, as the screen does it.
    static func contrast(of foreground: RGB, overMap map: RGB, backingOpacity: Double = StatusStripStyle.backingOpacity) -> Double {
        let keep = 1 - backingOpacity
        let backing = RGB(r: map.r * keep, g: map.g * keep, b: map.b * keep)
        return contrast(foreground.luminance, backing.luminance)
    }
}
