//
//  IconsetPackParserTests.swift
//  OmniTAKMobileTests
//
//  Issue #75 Phase 2 — unit tests for IconsetPackParser, the pure-Swift
//  parser for ATAK's `iconset.xml` format.
//
//  ATAK iconset.xml structure:
//
//  ```xml
//  <?xml version="1.0" encoding="UTF-8"?>
//  <iconset uid="abc-123" defaultFriendlyGroup="…" defaultHostileGroup="…"
//           defaultNeutralGroup="…" defaultUnknownGroup="…" name="My Pack"
//           skipResize="false" version="1">
//    <icon name="Ambulance" filename="Ground/Ambulance.png"/>
//    <icon name="Police Car" filename="Ground/PoliceCar.png"/>
//  </iconset>
//  ```
//
//  The parser is the core unit-testable contract — all path/name logic lives
//  here with zero UIKit dependencies. Bitmap loading is handled separately by
//  IconPackRegistry (needs real files on disk, covered on-device).
//

import XCTest
@testable import OmniTAK

final class IconsetPackParserTests: XCTestCase {

    // MARK: - Well-formed iconset.xml fixtures

    private let minimalXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <iconset uid="test-uid-001" name="Test Pack" version="1">
          <icon name="Ambulance" filename="Ground/Ambulance.png"/>
          <icon name="Police Car" filename="Ground/PoliceCar.png"/>
        </iconset>
        """

    private let fullAtakXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <iconset uid="f47ac10b-58cc-4372-a567-0e02b2c3d479"
                 defaultFriendlyGroup="Ground"
                 defaultHostileGroup="Ground"
                 defaultNeutralGroup="Ground"
                 defaultUnknownGroup="Ground"
                 name="ATAK Military"
                 skipResize="false"
                 version="1">
          <icon name="Ambulance"     filename="Ground/Ambulance.png"/>
          <icon name="Police Car"    filename="Ground/PoliceCar.png"/>
          <icon name="Helicopter"    filename="Air/Helicopter.png"/>
          <icon name="Infantry"      filename="Ground/Infantry.png"/>
          <icon name="Armored"       filename="Ground/Armored.png"/>
        </iconset>
        """

    /// ATAK sometimes nests icons under a `<group>` element.
    private let groupedXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <iconset uid="grouped-uid" name="Grouped Pack" version="1">
          <group name="Ground">
            <icon name="Tank" filename="Ground/Tank.png"/>
            <icon name="Jeep" filename="Ground/Jeep.png"/>
          </group>
          <group name="Air">
            <icon name="Drone" filename="Air/Drone.png"/>
          </group>
          <icon name="Unknown" filename="Unknown.png"/>
        </iconset>
        """

    // MARK: - Basic attribute parsing

    func testParseMinimalIconsetReturnsCorrectUID() {
        let result = IconsetPackParser.parse(minimalXml)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.uid, "test-uid-001")
    }

    func testParseMinimalIconsetReturnsCorrectName() {
        let result = IconsetPackParser.parse(minimalXml)
        XCTAssertEqual(result?.name, "Test Pack")
    }

    func testParseFullAtakIconsetUID() {
        let result = IconsetPackParser.parse(fullAtakXml)
        XCTAssertEqual(result?.uid, "f47ac10b-58cc-4372-a567-0e02b2c3d479")
    }

    func testParseFullAtakIconsetName() {
        let result = IconsetPackParser.parse(fullAtakXml)
        XCTAssertEqual(result?.name, "ATAK Military")
    }

    func testParseVersionAttributeCaptured() {
        let result = IconsetPackParser.parse(fullAtakXml)
        XCTAssertEqual(result?.version, 1)
    }

    func testParseVersionDefaultsToOneWhenAbsent() {
        let xml = """
            <?xml version="1.0"?>
            <iconset uid="v-uid" name="NoVersion">
              <icon name="X" filename="x.png"/>
            </iconset>
            """
        XCTAssertEqual(IconsetPackParser.parse(xml)?.version, 1)
    }

    // MARK: - Flat icon entry parsing

    func testParseMinimalXmlReturnsAllIconEntries() {
        let result = IconsetPackParser.parse(minimalXml)
        XCTAssertEqual(result?.icons.count, 2)
    }

    func testParseIconNameAndFilenameAreCorrect() {
        let result = IconsetPackParser.parse(minimalXml)!
        let ambulance = result.icons.first { $0.name == "Ambulance" }
        XCTAssertEqual(ambulance?.filename, "Ground/Ambulance.png")
    }

    func testParseFullAtakXmlReturnsFiveIcons() {
        let result = IconsetPackParser.parse(fullAtakXml)!
        XCTAssertEqual(result.icons.count, 5)
    }

    func testEveryIconInFullXmlHasNonEmptyFilename() {
        let result = IconsetPackParser.parse(fullAtakXml)!
        for icon in result.icons {
            XCTAssertFalse(icon.filename.isEmpty,
                           "icon '\(icon.name)' has empty filename")
        }
    }

    // MARK: - Grouped icon support

    func testGroupedIconsetFlattensIconsFromAllGroups() {
        let result = IconsetPackParser.parse(groupedXml)!
        // 2 (Ground) + 1 (Air) + 1 (top-level) = 4 total
        XCTAssertEqual(result.icons.count, 4)
    }

    func testIconFilenamesFromGroupedXmlAreAuthored() {
        let result = IconsetPackParser.parse(groupedXml)!
        let filenames = Set(result.icons.map { $0.filename })
        XCTAssertTrue(filenames.contains("Ground/Tank.png"))
        XCTAssertTrue(filenames.contains("Air/Drone.png"))
        XCTAssertTrue(filenames.contains("Unknown.png"))
    }

    // MARK: - Icon lookup by name

    func testIconByNameExactMatch() {
        let pack = IconsetPackParser.parse(fullAtakXml)!
        let icon = pack.iconByName("Ambulance")
        XCTAssertNotNil(icon)
        XCTAssertEqual(icon?.filename, "Ground/Ambulance.png")
    }

    func testIconByNameReturnsNilForUnknownName() {
        let pack = IconsetPackParser.parse(fullAtakXml)!
        XCTAssertNil(pack.iconByName("SpaceShip"))
    }

    func testIconByNameInsensitiveResolvesCaseInsensitively() {
        let pack = IconsetPackParser.parse(fullAtakXml)!
        XCTAssertNotNil(pack.iconByNameInsensitive("ambulance"))
        XCTAssertNotNil(pack.iconByNameInsensitive("HELICOPTER"))
    }

    // MARK: - iconsetPath resolution (ATAK wire format)
    //
    // ATAK `usericon iconsetpath` for custom packs:
    //   "<uid>/<filename-no-extension>"  e.g. "f47ac10b-…/Ground/Ambulance"
    // or sometimes basename only: "f47ac10b-…/Ambulance"
    // We resolve both so inbound CoT from ATAK peers works.

    func testIconByIconsetPathResolvesFullPathWithSubdirectory() {
        let pack = IconsetPackParser.parse(fullAtakXml)!
        let icon = pack.iconByIconsetPath(
            "f47ac10b-58cc-4372-a567-0e02b2c3d479/Ground/Ambulance")
        XCTAssertNotNil(icon)
        XCTAssertEqual(icon?.filename, "Ground/Ambulance.png")
    }

    func testIconByIconsetPathResolvesPathWithPngExtension() {
        let pack = IconsetPackParser.parse(fullAtakXml)!
        let icon = pack.iconByIconsetPath(
            "f47ac10b-58cc-4372-a567-0e02b2c3d479/Ground/Ambulance.png")
        XCTAssertNotNil(icon)
        XCTAssertEqual(icon?.filename, "Ground/Ambulance.png")
    }

    func testIconByIconsetPathResolvesBasenameOnly() {
        let pack = IconsetPackParser.parse(minimalXml)!
        let icon = pack.iconByIconsetPath("test-uid-001/Ambulance")
        XCTAssertNotNil(icon)
    }

    func testIconByIconsetPathReturnsNilWhenUIDDoesNotMatch() {
        let pack = IconsetPackParser.parse(minimalXml)!
        XCTAssertNil(pack.iconByIconsetPath("wrong-uid/Ambulance"))
    }

    func testIconByIconsetPathReturnsNilForUnknownTokenInCorrectUID() {
        let pack = IconsetPackParser.parse(minimalXml)!
        XCTAssertNil(pack.iconByIconsetPath("test-uid-001/SpaceShip"))
    }

    // MARK: - iconsetpath generation

    func testIconsetPathForIconMatchesATAKCanonicalForm() {
        let pack = IconsetPackParser.parse(fullAtakXml)!
        let icon = pack.icons.first { $0.name == "Ambulance" }!
        let expected = "f47ac10b-58cc-4372-a567-0e02b2c3d479/Ground/Ambulance"
        XCTAssertEqual(pack.iconsetPath(for: icon), expected)
    }

    func testIconsetPathRoundTripsThroughResolver() {
        let pack = IconsetPackParser.parse(fullAtakXml)!
        for icon in pack.icons {
            let path = pack.iconsetPath(for: icon)
            let resolved = pack.iconByIconsetPath(path)
            XCTAssertNotNil(resolved,
                            "iconsetPath '\(path)' failed to resolve back")
            XCTAssertEqual(resolved?.filename, icon.filename)
        }
    }

    // MARK: - Malformed input handling

    func testParseReturnsNilForCompletelyEmptyString() {
        XCTAssertNil(IconsetPackParser.parse(""))
    }

    func testParseReturnsNilForNonXMLGarbage() {
        XCTAssertNil(IconsetPackParser.parse("this is not xml at all }{]["))
    }

    func testParseReturnsNilWhenIconsetElementIsMissing() {
        let xml = """
            <?xml version="1.0"?>
            <root><something/></root>
            """
        XCTAssertNil(IconsetPackParser.parse(xml))
    }

    func testParseReturnsNilWhenUIDAttributeIsMissing() {
        let xml = """
            <?xml version="1.0"?>
            <iconset name="No UID Pack" version="1">
              <icon name="X" filename="x.png"/>
            </iconset>
            """
        XCTAssertNil(IconsetPackParser.parse(xml))
    }

    func testParseToleratesMissingNameAttributeAndUsesUIDFallback() {
        let xml = """
            <?xml version="1.0"?>
            <iconset uid="no-name-uid" version="1">
              <icon name="X" filename="x.png"/>
            </iconset>
            """
        let result = IconsetPackParser.parse(xml)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "no-name-uid")
    }

    func testParseWithZeroIconsReturnsEmptyListNotNil() {
        let xml = """
            <?xml version="1.0"?>
            <iconset uid="empty-uid" name="Empty Pack" version="1">
            </iconset>
            """
        let result = IconsetPackParser.parse(xml)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.icons.isEmpty == true)
    }

    func testParseSkipsIconEntriesWithMissingFilename() {
        let xml = """
            <?xml version="1.0"?>
            <iconset uid="partial-uid" name="Partial" version="1">
              <icon name="Good" filename="good.png"/>
              <icon name="Bad"/>
            </iconset>
            """
        let result = IconsetPackParser.parse(xml)!
        XCTAssertEqual(result.icons.count, 1)
        XCTAssertEqual(result.icons.first?.filename, "good.png")
    }

    func testParseSkipsIconEntriesWithMissingNameAttribute() {
        let xml = """
            <?xml version="1.0"?>
            <iconset uid="partial-uid-2" name="Partial2" version="1">
              <icon name="Good" filename="good.png"/>
              <icon filename="noname.png"/>
            </iconset>
            """
        let result = IconsetPackParser.parse(xml)!
        XCTAssertEqual(result.icons.count, 1)
    }

    // MARK: - IconPackRegistry integration sanity

    func testImportedPackIconsetPathStructureIsCorrect() {
        // Verify the generated iconsetpath has the right uid prefix and
        // contains the token — this is the contract TAKIconRegistry checks
        // when deciding to call IconPackRegistry.handles(_:).
        let pack = IconsetPackParser.parse(fullAtakXml)!
        let icon = pack.icons.first { $0.name == "Ambulance" }!
        let path = pack.iconsetPath(for: icon)

        XCTAssertTrue(path.hasPrefix(pack.uid),
                      "iconsetPath must start with the pack uid")
        XCTAssertTrue(path.contains("Ambulance"),
                      "iconsetPath must contain the icon name token")
        // The registry check: uid component must be extractable.
        let uidComponent = String(path.split(separator: "/").first ?? "")
        XCTAssertEqual(uidComponent, pack.uid)
    }

    func testIconPackRegistryHandlesReturnsFalseForBundledPacks() {
        // Bundled TAK packs are NOT in the imported registry — only user-imported
        // zips land there. This confirms the registry's handles() is discriminating.
        let registry = IconPackRegistry.shared
        XCTAssertFalse(registry.handles("COT_MAPPING_SPOTMAP/red"))
        XCTAssertFalse(registry.handles("COT_MAPPING_2525C/a-f-G"))
        XCTAssertFalse(registry.handles(nil))
    }
}
