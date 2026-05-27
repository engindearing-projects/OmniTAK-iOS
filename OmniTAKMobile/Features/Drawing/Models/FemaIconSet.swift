//
//  FemaIconSet.swift
//  OmniTAKMobile
//
//  FEMA / Incident Command (IC) symbology stand-in for issue #13 MVP.
//
//  MVP NOTE: This ships SF Symbols as a stand-in renderer because we do not
//  bundle the real FEMA ICS-237 sprite set yet. The IDEA of the feature —
//  "operator picks a fire/medical/LZ/etc. icon and drops it on the map" —
//  works end-to-end here. The PIXELS that ATAK draws on the receiving side
//  depend on whether ATAK has the matching `type` code (or a registered icon
//  set) in its symbol map.
//
//  CoT TYPE STRINGS:
//  TAK / ATAK doesn't define a canonical "FEMA marker" type code the way it
//  does for the four MIL-2525 affiliations (a-f/a-h/a-n/a-u). The strings
//  below are HONEST GUESSES anchored to:
//    - `b-m-p-...`  — generic "marker / point" branch
//    - `b-r-f-h-...` — "request / fire / hazard" branch ATAK uses for fire
//    - Friendly emergency-services style codes that some servers route off
//      `a-f-G-E-V-...` (Friendly Ground Equipment Vehicle …) for ambulances
//      and engines.
//  If ATAK doesn't know the exact code it falls back to a generic dot in the
//  receiver's affiliation color, which is still "something reasonable" for
//  the MVP receipt. Real ICS-237 parity is a follow-up that needs the asset
//  bundle + an ATAK plugin / icon-set definition on the server.
//

import Foundation
import SwiftUI

// MARK: - FEMA Icon

/// A small fixed set of FEMA / Incident Command marker types. These render
/// with SF Symbols today and are intended to be swapped for real FEMA ICS-237
/// sprites once those assets are available.
enum FemaIcon: String, CaseIterable, Codable, Identifiable {
    case fire
    case medical
    case lawEnforcement
    case helicopterLZ
    case shelter
    case commandPost

    var id: String { rawValue }

    /// SF Symbol stand-in. Swap for a UIImage asset when real FEMA sprites land.
    var sfSymbolName: String {
        switch self {
        case .fire:           return "flame.fill"
        case .medical:        return "cross.case.fill"
        case .lawEnforcement: return "shield.lefthalf.filled"
        case .helicopterLZ:   return "helicopter.fill"
        case .shelter:        return "house.fill"
        case .commandPost:    return "flag.fill"
        }
    }

    /// CoT type string. See file header — these are best-effort, not canonical.
    /// Receivers without a matching icon will fall back to a generic dot.
    var cotType: String {
        switch self {
        case .fire:           return "b-r-f-h-c"        // Fire / hazard / request
        case .medical:        return "a-f-G-E-V-A"      // Friendly ground vehicle - ambulance
        case .lawEnforcement: return "a-f-G-U-C-I-E"    // Friendly ground combat - law enforcement
        case .helicopterLZ:   return "b-m-p-w-GOTO"     // Waypoint / LZ
        case .shelter:        return "a-f-G-I-U-T"      // Friendly ground installation - utility
        case .commandPost:    return "a-f-G-U-h"        // Friendly ground unit - HQ / command
        }
    }

    var displayName: String {
        switch self {
        case .fire:           return "Fire"
        case .medical:        return "Medical"
        case .lawEnforcement: return "Law Enforcement"
        case .helicopterLZ:   return "Helo LZ"
        case .shelter:        return "Shelter"
        case .commandPost:    return "Command Post"
        }
    }

    /// Short code used for badges, name auto-gen, and filter chips.
    var shortCode: String {
        switch self {
        case .fire:           return "FIRE"
        case .medical:        return "MED"
        case .lawEnforcement: return "LE"
        case .helicopterLZ:   return "LZ"
        case .shelter:        return "SHEL"
        case .commandPost:    return "CP"
        }
    }

    var tintColor: Color {
        switch self {
        case .fire:           return .red
        case .medical:        return .pink
        case .lawEnforcement: return .blue
        case .helicopterLZ:   return .yellow
        case .shelter:        return .green
        case .commandPost:    return .purple
        }
    }

    var uiTintColor: UIColor {
        switch self {
        case .fire:           return .systemRed
        case .medical:        return .systemPink
        case .lawEnforcement: return .systemBlue
        case .helicopterLZ:   return .systemYellow
        case .shelter:        return .systemGreen
        case .commandPost:    return .systemPurple
        }
    }

    // MARK: - CoT round-trip

    /// Try to reconstruct a `FemaIcon` from a CoT type string.
    /// Used by the receiver path so an incoming marker we previously sent
    /// (or anyone else sent with the same code) renders with the FEMA icon
    /// instead of falling through to MIL-2525 affiliation rendering.
    static func from(cotType: String) -> FemaIcon? {
        return FemaIcon.allCases.first { $0.cotType == cotType }
    }
}
