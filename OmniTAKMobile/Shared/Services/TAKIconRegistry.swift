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
//    1. explicit `usericon iconsetpath` (Spot Map / Markers / Google)
//    2. CoT type that maps to a known iconset (b-m-p-s-m → Spot Map)
//    3. caller's fallback (MIL-STD-2525 affiliation frame)
//
//  ICON SOURCING / LICENSING (read before adding packs)
//  ----------------------------------------------------
//  Every pack here is rendered at runtime — OmniTAK ships ZERO third-party
//  bitmap assets for the suite, so there is no licensing taint on the App-Store
//  binary (ATAK-CIV's iconsets.sqlite is GPLv3 and cannot be vendored).
//
//    • Spot Map   — colored dots keyed off the CoT `<color>` element. No
//                   creative artwork; rendered to ATAK's exact canonical color
//                   palette + `COT_MAPPING_SPOTMAP/{color}` paths.
//    • Markers    — the ATAK "Markers" pack IS the 2525C symbol set
//                   (`COT_MAPPING_2525C`, ATAK string `civ_cot2525C` = "Markers").
//                   It resolves through OmniTAK's existing MIL-STD-2525 renderer
//                   (the same bundled symbology used everywhere else), so a
//                   `COT_MAPPING_2525C/{2525code}` path renders the real symbol.
//    • Google     — the ATAK "Google" place-marker pack (96 named POI tokens
//                   under iconset uid `f7f71666-…`). The TOKEN NAMES are factual
//                   metadata (coffee/hospitals/gas_stations/…), not copyrightable
//                   art; each is mapped to an SF-Symbol glyph drawn on a Google-
//                   Maps-style teardrop pin. A received `…/coffee.png` resolves
//                   to the coffee pin; the same set is selectable when placing.
//
//  Phase 2 (user-imported ATAK iconsets: iconset.xml + PNGs via data package)
//  slots in behind the same `TAKIconPack` + `resolveImage` API.
//

import UIKit
import SwiftUI

// MARK: - TAK Icon Pack

/// Identifies a standard TAK icon pack. The `rawValue` matches ATAK's iconset
/// UID / `COT_MAPPING_*` path prefix so an `iconsetpath` round-trips exactly.
enum TAKIconPack: String, CaseIterable {
    /// Colored point markers — ATAK's "Spot Map". Path prefix
    /// `COT_MAPPING_SPOTMAP`, CoT type `b-m-p-s-m`. Rendered (colored dot).
    case spotMap = "COT_MAPPING_SPOTMAP"
    /// ATAK "Markers" pack — the 2525C symbol set (`COT_MAPPING_2525C`,
    /// ATAK display string `civ_cot2525C` = "Markers"). Rendered via the app's
    /// existing MIL-STD-2525 engine.
    case markers = "COT_MAPPING_2525C"
    /// ATAK "Google" place-marker pack. Iconset uid (matches ATAK's
    /// `iconsets.sqlite`). Rendered as SF-Symbol POI pins keyed by token name.
    case google = "f7f71666-8b28-4b57-9fbb-e38e61d33b79"

    var displayName: String {
        switch self {
        case .spotMap: return "Spot Map"
        case .markers: return "Markers"
        case .google:  return "Google"
        }
    }

    /// Whether OmniTAK can render this pack today. All three standard packs are
    /// now rendered at runtime (no third-party assets), so all are bundled.
    var isBundled: Bool { true }
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

// MARK: - Markers (2525C) Icon

/// The ATAK "Markers" pack (`COT_MAPPING_2525C`). ATAK's "Markers" iconset is
/// the 2525C symbol set — each icon is just a CoT type rendered with MIL-STD
/// symbology, which OmniTAK already does. This enum is the *selectable* slice
/// of that set offered in the placement picker (the most-used markers); the
/// resolver below handles ANY `COT_MAPPING_2525C/{type}` path, not just these.
enum TAKMarkersIcon: String, CaseIterable, Codable, Identifiable {
    case friendlyGround   // friendly ground unit
    case hostileGround    // hostile ground unit
    case neutralGround    // neutral ground
    case unknownGround    // unknown ground
    case friendlyInfantry // friendly infantry
    case hostileInfantry  // hostile infantry
    case friendlyVehicle  // friendly ground vehicle
    case hostileVehicle   // hostile ground vehicle
    case friendlyAir      // friendly aircraft
    case hostileAir       // hostile aircraft

    var id: String { rawValue }

    /// The MIL-STD-2525 CoT type this marker carries — drives both the rendered
    /// symbol and the emitted CoT `type`.
    var cotType: String {
        switch self {
        case .friendlyGround:   return "a-f-G-U-C"
        case .hostileGround:    return "a-h-G-U-C"
        case .neutralGround:    return "a-n-G"
        case .unknownGround:    return "a-u-G"
        case .friendlyInfantry: return "a-f-G-U-C-I"
        case .hostileInfantry:  return "a-h-G-U-C-I"
        case .friendlyVehicle:  return "a-f-G-E-V"
        case .hostileVehicle:   return "a-h-G-E-V"
        case .friendlyAir:      return "a-f-A"
        case .hostileAir:       return "a-h-A"
        }
    }

    /// `usericon` iconset path: `COT_MAPPING_2525C/{cotType}`. ATAK keys the
    /// Markers pack by the symbol's CoT type.
    var iconsetPath: String { "\(TAKIconPack.markers.rawValue)/\(cotType)" }

    var displayName: String {
        switch self {
        case .friendlyGround:   return "Friendly"
        case .hostileGround:    return "Hostile"
        case .neutralGround:    return "Neutral"
        case .unknownGround:    return "Unknown"
        case .friendlyInfantry: return "Fr Infantry"
        case .hostileInfantry:  return "Ho Infantry"
        case .friendlyVehicle:  return "Fr Vehicle"
        case .hostileVehicle:   return "Ho Vehicle"
        case .friendlyAir:      return "Fr Air"
        case .hostileAir:       return "Ho Air"
        }
    }

    /// Short label for the placement swatch.
    var shortName: String {
        switch self {
        case .friendlyGround:   return "FRND"
        case .hostileGround:    return "HOST"
        case .neutralGround:    return "NEUT"
        case .unknownGround:    return "UNKN"
        case .friendlyInfantry: return "F-INF"
        case .hostileInfantry:  return "H-INF"
        case .friendlyVehicle:  return "F-VEH"
        case .hostileVehicle:   return "H-VEH"
        case .friendlyAir:      return "F-AIR"
        case .hostileAir:       return "H-AIR"
        }
    }

    /// The 2525C CoT type carried in a `COT_MAPPING_2525C/{type}` path, if any.
    static func cotType(fromIconsetPath path: String) -> String? {
        guard path.uppercased().hasPrefix(TAKIconPack.markers.rawValue) else { return nil }
        let token = path.split(separator: "/").last.map(String.init) ?? ""
        return token.isEmpty ? nil : token
    }
}

// MARK: - Google Place Icon

/// The ATAK "Google" place-marker pack (iconset uid `f7f71666-…`). The token
/// names below are the exact filenames ATAK ships in `iconsets.sqlite` (factual
/// metadata, not copyrightable art); each maps to an SF-Symbol glyph rendered
/// on a Google-Maps-style teardrop pin. A received `…/coffee.png` resolves to
/// the coffee pin, and the same set is selectable when placing a marker.
enum TAKGoogleIcon: String, CaseIterable, Codable, Identifiable {
    case airports, bars, cabs, bus, coffee, dining, dollar, ferry
    case firedept, fishing, flag, gas_stations, golf, grocery, heliport
    case hiker, hospitals, info, lodging, marina, mechanic, movies
    case parks, phone, picnic, police, poi, post_office, rail
    case ranger_station, sailing, shopping, ski, swimming, target
    case toilets, trail, tram, truck, water, camera, caution
    case earthquake, falling_rocks, volcano

    var id: String { rawValue }

    /// The ATAK filename token (what a `…/{token}.png` iconsetpath carries).
    var token: String { rawValue }

    /// `usericon` iconset path: `{googleUID}/{token}.png` — exactly how ATAK
    /// writes a Google-pack marker so it round-trips byte-for-byte.
    var iconsetPath: String { "\(TAKIconPack.google.rawValue)/\(rawValue).png" }

    /// Default CoT type ATAK files these under (mostly `a-u-G`, unknown ground).
    var cotType: String {
        switch self {
        case .airports:               return "a-u-A"
        case .heliport:               return "a-u-A-C-H"
        case .bus, .cabs, .truck, .rail: return "a-u-G-E-V"
        case .ferry, .sailing, .marina: return "a-u-S"
        case .firedept, .hospitals, .grocery, .lodging,
             .movies, .shopping, .ranger_station, .post_office, .poi:
            return "a-u-G-I"
        default:                      return "a-u-G"
        }
    }

    /// SF-Symbol glyph used to render the pin face. Chosen to read like the
    /// Google place icon of the same name.
    var symbolName: String {
        switch self {
        case .airports:       return "airplane"
        case .heliport:       return "airplane.circle.fill"
        case .bars:           return "cup.and.saucer.fill"
        case .cabs:           return "car.fill"
        case .bus:            return "car.fill"
        case .coffee:         return "cup.and.saucer.fill"
        case .dining:         return "fork.knife"
        case .dollar:         return "dollarsign.circle.fill"
        case .ferry:          return "ferry.fill"
        case .firedept:       return "flame.fill"
        case .fishing:        return "drop.fill"
        case .flag:           return "flag.fill"
        case .gas_stations:   return "fuelpump.fill"
        case .golf:           return "flag.fill"
        case .grocery:        return "cart.fill"
        case .hiker:          return "figure.walk"
        case .hospitals:      return "cross.fill"
        case .info:           return "info.circle.fill"
        case .lodging:        return "bed.double.fill"
        case .marina:         return "sailboat.fill"
        case .mechanic:       return "wrench.and.screwdriver.fill"
        case .movies:         return "film.fill"
        case .parks:          return "leaf.fill"
        case .phone:          return "phone.fill"
        case .picnic:         return "fork.knife"
        case .police:         return "shield.lefthalf.filled"
        case .poi:            return "mappin"
        case .post_office:    return "envelope.fill"
        case .rail:           return "tram.fill"
        case .ranger_station: return "house.fill"
        case .sailing:        return "sailboat.fill"
        case .shopping:       return "bag.fill"
        case .ski:            return "snowflake"
        case .swimming:       return "drop.fill"
        case .target:         return "scope"
        case .toilets:        return "figure.walk"
        case .trail:          return "arrow.triangle.turn.up.right.diamond.fill"
        case .tram:           return "tram.fill"
        case .truck:          return "shippingbox.fill"
        case .water:          return "drop.fill"
        case .camera:         return "camera.fill"
        case .caution:        return "exclamationmark.triangle.fill"
        case .earthquake:     return "waveform.path.ecg"
        case .falling_rocks:  return "triangle.fill"
        case .volcano:        return "triangle.fill"
        }
    }

    /// Pin tint — hazards red/amber, transport blue, the rest the Google red.
    var tintColor: UIColor {
        switch self {
        case .caution, .falling_rocks, .firedept, .volcano, .earthquake:
            return UIColor.systemRed
        case .airports, .heliport, .bus, .cabs, .truck, .rail, .tram, .ferry, .sailing, .marina:
            return UIColor.systemBlue
        case .hospitals:
            return UIColor.systemRed
        case .parks, .golf, .hiker, .trail, .fishing, .water:
            return UIColor.systemGreen
        default:
            return UIColor(red: 0.85, green: 0.18, blue: 0.18, alpha: 1) // Google place red
        }
    }

    var displayName: String {
        token.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Match a Google-pack `iconsetpath` (`{googleUID}/coffee.png`) to a token.
    static func from(iconsetPath: String) -> TAKGoogleIcon? {
        guard iconsetPath.hasPrefix(TAKIconPack.google.rawValue) else { return nil }
        var token = iconsetPath.split(separator: "/").last.map(String.init) ?? ""
        if token.lowercased().hasSuffix(".png") { token = String(token.dropLast(4)) }
        return TAKGoogleIcon(rawValue: token.lowercased())
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
    private let cacheCap = 512

    // MARK: Selection catalogue (placing markers)

    /// Spot Map icons offered in the marker-placement picker, in ATAK order.
    var selectableSpotIcons: [TAKSpotIcon] { TAKSpotIcon.allCases }

    /// Markers (2525C) icons offered in the placement picker.
    var selectableMarkersIcons: [TAKMarkersIcon] { TAKMarkersIcon.allCases }

    /// Google place icons offered in the placement picker.
    var selectableGoogleIcons: [TAKGoogleIcon] { TAKGoogleIcon.allCases }

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
        // 0. Imported custom pack (Phase 2) — checked before bundled packs so
        //    a user pack with the same uid prefix wins over a bundled one.
        if let path = iconsetPath, IconPackRegistry.shared.handles(path) {
            return importedPackImage(iconsetPath: path, size: size)
        }
        // 1. Explicit iconset path wins. Match against each standard pack.
        if let path = iconsetPath, !path.isEmpty {
            // 1a. Spot Map — colored dot keyed off the path/color.
            if let spot = TAKSpotIcon.from(iconsetPath: path) {
                let color = argb.flatMap { Self.uiColor(fromARGB: $0) } ?? spot.uiColor
                return spotDot(color: color, size: size, cacheKey: "spot|\(path)|\(argb ?? 0)|\(Int(size))")
            }
            // 1b. Google place pack — SF-Symbol POI pin keyed by token.
            if let g = TAKGoogleIcon.from(iconsetPath: path) {
                return googlePin(g, size: size)
            }
            // 1c. Markers pack (2525C) — render the carried 2525 type via the
            //     app's MIL-STD engine. If the path carried no usable type,
            //     fall back to the marker's own CoT type below.
            if let typeFromPath = TAKMarkersIcon.cotType(fromIconsetPath: path) {
                return milStdSymbol(cotType: typeFromPath, size: size)
            }
        }
        // 2. Spot Map CoT type (color carried by <color>, default white).
        if cotType == TAKSpotIcon.cotType {
            let color = argb.flatMap { Self.uiColor(fromARGB: $0) } ?? TAKSpotIcon.white.uiColor
            return spotDot(color: color, size: size, cacheKey: "spot|type|\(argb ?? 0)|\(Int(size))")
        }
        // 3. No TAK-suite match — caller keeps the MIL-STD-2525 fallback.
        return nil
    }

    /// Load and cache an image from an imported custom iconset pack.
    func importedPackImage(iconsetPath: String, size: CGFloat) -> UIImage? {
        let key = IconPackRegistry.shared.cacheKey(for: iconsetPath) + "|\(Int(size))"
        if let cached = cached(key) { return cached }
        guard let (pack, icon) = IconPackRegistry.shared.resolve(iconsetPath) else { return nil }
        guard let raw = IconPackRegistry.shared.loadImage(pack: pack, icon: icon) else { return nil }
        // Scale to target size preserving aspect ratio, matching bundled icon behavior.
        let scaled = raw.scaledToFill(size: CGSize(width: size, height: size))
        store(key, scaled)
        return scaled
    }

    /// Convenience: the rendered glyph for a selectable Spot Map icon (picker
    /// swatches, recent-marker rows).
    func image(for spot: TAKSpotIcon, size: CGFloat = 36) -> UIImage {
        spotDot(color: spot.uiColor, size: size, cacheKey: "spot|sel|\(spot.rawValue)|\(Int(size))")
    }

    /// The rendered glyph for a selectable Markers (2525C) icon.
    func image(for marker: TAKMarkersIcon, size: CGFloat = 36) -> UIImage {
        milStdSymbol(cotType: marker.cotType, size: size)
    }

    /// The rendered glyph for a selectable Google place icon.
    func image(for google: TAKGoogleIcon, size: CGFloat = 36) -> UIImage {
        googlePin(google, size: size)
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

    /// Render a MIL-STD-2525 symbol (no callsign) to a UIImage via the app's
    /// existing `MilStd2525SymbolView` — this is the "Markers" pack art. Done on
    /// the main thread because it hosts a SwiftUI view; cached by type+size.
    private func milStdSymbol(cotType: String, size: CGFloat) -> UIImage {
        let key = "mil2525|\(cotType)|\(Int(size))"
        if let cached = cached(key) { return cached }
        let view = MilStd2525SymbolView(cotType: cotType, size: size, showLabel: false)
        let img = Self.snapshot(view, size: CGSize(width: size, height: size))
        store(key, img)
        return img
    }

    /// Render a Google-style place pin: a teardrop with a white face and the
    /// token's SF-Symbol glyph. Cached by token+size.
    private func googlePin(_ icon: TAKGoogleIcon, size: CGFloat) -> UIImage {
        let key = "google|\(icon.rawValue)|\(Int(size))"
        if let cached = cached(key) { return cached }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let w = size, h = size
            // Teardrop pin: a circle head with a pointed tail at the bottom.
            let headRadius = w * 0.34
            let headCenter = CGPoint(x: w / 2, y: headRadius + h * 0.06)
            cg.setShadow(offset: CGSize(width: 0, height: size * 0.03),
                         blur: size * 0.06,
                         color: UIColor.black.withAlphaComponent(0.45).cgColor)
            let pin = UIBezierPath()
            pin.addArc(withCenter: headCenter, radius: headRadius,
                       startAngle: .pi * 0.78, endAngle: .pi * 0.22, clockwise: true)
            pin.addLine(to: CGPoint(x: w / 2, y: h * 0.97))
            pin.close()
            icon.tintColor.setFill()
            pin.fill()
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            // White face disc to host the glyph.
            let faceRadius = headRadius * 0.66
            let face = UIBezierPath(arcCenter: headCenter, radius: faceRadius,
                                    startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor.white.setFill()
            face.fill()
            // Glyph centered in the white face.
            let glyphPt = max(8, faceRadius * 1.35)
            let cfg = UIImage.SymbolConfiguration(pointSize: glyphPt, weight: .semibold)
            if let glyph = UIImage(systemName: icon.symbolName, withConfiguration: cfg)?
                .withTintColor(icon.tintColor, renderingMode: .alwaysOriginal) {
                let gw = min(glyph.size.width, faceRadius * 1.5)
                let gh = min(glyph.size.height, faceRadius * 1.5)
                glyph.draw(in: CGRect(x: headCenter.x - gw / 2,
                                      y: headCenter.y - gh / 2,
                                      width: gw, height: gh))
            }
        }
        store(key, img)
        return img
    }

    /// SwiftUI → UIImage on the main thread. Wrapped so a transient render
    /// glitch yields an (empty) image rather than crashing the map.
    private static func snapshot<Content: View>(_ view: Content, size: CGSize) -> UIImage {
        let work: () -> UIImage = {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(origin: .zero, size: size)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
        }
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
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

// MARK: - UIImage scaling helper

private extension UIImage {
    /// Scale (fill) to an exact target size, preserving aspect ratio.
    func scaledToFill(size targetSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            let scale = max(targetSize.width / max(self.size.width, 1),
                            targetSize.height / max(self.size.height, 1))
            let drawSize = CGSize(width: self.size.width * scale,
                                  height: self.size.height * scale)
            let origin = CGPoint(x: (targetSize.width - drawSize.width) / 2,
                                 y: (targetSize.height - drawSize.height) / 2)
            self.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
