//
//  IconsetImporter.swift  (OmniTAK adaptation)
//
//  Adapted from flighttactics/TAKAware (Apache-2.0).
//  Upstream: https://github.com/flighttactics/TAKAware
//  Source: TAKAware/Parsers/IconsetImporter.swift (Cory Foy, 2025)
//
//  This file documents the iconset .zip schema that ATAK/WinTAK use for
//  custom icon distribution and exposes a tiny pure-Swift parser for
//  the inner `iconset.xml` manifest. We deliberately leave out:
//
//    - SQLite persistence  (TAKAware uses a bundled icons.sqlite)
//    - Zip extraction      (would require a third-party Zip dep)
//    - SwiftTAK / SWXMLHash dependencies
//
//  The header is preserved for attribution. When OmniTAK eventually
//  ships the full iconset import flow, this file is the obvious
//  jumping-off point — it keeps the upstream data model so the schema
//  stays in sync.
//

import Foundation

/// In-memory representation of an `iconset.xml` manifest, matching the
/// upstream `IconSet` / `Icon` structs in TAKAware's IconData.swift.
public struct TAKAwareIconSet {
    public var name: String
    public var uid: String
    public var version: String?
    public var skipResize: Bool
    public var defaultFriendly: String?
    public var defaultHostile: String?
    public var defaultNeutral: String?
    public var defaultUnknown: String?
    public var icons: [TAKAwareIconEntry]
}

public struct TAKAwareIconEntry {
    public var filename: String
    public var groupName: String
    public var type2525b: String?
}

/// Minimal pure-Swift parser for ATAK iconset XML manifests.
///
/// Example manifest:
///
///     <iconset name="my-iconset" uid="…" version="8" skipResize="false">
///         <icon name="air_ship.png" type2525b="a-h-G"/>
///     </iconset>
///
/// We intentionally use Foundation's `XMLParser` (no SWXMLHash) so this
/// stays dependency-free and ready for an eventual full iconset
/// pipeline in OmniTAK.
public final class TAKAwareIconsetParser: NSObject, XMLParserDelegate {
    public private(set) var parsedSet: TAKAwareIconSet?

    private var current: TAKAwareIconSet?
    private var icons: [TAKAwareIconEntry] = []

    public func parse(_ data: Data) -> TAKAwareIconSet? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        if parser.parse() {
            return parsedSet
        }
        return nil
    }

    // MARK: - XMLParserDelegate

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "iconset":
            current = TAKAwareIconSet(
                name: attributeDict["name"] ?? "",
                uid: attributeDict["uid"] ?? "",
                version: attributeDict["version"],
                skipResize: (attributeDict["skipResize"] ?? "false") == "true",
                defaultFriendly: attributeDict["defaultFriendly"],
                defaultHostile: attributeDict["defaultHostile"],
                defaultNeutral: attributeDict["defaultNeutral"],
                defaultUnknown: attributeDict["defaultUnknown"],
                icons: []
            )

        case "icon":
            icons.append(TAKAwareIconEntry(
                filename: attributeDict["name"] ?? "",
                groupName: attributeDict["group"] ?? "default",
                type2525b: attributeDict["type2525b"]
            ))

        default:
            break
        }
    }

    public func parserDidEndDocument(_ parser: XMLParser) {
        guard var set = current else { return }
        set.icons = icons
        parsedSet = set
    }
}
