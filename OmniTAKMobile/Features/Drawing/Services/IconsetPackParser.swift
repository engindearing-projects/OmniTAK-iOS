//
//  IconsetPackParser.swift
//  OmniTAKMobile
//
//  Issue #75 Phase 2 — pure-Swift parser for ATAK's `iconset.xml` format.
//
//  ATAK iconset zips contain an `iconset.xml` at the root (or sometimes nested
//  under a directory) alongside the image files the XML references. The XML
//  follows this structure:
//
//  ```xml
//  <?xml version="1.0" encoding="UTF-8"?>
//  <iconset uid="<uuid>" name="Pack Name" version="1"
//           defaultFriendlyGroup="…" defaultHostileGroup="…" …>
//    <icon name="Ambulance" filename="Ground/Ambulance.png"/>
//    <!-- or grouped: -->
//    <group name="Ground">
//      <icon name="Tank" filename="Ground/Tank.png"/>
//    </group>
//  </iconset>
//  ```
//
//  No UIKit / Foundation dependencies beyond XMLParser — fully testable without
//  a device. Bitmap loading and storage are handled by `IconPackRegistry`.
//
//  Resolution follows ATAK's `iconsetpath` wire format:
//    `"<uid>/<filename-without-extension>"`
//  e.g. `"f47ac10b-…/Ground/Ambulance"` matches the icon with
//  `filename="Ground/Ambulance.png"`.
//

import Foundation

// MARK: - IconsetPackParser

/// Pure-Swift, no-UIKit parser for ATAK `iconset.xml`. Returns a
/// `ParsedIconset` or nil on malformed input. All path logic lives here;
/// bitmap loading is separate (see `IconPackRegistry`).
enum IconsetPackParser {

    // MARK: - Data types

    /// A single icon entry from `iconset.xml`.
    struct IconEntry: Equatable {
        /// Display / lookup name (`name` attribute).
        let name: String
        /// Relative path inside the zip (`filename` attribute),
        /// e.g. `"Ground/Ambulance.png"`.
        let filename: String

        /// Derive the ATAK `iconsetpath` token (filename without extension).
        var pathToken: String { filename.removingFileExtension }
    }

    /// A fully-parsed ATAK iconset pack.
    struct ParsedIconset: Equatable {
        /// The pack's UUID (`uid` attribute on `<iconset>`). First path component
        /// in ATAK `iconsetpath` wire format.
        let uid: String
        /// Human-readable pack name (`name` attribute, or `uid` when absent).
        let name: String
        /// Pack version (defaults to 1).
        let version: Int
        /// All icon entries, flattened from any `<group>` nesting.
        let icons: [IconEntry]

        // MARK: Icon lookup

        /// Resolve an icon by its exact `name` attribute.
        func iconByName(_ name: String) -> IconEntry? {
            icons.first { $0.name == name }
        }

        /// Resolve an icon by name, case-insensitively.
        func iconByNameInsensitive(_ name: String) -> IconEntry? {
            icons.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        /// Resolve an icon from an ATAK `usericon iconsetpath` value.
        ///
        /// Accepted forms (all equivalent for `uid="abc"`, `filename="Ground/Ambulance.png"`):
        /// - `"abc/Ground/Ambulance"`       — full path, no extension
        /// - `"abc/Ground/Ambulance.png"`   — full path, with extension
        /// - `"abc/Ambulance"`              — basename only, no extension
        /// - `"abc/Ambulance.png"`          — basename only, with extension
        ///
        /// Returns nil when the uid prefix doesn't match or the token is unknown.
        func iconByIconsetPath(_ iconsetPath: String) -> IconEntry? {
            let prefix = uid + "/"
            guard iconsetPath.hasPrefix(prefix) else { return nil }
            let token = String(iconsetPath.dropFirst(prefix.count))
                .removingFileExtension
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // 1. Exact filename-without-extension match (full subdirectory path).
            if let exact = icons.first(where: { $0.filename.removingFileExtension == token }) {
                return exact
            }
            // 2. Basename match (caller omitted the subdirectory component).
            let basename = String(token.split(separator: "/").last ?? Substring(token))
            return icons.first(where: {
                $0.filename.removingFileExtension.baseName == basename
            })
        }

        /// ATAK canonical `iconsetpath` for an `IconEntry`:
        /// `"<uid>/<filename-without-extension>"`.
        ///
        /// This is what OmniTAK emits in `<usericon iconsetpath="…"/>` when the
        /// operator places a marker so ATAK / iTAK peers resolve to the right glyph.
        func iconsetPath(for icon: IconEntry) -> String {
            "\(uid)/\(icon.filename.removingFileExtension)"
        }
    }

    // MARK: - Parse

    /// Parse an ATAK `iconset.xml` string into a `ParsedIconset`.
    ///
    /// Returns nil when:
    /// - the string is blank or not valid XML,
    /// - the root element is not `<iconset>`,
    /// - the `uid` attribute is missing or blank.
    ///
    /// Malformed `<icon>` entries (missing `name` or `filename`) are silently
    /// skipped — a partial pack is better than a total failure.
    static func parse(_ xml: String) -> ParsedIconset? {
        guard !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.failed else { return nil }
        return delegate.result
    }
}

// MARK: - XMLParserDelegate (private)

private final class ParserDelegate: NSObject, XMLParserDelegate {

    var result: IconsetPackParser.ParsedIconset?
    var failed = false

    private var uid: String?
    private var name: String?
    private var version: Int = 1
    private var icons: [IconsetPackParser.IconEntry] = []

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes: [String: String]) {
        switch elementName {
        case "iconset":
            guard let u = attributes["uid"], !u.trimmingCharacters(in: .whitespaces).isEmpty else {
                failed = true
                parser.abortParsing()
                return
            }
            uid = u
            let n = attributes["name"]?.trimmingCharacters(in: .whitespaces)
            name = (n?.isEmpty ?? true) ? nil : n
            version = attributes["version"].flatMap(Int.init) ?? 1

        case "icon":
            let iName = attributes["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let iFile = attributes["filename"]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !iName.isEmpty, !iFile.isEmpty else { break }
            icons.append(IconsetPackParser.IconEntry(name: iName, filename: iFile))

        default:
            break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        guard let uid else { return }
        result = IconsetPackParser.ParsedIconset(
            uid: uid,
            name: name ?? uid,
            version: version,
            icons: icons
        )
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}

// MARK: - String helpers (file-path utils)

private extension String {
    /// Remove the last path extension (`.png`, `.jpg`, etc.), mirroring
    /// `URL.deletingPathExtension().lastPathComponent` for simple filenames.
    var removingFileExtension: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return self }
        return String(self[..<dot])
    }

    /// Last path component — everything after the final `/`.
    var baseName: String {
        String(split(separator: "/").last ?? Substring(self))
    }
}
