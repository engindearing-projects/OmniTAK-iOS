//
//  TAKIconRegistry.swift
//  OmniTAKMobile
//
//  Resolution + selection framework for the standard TAK icon suite
//  (issue #75 — "full TAK icon suite + custom icon pack import", Phase 1).
//
//  WHAT THIS SOLVES
//  ----------------
//  Before this, a marker only ever rendered as one of four MIL-STD-2525
//  affiliation frames (friendly rect / hostile diamond / neutral square /
//  unknown quatrefoil) via `MilStdMarkerSymbolView`. Markers pushed from
//  scripts or iTAK with a `<usericon iconsetpath="…">` (the Spot Map / Markers
//  / Google packs) had nowhere to resolve to, so they fell through to the
//  generic affiliation glyph — the gap kymyura reported on Discord.
//
//  This registry is the resolution layer: given a CoT type, an optional
//  `usericon` iconset path, and an optional ARGB color, it returns the right
//  bundled icon image — and it exposes a selectable catalogue so the same
//  icons can be picked when *placing* a marker. Resolution order mirrors ATAK:
//    1. explicit `usericon iconsetpath` (e.g. COT_MAPPING_SPOTMAP/red)
//    2. CoT type that maps to a known iconset (b-m-p-s-m → Spot Map)
//    3. caller's fallback (MIL-STD-2525 affiliation frame)
//
//  ICON SOURCING / LICENSING (read before adding packs)
//  ----------------------------------------------------
//  The standard ATAK "Spot Map" set is a colored dot keyed off the CoT
//  `<color>` element — it carries no creative artwork, so this file renders it
//  cleanly at runtime (UIImage, cached) keyed to ATAK's exact canonical color
//  palette and `COT_MAPPING_SPOTMAP/{color}` paths. That makes received and
//  placed spot-map markers resolve and round-trip correctly with ATAK / iTAK /
//  TAK Server with zero third-party assets.
//
//  The "Markers" and "Google" raster packs are bitmap artwork. The only local
//  source (atak-civ-source) is GPLv3 in this checkout, so those bitmaps CANNOT
//  be vendored into the App-Store binary without relicensing the app. The
//  framework here is pack-agnostic — `TAKIconPack` + `resolveImage` already
//  model multi-pack lookup — so when an Apache-2.0 / public-domain bitmap pack
//  (or a user-imported ATAK iconset, Phase 2) is available it slots in behind
//  the same API. See the build report for the explicit asset blocker.
//

import UIKit
import SwiftUI

// MARK: - TAK Icon Pack

/// Identifies a standard TAK icon pack. The `uid` matches ATAK's iconset UID /
/// `COT_MAPPING_*` path prefix so an `iconsetpath` round-trips byte-for-byte.
enum TAKIconPack: String, CaseIterable {
    /// Colored point markers — ATAK's "Spot Map". Path prefix
    /// `COT_MAPPING_SPOTMAP`, CoT type `b-m-p-s-m`. Bundled (runtime-rendered).
    case spotMap = "COT_MAPPING_SPOTMAP"
    /// ATAK "Markers" pack (bitmap artwork). Modeled for resolution but not
    /// bundled — see file header on the GPL asset blocker.
    case markers = "COT_MAPPING_2525C"
    /// ATAK "Google" pack (bitmap artwork). Modeled but not bundled.
    case google = "f7f71666-8b28-4b57-9fbb-e38e61d33b79"

    var displayName: String {
        switch self {
        case .spotMap: return "Spot Map"
        case .markers: return "Markers"
        case .google:  return "Google"
        }
    }

    /// Whether image assets for this pack ship in the app today. Only Spot Map
    /// is bundled (runtime-rendered); the bitmap packs await a clean source.
    var isBundled: Bool { self == .spotMap }
}

// MARK: - Spot Map Icon

/// The canonical ATAK Spot Map color palette. Values mirror
/// `SpotMapPalletFragment` in ATAK-CIV exactly so a marker placed here reads
/// identically in ATAK / iTAK and a marker received from them resolves back to
/// the same swatch. Each case is a selectable icon when placing a marker.
enum TAKSpotIcon: String, CaseIterable, Codable, Identifiable {
    case white, yellow, orange, brown, red, magenta, blue, cyan, green, grey, black

    var id: String { rawValue }

    /// The CoT type ATAK uses for every spot-map point (`SPOT_MAP_POINT_COT_TYPE`).
    /// Color is carried by the `<color>` element, not the type — same as ATAK.
    static let cotType = "b-m-p-s-m"

    /// `usericon` iconset path: `COT_MAPPING_SPOTMAP/{color}`. ATAK matches the
    /// trailing token case-insensitively, so the lowercased raw value is exact.
    var iconsetPath: String { "\(TAKIconPack.spotMap.rawValue)/\(rawValue)" }

    /// UIColor matching ATAK's swatch EXACTLY (alpha applied by the CoT
    /// `<color>`). These are the literal `android.graphics.Color` constants
    /// `SpotMapPalletFragment` uses — pure RGB, NOT iOS system colors — so a
    /// dot placed here is byte-identical to the same swatch in ATAK / iTAK.
    var uiColor: UIColor {
        switch self {
        case .white:   return UIColor(red: 1,       green: 1,       blue: 1,       alpha: 1) // WHITE
        case .yellow:  return UIColor(red: 1,       green: 1,       blue: 0,       alpha: 1) // YELLOW
        case .orange:  return UIColor(red: 255/255, green: 119/255, blue: 0,       alpha: 1) // argb(255,255,119,0)
        case .brown:   return UIColor(red: 139/255, green: 69/255,  blue: 19/255,  alpha: 1) // argb(255,139,69,19)
        case .red:     return UIColor(red: 1,       green: 0,       blue: 0,       alpha: 1) // RED
        case .magenta: return UIColor(red: 1,       green: 0,       blue: 1,       alpha: 1) // MAGENTA
        case .blue:    return UIColor(red: 0,       green: 0,       blue: 1,       alpha: 1) // BLUE
        case .cyan:    return UIColor(red: 0,       green: 1,       blue: 1,       alpha: 1) // CYAN
        case .green:   return UIColor(red: 0,       green: 1,       blue: 0,       alpha: 1) // GREEN
        case .grey:    return UIColor(red: 119/255, green: 119/255, blue: 119/255, alpha: 1) // argb(255,119,119,119)
        case .black:   return UIColor(red: 0,       green: 0,       blue: 0,       alpha: 1) // BLACK
        }
    }

    var color: Color { Color(uiColor) }

    /// Display name for the picker / accessibility.
    var displayName: String { rawValue.capitalized }

    /// 8-hex ARGB string (opaque) for the CoT `<color argb>` element, matching
    /// the `hexColor` convention used by `MarkerAffiliation`.
    var argbHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let R = Int((r * 255).rounded()), G = Int((g * 255).rounded()), B = Int((b * 255).rounded())
        return String(format: "FF%02X%02X%02X", R, G, B)
    }

    /// Resolve a Spot Map color from a `usericon` iconset path
    /// (`COT_MAPPING_SPOTMAP/red`, case-insensitive trailing token).
    static func from(iconsetPath: String) -> TAKSpotIcon? {
        guard iconsetPath.uppercased().hasPrefix(TAKIconPack.spotMap.rawValue) else { return nil }
        let token = iconsetPath.split(separator: "/").last.map { String($0).lowercased() } ?? ""
        // "label" (label-only spot) and unknown tokens fall back to white.
        return TAKSpotIcon(rawValue: token) ?? (token.isEmpty ? nil : .white)
    }
}

// MARK: - TAK Icon Registry

/// Central resolver + catalogue for the TAK icon suite. Thread-safe singleton;
/// rendered glyphs are cached so the map's annotation refresh stays cheap.
final class TAKIconRegistry {
    static let shared = TAKIconRegistry()
    private init() {}

    private var cache: [String: UIImage] = [:]
    private let cacheLock = NSLock()
    private let cacheCap = 256

    // MARK: Selection catalogue (placing markers)

    /// Spot Map icons offered in the marker-placement picker, in ATAK order.
    var selectableSpotIcons: [TAKSpotIcon] { TAKSpotIcon.allCases }

    /// Packs the suite knows about, flagged by whether their assets are bundled.
    var availablePacks: [TAKIconPack] { TAKIconPack.allCases }

    // MARK: Resolution (rendering received / placed markers)

    /// Resolve a renderable icon for a marker. Returns nil when no TAK-suite
    /// icon applies, so the caller falls back to MIL-STD-2525 affiliation art.
    ///
    /// - Parameters:
    ///   - cotType: CoT `type` (e.g. `b-m-p-s-m`, `a-f-G-U-C-I`).
    ///   - iconsetPath: `usericon iconsetpath` if the CoT carried one.
    ///   - argb: optional override color (signed ARGB int from `<color>`); used
    ///           for Spot Map points whose color rides the `<color>` element.
    ///   - size: target point size for the rendered glyph.
    func resolveImage(cotType: String,
                      iconsetPath: String? = nil,
                      argb: Int? = nil,
                      size: CGFloat = 36) -> UIImage? {
        // 1. Explicit Spot Map iconset path wins.
        if let path = iconsetPath, let spot = TAKSpotIcon.from(iconsetPath: path) {
            let color = argb.flatMap { Self.uiColor(fromARGB: $0) } ?? spot.uiColor
            return spotDot(color: color, size: size, cacheKey: "spot|\(path)|\(argb ?? 0)|\(Int(size))")
        }
        // 2. Spot Map CoT type (color carried by <color>, default white).
        if cotType == TAKSpotIcon.cotType {
            let color = argb.flatMap { Self.uiColor(fromARGB: $0) } ?? TAKSpotIcon.white.uiColor
            return spotDot(color: color, size: size, cacheKey: "spot|type|\(argb ?? 0)|\(Int(size))")
        }
        // 3. Unbundled bitmap packs (Markers/Google) would resolve here once a
        //    clean asset source lands — intentionally nil for now so the caller
        //    keeps using the MIL-STD-2525 fallback rather than a blank square.
        return nil
    }

    /// Convenience: the rendered glyph for a selectable Spot Map icon (picker
    /// swatches, recent-marker rows).
    func image(for spot: TAKSpotIcon, size: CGFloat = 36) -> UIImage {
        spotDot(color: spot.uiColor, size: size, cacheKey: "spot|sel|\(spot.rawValue)|\(Int(size))")
    }

    // MARK: - Rendering

    /// ATAK's spot-map point: a filled dot with a thin contrasting outline so
    /// it reads on any basemap. White/black get an inverted ring for contrast.
    private func spotDot(color: UIColor, size: CGFloat, cacheKey: String) -> UIImage {
        if let cached = cached(cacheKey) { return cached }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let img = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.18, dy: size * 0.18)
            // Drop shadow for legibility against bright imagery.
            ctx.cgContext.setShadow(offset: .zero, blur: size * 0.06, color: UIColor.black.withAlphaComponent(0.5).cgColor)
            color.setFill()
            let dot = UIBezierPath(ovalIn: rect)
            dot.fill()
            ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            // Contrasting outline — black ring for light dots, white for dark.
            let outline: UIColor = color.isLight ? .black : .white
            outline.setStroke()
            dot.lineWidth = max(1, size * 0.06)
            dot.stroke()
        }
        store(cacheKey, img)
        return img
    }

    private func cached(_ key: String) -> UIImage? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[key]
    }

    private func store(_ key: String, _ image: UIImage) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache.count >= cacheCap { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
    }

    // MARK: - Color helpers

    /// Decode a signed ARGB int (as carried in CoT `<color argb>`) to UIColor.
    static func uiColor(fromARGB argb: Int) -> UIColor {
        let v = UInt32(bitPattern: Int32(truncatingIfNeeded: argb))
        let a = CGFloat((v >> 24) & 0xFF) / 255.0
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        // Treat a fully-transparent alpha (common when color omits alpha) as opaque.
        return UIColor(red: r, green: g, blue: b, alpha: a == 0 ? 1 : a)
    }
}

// MARK: - UIColor luminance helper

private extension UIColor {
    /// Perceived-luminance test used to pick a contrasting outline.
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }
}
