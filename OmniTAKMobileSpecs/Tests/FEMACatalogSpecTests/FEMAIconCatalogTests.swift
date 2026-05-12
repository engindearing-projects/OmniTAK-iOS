//
//  FEMAIconCatalogTests.swift
//  FEMACatalogSpecTests
//
//  TDD spec for the FEMA / Incident Command icon catalog used by the
//  SAR / disaster-response marker palette (closes #13).
//
//  These tests intentionally live in a standalone SwiftPM package because
//  OmniTAKMobile.xcodeproj has no `OmniTAKMobileTests` PBXNativeTarget yet
//  — see OmniTAKMobileTests/README.md. The catalog source is mirrored into
//  the app target as `OmniTAKMobile/Shared/Services/FEMAIconCatalog.swift`.
//
import XCTest
@testable import FEMACatalogSpec

final class FEMAIconCatalogTests: XCTestCase {

    // MARK: - Catalog presence

    func test_catalog_categories_isNotEmpty() {
        XCTAssertFalse(FEMAIconCatalog.allCategories.isEmpty,
                       "catalog must publish at least one FEMA / IC category")
    }

    func test_catalog_includesCoreSARCategories() {
        // K9Blue feedback: IC, medical, helicopter LZ, vehicles, support stations.
        let required: Set<FEMAIconCatalog.Category> = [
            .incidentCommand,
            .medical,
            .aviation,
            .vehicles,
            .support,
        ]
        let present = Set(FEMAIconCatalog.allCategories)
        for cat in required {
            XCTAssertTrue(present.contains(cat),
                          "missing required SAR/FEMA category: \(cat.rawValue)")
        }
    }

    // MARK: - Individual icon lookup

    func test_commandPost_icon_isResolvable() {
        let icon = FEMAIconCatalog.icon(for: .commandPost)
        XCTAssertNotNil(icon, "Command Post icon must be in the catalog")
        XCTAssertFalse(icon!.symbolName.isEmpty,
                       "icon must have a non-empty SF Symbol name")
        XCTAssertEqual(icon!.category, .incidentCommand)
    }

    func test_helicopterLZ_icon_isResolvable_andUsesAviationSymbol() {
        let icon = FEMAIconCatalog.icon(for: .helicopterLZ)
        XCTAssertNotNil(icon)
        XCTAssertEqual(icon!.category, .aviation)
        // SF Symbol should at least mention "helicopter" — we don't pin the
        // exact glyph because Apple renames them occasionally.
        XCTAssertTrue(icon!.symbolName.lowercased().contains("helicopter"),
                      "expected a helicopter-themed SF Symbol, got \(icon!.symbolName)")
    }

    func test_triageStation_icon_isResolvable_andUsesMedicalCategory() {
        let icon = FEMAIconCatalog.icon(for: .triageStation)
        XCTAssertNotNil(icon)
        XCTAssertEqual(icon!.category, .medical)
    }

    func test_baseCamp_icon_isResolvable_andUsesSupportCategory() {
        let icon = FEMAIconCatalog.icon(for: .baseCamp)
        XCTAssertNotNil(icon)
        XCTAssertEqual(icon!.category, .support)
    }

    func test_allIconKinds_haveResolvableEntries() {
        for kind in FEMAIconCatalog.Kind.allCases {
            XCTAssertNotNil(FEMAIconCatalog.icon(for: kind),
                            "catalog missing entry for kind: \(kind.rawValue)")
        }
    }

    // MARK: - Category grouping

    func test_iconsByCategory_groupsEveryKindUnderItsCategory() {
        for kind in FEMAIconCatalog.Kind.allCases {
            guard let icon = FEMAIconCatalog.icon(for: kind) else {
                XCTFail("no icon for \(kind.rawValue)")
                continue
            }
            let group = FEMAIconCatalog.icons(in: icon.category)
            XCTAssertTrue(group.contains(where: { $0.kind == kind }),
                          "icon \(kind.rawValue) missing from category \(icon.category.rawValue)")
        }
    }

    // MARK: - CoT round-trip mapping

    func test_cotType_friendlyAffiliation_prefix() {
        // Per #13: round-trip over CoT with a type ATAK/iTAK can render.
        // FEMA/IC markers are friendly civil-response installations, so they
        // should use a-f-G-I-* (Friendly Ground Installation) as the canonical
        // prefix and rely on usericon iconsetpath for the FEMA glyph.
        let icon = FEMAIconCatalog.icon(for: .commandPost)!
        XCTAssertTrue(icon.cotType.hasPrefix("a-f-G-"),
                      "FEMA marker CoT type must be friendly ground; got \(icon.cotType)")
    }

    func test_cotType_isStableAcrossLookups() {
        let a = FEMAIconCatalog.icon(for: .helicopterLZ)!.cotType
        let b = FEMAIconCatalog.icon(for: .helicopterLZ)!.cotType
        XCTAssertEqual(a, b)
    }

    func test_iconsetpath_isFEMAFlavored() {
        // ATAK iconsetpath convention: "COT_MAPPING_<set>/<group>/<icon>".
        // We mint our own "COT_MAPPING_FEMA/<kind>" namespace so receivers
        // can choose to render the icon or fall through to the affiliation
        // fallback if they don't ship the FEMA set yet.
        for kind in FEMAIconCatalog.Kind.allCases {
            let icon = FEMAIconCatalog.icon(for: kind)!
            XCTAssertTrue(icon.iconsetPath.hasPrefix("COT_MAPPING_FEMA/"),
                          "iconsetpath should be FEMA-namespaced, got \(icon.iconsetPath)")
        }
    }

    func test_kindFromCoTType_roundTrip_recoversSameKind() {
        // Round-trip: catalog -> cotType -> kind should be lossless for all
        // kinds. This is the key contract from #13 ("round-trips over CoT").
        for kind in FEMAIconCatalog.Kind.allCases {
            let icon = FEMAIconCatalog.icon(for: kind)!
            let recovered = FEMAIconCatalog.kind(forCoTType: icon.cotType,
                                                 iconsetPath: icon.iconsetPath)
            XCTAssertEqual(recovered, kind,
                           "round-trip failed for \(kind.rawValue): cotType=\(icon.cotType) iconsetPath=\(icon.iconsetPath)")
        }
    }
}
