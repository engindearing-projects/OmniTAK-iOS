//
//  IconData.swift  (OmniTAK adaptation)
//
//  Adapted from flighttactics/TAKAware (Apache-2.0).
//  Upstream: https://github.com/flighttactics/TAKAware
//  Source: TAKAware/Data Models/IconData.swift (Cory Foy, 2024)
//
//  This file vendors only the pure-Swift, dependency-free helpers that
//  OmniTAK needs for MIL-STD-2525 affiliation rendering and ATAK team
//  color mapping. The original ships with SQLite, SwiftTAK, and a full
//  iconset cache layer; we deliberately leave those out.
//
//  Adapted helpers:
//    - mil2525FromCotType(cotType:)    — CoT type → SIDC resolver
//    - milStdIconWithName(name:)       — pad SIDC to 15-char SIDC string
//    - colorForTeam(_:)                — ATAK team filter colour table
//    - staticIconNameFromCotType(_:)   — fallback icon names for non-2525 CoT
//
//  Anything depending on Connection, SwiftTAK, or filesystem state
//  was dropped. Do not edit upstream copyright headers in this file.
//

import Foundation
import UIKit

/// Pure-Swift helpers ported from TAKAware's IconData class.
///
/// The original class is a stateful icon registry; this struct is a
/// namespace for the static, dependency-free utility functions.
enum TAKAwareIconData {

    /// ATAK / WinTAK team filter colours (the same hex values shipped
    /// with `team_filters.xml` in `AndroidTacticalAssaultKit-CIV`).
    /// Used by Engie team breadcrumbs and the onboarding swatch grid.
    static func colorForTeam(_ team: String) -> UIColor {
        switch team {
        case "White":      return .white
        case "Yellow":     return .yellow
        case "Magenta":    return .magenta
        case "Red":        return .red
        case "Blue":       return .blue
        case "Cyan":       return .cyan
        case "Green":      return .green
        case "Orange":     return UIColor(red: 1.000, green: 0.467, blue: 0.000, alpha: 1.0)
        case "Maroon":     return UIColor(red: 0.498, green: 0.000, blue: 0.000, alpha: 1.0)
        case "Purple":     return UIColor(red: 0.498, green: 0.000, blue: 0.498, alpha: 1.0)
        case "Dark Blue":  return UIColor(red: 0.000, green: 0.000, blue: 0.498, alpha: 1.0)
        case "Teal":       return UIColor(red: 0.000, green: 0.498, blue: 0.498, alpha: 1.0)
        case "Dark Green": return UIColor(red: 0.000, green: 0.498, blue: 0.000, alpha: 1.0)
        case "Brown":      return UIColor(red: 0.627, green: 0.443, blue: 0.310, alpha: 1.0)
        default:           return .white
        }
    }

    /// MIL-STD-2525 SIDC strings are 15 characters, dash-padded.
    static func milStdIconWithName(_ name: String) -> String {
        name.padding(toLength: 15, withPad: "-", startingAt: 0)
    }

    /// Resolve a CoT type ("a-h-G-U-C-I", "a-f-G", "a-u-A-M-F", …) to a
    /// 15-char SIDC ("SHGPUCI--------"). Adapted from
    /// `Icon2525cTypeResolver.java` upstream.
    ///
    /// Falls back to "su" (unknown affiliation) when the input doesn't
    /// look like a CoT atom (must start with "a-"). The OmniTAK iconset
    /// loader uses the trailing dashes as wildcards.
    static func mil2525FromCotType(_ cotType: String) -> String {
        guard cotType.count > 2, cotType.first == "a" else { return "" }

        var s2525C = ""
        let checkIndex = cotType.index(cotType.startIndex, offsetBy: 2)

        switch cotType[checkIndex].lowercased() {
        case "f", "a":             s2525C = "sf"   // friendly / assumed-friend
        case "n":                  s2525C = "sn"   // neutral
        case "s", "j", "k", "h":   s2525C = "sh"   // hostile / suspect / joker / faker
        case "u":                  s2525C = "su"   // unknown
        default:                   s2525C = "su"
        }

        var cotChars = Array(cotType)
        for pos in stride(from: 4, to: cotType.count, by: 2) where pos < cotChars.count {
            s2525C.append(cotChars[pos].lowercased())
            if pos == 4 { s2525C.append("p") } // present
        }

        cotChars = Array(s2525C)
        for pos in s2525C.count..<15 {
            if pos == 10, cotChars.count >= 5, cotChars[2] == "g", cotChars[4] == "i" {
                s2525C.append("h") // ground/installation glyph slot
            } else {
                s2525C.append("-")
            }
        }
        return s2525C
    }

    /// Static (non-2525) fallback icon names for misc CoT subtypes
    /// (waypoints, contact points, bullseyes, etc.). The actual asset
    /// lookup is left to the caller.
    static func staticIconNameFromCotType(_ cotType: String) -> String {
        guard cotType.count > 2, ["b", "u"].contains(cotType.first) else { return "" }

        switch cotType {
        case "b-m-p-i":           return "piicon"
        case "b-m-p-c-cp":        return "piicon_contact"
        case "b-m-p-c-ip":        return "piicon_initial"
        case "b-m-p-c":           return "piicon"
        case "b-m-p-w-GOTO":      return "pointtype_waypoint_default"
        case "b-m-p-w":           return "generic"
        case "b-i-x-i":            return "camera"
        case "b-d":                return "nav_alert"
        case "u-r-b-bullseye":    return "bullseye"
        case "b-m-p-s-p-loc":     return "sensor_location"
        case "b-m-p-s-p-op":      return "binos"
        default:                   return ""
        }
    }

    /// Decode an `aabbggrr` KML colour string to an ARGB Int (matches
    /// the upstream signature so future KML/KMZ ingest can call it).
    static func colorFromKMLColor(_ kmlColor: String) -> Int {
        let hex = kmlColor.replacingOccurrences(of: "#", with: "")
        guard hex.count == 8,
              let a = Int(hex.prefix(2), radix: 16),
              let b = Int(hex.dropFirst(2).prefix(2), radix: 16),
              let g = Int(hex.dropFirst(4).prefix(2), radix: 16),
              let r = Int(hex.suffix(2), radix: 16)
        else { return 0 }
        return (a << 24) | (r << 16) | (g << 8) | b
    }
}
