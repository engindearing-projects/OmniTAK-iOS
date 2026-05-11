//
//  AtakDeepLinkExtensions.swift
//  OmniTAKMobile
//
//  Adds `/import` and `/preference` subpath support to the existing
//  `tak://com.atakmap.app/<verb>?…` deep-link family. iOS already
//  speaks `/enroll` + the bare connect form via DeepLinkHandler; this
//  file fills in the two remaining ATAK-canonical verbs so QR codes
//  and OpenTAKserver onboarding portals generated for ATAK / iTAK /
//  TAKaware also onboard OmniTAK.
//
//  Mirrors the Android AtakUriParser so both clients consume the same
//  scheme. Pure on its own — handlers live below the parser types.
//

import Foundation
import SwiftUI

// MARK: - Import data package from URL

struct ImportPackageDeepLink {
    let url: URL

    static func parse(url: URL) -> ImportPackageDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let raw = (components.queryItems ?? [])
            .first(where: { $0.name.lowercased() == "url" })?
            .value?
            .trimmingCharacters(in: .whitespaces)
        guard let raw, !raw.isEmpty else { return nil }
        // Only honour http(s) — file:// could exfiltrate sandbox contents
        // through a forged QR.
        let lower = raw.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard let target = URL(string: raw) else { return nil }
        return ImportPackageDeepLink(url: target)
    }
}

// MARK: - Preference write (indexed keyN/typeN/valueN groups)

struct PreferenceEntry {
    let key: String
    let type: String
    let value: String
}

struct PreferenceDeepLink {
    let entries: [PreferenceEntry]

    static func parse(url: URL) -> PreferenceDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let v = item.value { params[item.name.lowercased()] = v }
        }
        var out: [PreferenceEntry] = []
        var i = 1
        while true {
            let keyName = "key\(i)"
            guard let key = params[keyName]?.trimmingCharacters(in: .whitespaces),
                  !key.isEmpty else { break }
            let type = params["type\(i)"]?.lowercased() ?? "string"
            let value = params["value\(i)"] ?? ""
            out.append(PreferenceEntry(key: key, type: type, value: value))
            i += 1
        }
        guard !out.isEmpty else { return nil }
        return PreferenceDeepLink(entries: out)
    }
}

// MARK: - Atak verb router (pure, testable)

enum AtakDeepLinkAction: Equatable {
    case importPackage(URL)
    case setPreferences([String: String]) // resolved key → value, OmniTAK-side
    case unknown

    static func == (lhs: AtakDeepLinkAction, rhs: AtakDeepLinkAction) -> Bool {
        switch (lhs, rhs) {
        case (.importPackage(let a), .importPackage(let b)): return a == b
        case (.setPreferences(let a), .setPreferences(let b)): return a == b
        case (.unknown, .unknown): return true
        default: return false
        }
    }

    /// Returns nil if the URL doesn't carry an `/import` or `/preference`
    /// payload — caller (DeepLinkHandler.handleURL) falls back to its
    /// existing `/enroll` / connect logic.
    static func parse(url: URL) -> AtakDeepLinkAction? {
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch path {
        case "import":
            if let pkg = ImportPackageDeepLink.parse(url: url) {
                return .importPackage(pkg.url)
            }
            return .unknown
        case "preference":
            if let prefs = PreferenceDeepLink.parse(url: url) {
                return .setPreferences(PreferenceApplier.resolve(prefs.entries))
            }
            return .unknown
        default:
            return nil
        }
    }
}

// MARK: - Apply preferences to UserDefaults (mirrors @AppStorage keys)

/// Translates ATAK-flavoured preference entries onto OmniTAK's SwiftUI
/// `@AppStorage` keys. Keep this list in sync with `SettingsView` and
/// `PREFERENCES.md`. Unrecognised keys are dropped so a portal that
/// targets full ATAK can safely push at us.
enum PreferenceApplier {

    static func resolve(_ entries: [PreferenceEntry]) -> [String: String] {
        var out: [String: String] = [:]
        for entry in entries {
            guard let mapped = map(entry) else { continue }
            out[mapped.key] = mapped.value
        }
        return out
    }

    /// Reports which ATAK-side keys produced an OmniTAK pref write and
    /// which were ignored. Used for toast text after the deep link fires.
    static func partition(_ entries: [PreferenceEntry]) -> (applied: [String], ignored: [String]) {
        var applied: [String] = []
        var ignored: [String] = []
        for entry in entries {
            if map(entry) != nil { applied.append(entry.key) } else { ignored.append(entry.key) }
        }
        return (applied, ignored)
    }

    private struct Mapped { let key: String; let value: String }

    /// Map ATAK-flavoured keys onto OmniTAK `@AppStorage` keys, coercing
    /// values into the canonical string form (`"true"` / `"false"` for
    /// booleans, integer strings for `trailMaxLength`). The DeepLink
    /// handler turns those back into the right `UserDefaults` primitive
    /// type at the write boundary.
    private static func map(_ e: PreferenceEntry) -> Mapped? {
        switch e.key {
        case "callsign", "userCallsign", "locationCallsign":
            return Mapped(key: "userCallsign", value: e.value.trimmingCharacters(in: .whitespaces))
        case "userName", "operator":
            return Mapped(key: "userName", value: e.value.trimmingCharacters(in: .whitespaces))
        case "unitSystem", "distanceUnit", "rangeSystem":
            return coerceUnit(e.value).map { Mapped(key: "unitSystem", value: $0) }
        case "coordinateDisplayFormat", "coordFormat", "coord_display_format":
            return coerceCoord(e.value).map { Mapped(key: "coordinateDisplayFormat", value: $0) }
        case "mgrsGridEnabled", "gridEnabled":
            return coerceBool(e.value).map { Mapped(key: "mgrsGridEnabled", value: $0) }
        case "mgrsGridDensity":
            return coerceDensity(e.value).map { Mapped(key: "mgrsGridDensity", value: $0) }
        case "showMGRSLabels":
            return coerceBool(e.value).map { Mapped(key: "showMGRSLabels", value: $0) }
        case "breadcrumbTrailsEnabled":
            return coerceBool(e.value).map { Mapped(key: "breadcrumbTrailsEnabled", value: $0) }
        case "trailMaxLength":
            return Int(e.value).flatMap { 10...500 ~= $0 ? Mapped(key: "trailMaxLength", value: String($0)) : nil }
        case "trailColorName":
            return coerceTrailColor(e.value).map { Mapped(key: "trailColorName", value: $0) }
        case "appMode":
            return coerceAppMode(e.value).map { Mapped(key: "appMode", value: $0) }
        default:
            return nil
        }
    }

    private static func coerceBool(_ v: String) -> String? {
        switch v.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes", "on": return "true"
        case "false", "0", "no", "off": return "false"
        default: return nil
        }
    }

    private static func coerceUnit(_ v: String) -> String? {
        switch v.trimmingCharacters(in: .whitespaces).lowercased() {
        case "metric": return "Metric"
        case "imperial": return "Imperial"
        default: return nil
        }
    }

    private static let COORD_VALUES: Set<String> = ["DD", "DM", "DMS", "MGRS", "UTM", "BNG"]
    private static func coerceCoord(_ v: String) -> String? {
        let upper = v.trimmingCharacters(in: .whitespaces).uppercased()
        return COORD_VALUES.contains(upper) ? upper : nil
    }

    private static let DENSITY_VALUES: Set<String> = ["100km", "10km", "1km"]
    private static func coerceDensity(_ v: String) -> String? {
        let lower = v.trimmingCharacters(in: .whitespaces).lowercased()
        return DENSITY_VALUES.contains(lower) ? lower : nil
    }

    private static let TRAIL_COLORS: Set<String> = ["cyan", "green", "orange", "red", "blue"]
    private static func coerceTrailColor(_ v: String) -> String? {
        let lower = v.trimmingCharacters(in: .whitespaces).lowercased()
        return TRAIL_COLORS.contains(lower) ? lower : nil
    }

    private static let APP_MODES: Set<String> = ["tactical", "fire_rescue", "sar", "civilian"]
    private static func coerceAppMode(_ v: String) -> String? {
        let lower = v.trimmingCharacters(in: .whitespaces).lowercased()
        return APP_MODES.contains(lower) ? lower : nil
    }
}
