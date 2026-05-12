//
//  FEMAIconCatalog.swift
//  OmniTAKMobile
//
//  FEMA / Incident Command symbology catalog used by the SAR / disaster
//  response marker palette (closes GitHub #13).
//
//  Why this exists
//  ---------------
//  K9Blue SAR feedback (5/10/26): pre-planned and hasty searches both need
//  IC / medical / LZ / vehicle / support-station markers, and MIL-STD-2525
//  symbols aren't the right vocabulary for civil disaster response.
//
//  CoT type convention
//  -------------------
//  FEMA / ICS markers don't have a canonical MIL-STD-2525 unit type, so we
//  emit them as friendly ground installations (`a-f-G-I-*`) and rely on the
//  `<usericon iconsetpath="COT_MAPPING_FEMA/...">` detail extension to carry
//  the FEMA glyph. Receivers that don't ship the FEMA set still get a
//  plausible friendly-installation fallback rendered by ATAK/iTAK.
//
//  References:
//    * NIMS / ICS-237 Resource Typing — symbology categories used here
//    * TAK ATAK-CIV iconsetpath convention (COT_MAPPING_<SET>/<group>/<icon>)
//
//  Spec mirror: OmniTAKMobileSpecs/Sources/FEMACatalogSpec/FEMAIconCatalog.swift
//
import Foundation
import SwiftUI

enum FEMAIconCatalog {

    // MARK: - Category

    /// SAR / incident-command grouping shown as palette sections.
    enum Category: String, CaseIterable, Hashable {
        case incidentCommand
        case medical
        case aviation
        case vehicles
        case support

        var displayName: String {
            switch self {
            case .incidentCommand: return "Command"
            case .medical:         return "Medical"
            case .aviation:        return "Aviation"
            case .vehicles:        return "Vehicles"
            case .support:         return "Support"
            }
        }

        /// Tint applied behind the SF symbol so categories are visually
        /// distinguishable on the palette without grey backplates (per
        /// feedback_radial_menu_no_backdrop — icons stay floaty on map).
        var accentColor: Color {
            switch self {
            case .incidentCommand: return .orange
            case .medical:         return .red
            case .aviation:        return .cyan
            case .vehicles:        return .yellow
            case .support:         return .green
            }
        }
    }

    // MARK: - Kind

    /// Individual FEMA / IC icons. Stable raw values — embedded in CoT
    /// iconsetpath so we don't break round-trips when we add more.
    enum Kind: String, CaseIterable, Hashable {
        case commandPost        = "command_post"
        case stagingArea        = "staging_area"
        case triageStation      = "triage_station"
        case medicalSupply      = "medical_supply"
        case helicopterLZ       = "helicopter_lz"
        case fireTruck          = "fire_truck"
        case ambulance          = "ambulance"
        case searchTeam         = "search_team"
        case baseCamp           = "base_camp"
        case foodWater          = "food_water"
        case generator          = "generator"
        case communicationsHub  = "communications_hub"
    }

    // MARK: - FEMAIcon

    struct FEMAIcon: Equatable, Identifiable {
        let kind: Kind
        let category: Category
        let label: String
        /// SF Symbol glyph. We deliberately use SF Symbols as scaffolding
        /// until proper FEMA artwork is licensed/drawn — see issue #13.
        let symbolName: String
        /// CoT `type` attribute on the emitted event.
        let cotType: String
        /// Value for `<usericon iconsetpath="...">` so peers can render
        /// the FEMA glyph if they have the icon set installed.
        let iconsetPath: String

        var id: Kind { kind }
    }

    // MARK: - Catalog

    private static let entries: [Kind: FEMAIcon] = {
        func make(_ kind: Kind,
                  _ category: Category,
                  _ label: String,
                  _ symbol: String,
                  _ cot: String) -> (Kind, FEMAIcon) {
            return (kind, FEMAIcon(
                kind: kind,
                category: category,
                label: label,
                symbolName: symbol,
                cotType: cot,
                iconsetPath: "COT_MAPPING_FEMA/\(category.rawValue)/\(kind.rawValue)"
            ))
        }

        let all: [(Kind, FEMAIcon)] = [
            // --- Incident Command ---
            make(.commandPost,       .incidentCommand, "Command Post",
                 "flag.checkered",                "a-f-G-I-U-T"),
            make(.stagingArea,       .incidentCommand, "Staging Area",
                 "rectangle.stack.fill",          "a-f-G-I-B-A"),

            // --- Medical ---
            make(.triageStation,     .medical,         "Triage Station",
                 "cross.case.fill",               "a-f-G-I-M-T"),
            make(.medicalSupply,     .medical,         "Medical Supply",
                 "cross.vial.fill",               "a-f-G-I-M-S"),

            // --- Aviation ---
            make(.helicopterLZ,      .aviation,        "Helicopter LZ",
                 "helicopter",                    "a-f-G-I-X-H"),

            // --- Vehicles ---
            make(.fireTruck,         .vehicles,        "Fire Engine",
                 "flame.fill",                    "a-f-G-E-V-F-R"),
            make(.ambulance,         .vehicles,        "Ambulance",
                 "cross.circle.fill",             "a-f-G-E-V-M-A"),
            make(.searchTeam,        .vehicles,        "Search Team",
                 "figure.2.and.child.holdinghands","a-f-G-U-U-S"),

            // --- Support ---
            make(.baseCamp,          .support,         "Base Camp",
                 "tent.fill",                     "a-f-G-I-B-C"),
            make(.foodWater,         .support,         "Food / Water",
                 "fork.knife",                    "a-f-G-I-B-F"),
            make(.generator,         .support,         "Generator",
                 "bolt.fill",                     "a-f-G-I-U-E"),
            make(.communicationsHub, .support,         "Comms Hub",
                 "antenna.radiowaves.left.and.right",
                 "a-f-G-I-U-C"),
        ]

        return Dictionary(uniqueKeysWithValues: all)
    }()

    // MARK: - Lookup

    static var allCategories: [Category] {
        Category.allCases.filter { cat in
            entries.values.contains(where: { $0.category == cat })
        }
    }

    static func icon(for kind: Kind) -> FEMAIcon? {
        entries[kind]
    }

    static func icons(in category: Category) -> [FEMAIcon] {
        let kindOrder = Kind.allCases.enumerated().reduce(into: [Kind: Int]()) {
            $0[$1.element] = $1.offset
        }
        return entries.values
            .filter { $0.category == category }
            .sorted { (kindOrder[$0.kind] ?? 0) < (kindOrder[$1.kind] ?? 0) }
    }

    /// Recover a `Kind` from an incoming CoT event. Round-trips with what we
    /// emit. Preference order:
    ///   1. iconsetPath match on `COT_MAPPING_FEMA/<cat>/<kind>`
    ///   2. cotType exact match (last-resort; some kinds may share types)
    static func kind(forCoTType cotType: String, iconsetPath: String) -> Kind? {
        let prefix = "COT_MAPPING_FEMA/"
        if iconsetPath.hasPrefix(prefix) {
            let suffix = iconsetPath.dropFirst(prefix.count)
            if let slash = suffix.lastIndex(of: "/") {
                let kindRaw = String(suffix[suffix.index(after: slash)...])
                if let kind = Kind(rawValue: kindRaw) {
                    return kind
                }
            }
        }
        let matches = entries.values.filter { $0.cotType == cotType }
        if matches.count == 1 {
            return matches.first?.kind
        }
        return nil
    }
}
