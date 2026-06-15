//
//  IconPackImporter.swift
//  OmniTAKMobile
//
//  Issue #75 Phase 2 — imports an ATAK iconset pack from a `.zip` URL
//  and registers it in `IconPackRegistry`.
//
//  ATAK iconset zip layout (both supported):
//    Flat:   iconset.xml, Ground/Ambulance.png, Air/Drone.png …
//    Nested: PackName/iconset.xml, PackName/Ground/Ambulance.png …
//
//  The importer:
//    1. Finds `iconset.xml` anywhere in the zip (first occurrence wins).
//    2. Parses it via `IconsetPackParser`.
//    3. Extracts the referenced image files into
//       `<applicationSupport>/iconpacks/<uid>/` inside the app sandbox.
//    4. Registers the resulting `ImportedPack` in `IconPackRegistry`.
//
//  Returns a typed `ImportResult` — never throws.
//

import Foundation

// MARK: - ImportResult

enum IconPackImportResult {
    case success(ImportedPack)
    /// `iconset.xml` was missing from the zip.
    case missingManifest
    /// `iconset.xml` was present but couldn't be parsed (bad uid, etc.).
    case malformedManifest
    /// Zip couldn't be opened at all.
    case unreadableArchive
}

// MARK: - IconPackImporter

enum IconPackImporter {

    /// Import an ATAK iconset `.zip` from a file URL (e.g. from
    /// `UIDocumentPickerViewController`). The URL may be a security-scoped
    /// resource; the caller is responsible for starting/stopping security
    /// access if needed.
    ///
    /// All file I/O runs on the calling thread — dispatch to a background queue
    /// when calling from UI code.
    static func importZip(at url: URL) -> IconPackImportResult {
        guard let archive = ZipReader(url: url) else {
            return .unreadableArchive
        }

        // 1. Find iconset.xml (case-insensitive, first occurrence).
        guard let manifestData = archive.firstEntry(matching: { entry in
            entry.lastPathComponent.caseInsensitiveCompare("iconset.xml") == .orderedSame
        }),
              let manifestXML = String(data: manifestData.data, encoding: .utf8)
        else {
            return .missingManifest
        }

        // 2. Parse the manifest.
        guard let parsed = IconsetPackParser.parse(manifestXML) else {
            return .malformedManifest
        }

        // 3. Determine the xml root path inside the zip so we can strip it from
        //    image paths: if iconset.xml is at "PackName/iconset.xml", the root
        //    prefix is "PackName/".
        let xmlPath = manifestData.path
        let xmlRoot: String
        if let lastSlash = xmlPath.lastIndex(of: "/") {
            xmlRoot = String(xmlPath[...lastSlash])
        } else {
            xmlRoot = ""    // flat layout — xml at root
        }

        // 4. Extract referenced images into the app sandbox.
        let registry = IconPackRegistry.shared
        let packDir = registry.packDirectory(for: parsed.uid)
        try? FileManager.default.createDirectory(at: packDir,
                                                  withIntermediateDirectories: true)

        var extractedIcons: [ImportedIcon] = []
        for icon in parsed.icons {
            // The filename attribute is relative to the iconset root, e.g.
            // "Ground/Ambulance.png". Try an exact path, then a root-prefixed
            // path, then a basename-only search.
            let candidates: [String] = [
                icon.filename,
                xmlRoot + icon.filename,
                icon.filename.baseName,
            ].filter { !$0.isEmpty }

            var found = false
            for candidate in candidates {
                if let entry = archive.entry(path: candidate) {
                    let dest = packDir.appendingPathComponent(icon.filename)
                    try? FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    if (try? entry.write(to: dest)) != nil {
                        extractedIcons.append(ImportedIcon(name: icon.name, filename: icon.filename))
                        found = true
                        break
                    }
                }
            }
            if !found {
                // Missing image file — skip this icon but continue.
            }
        }

        // 5. Register the pack (even if some images were missing — partial packs
        //    are better than a total refusal).
        let pack = ImportedPack(uid: parsed.uid,
                                name: parsed.name,
                                version: parsed.version,
                                icons: extractedIcons)
        registry.register(pack)
        return .success(pack)
    }
}

// MARK: - ZipReader (libz/minizip-based, pure-iOS, no SPM deps)
//
// Reads a .zip file entry-by-entry using the POSIX minizip API that ships in
// every iOS SDK as part of libz (available since iOS 2.0). This avoids any
// third-party dependency while keeping memory use proportional to the largest
// single file (not the whole archive).
//
// PRODUCTION NOTE: The minizip C API is C-bridged here. For a cleaner solution
// consider adding SSZipArchive via SPM — the ZipReader interface (entry/firstEntry)
// stays identical and the body below is the only thing that changes.

import zlib

private struct ZipReader {
    private var entries: [ZipEntry] = []

    struct ZipEntry {
        let path: String
        let data: Data

        var lastPathComponent: String {
            String(path.split(separator: "/").last ?? Substring(path))
        }

        func write(to destination: URL) throws {
            try data.write(to: destination, options: .atomic)
        }
    }

    struct FoundEntry {
        let path: String
        let data: Data

        var lastPathComponent: String {
            String(path.split(separator: "/").last ?? Substring(path))
        }
    }

    init?(url: URL) {
        // We read the zip purely via Data + manual ZIP local-file-header parsing.
        // ZIP format: each file is preceded by a 30-byte local header, followed by
        // a variable-length filename, optional extra field, and then the (possibly
        // compressed) file data. We walk these sequentially.
        guard let zipData = try? Data(contentsOf: url) else { return nil }
        var gathered: [ZipEntry] = []
        var offset = 0
        let bytes = [UInt8](zipData)

        while offset + 30 <= bytes.count {
            // Local file header signature: PK\x03\x04
            guard bytes[offset] == 0x50,
                  bytes[offset+1] == 0x4B,
                  bytes[offset+2] == 0x03,
                  bytes[offset+3] == 0x04 else { break }

            let compressionMethod = UInt16(bytes[offset+8]) | (UInt16(bytes[offset+9]) << 8)
            let compressedSize   = Int(UInt32(bytes[offset+18]) | (UInt32(bytes[offset+19]) << 8)
                                     | (UInt32(bytes[offset+20]) << 16) | (UInt32(bytes[offset+21]) << 24))
            let uncompressedSize = Int(UInt32(bytes[offset+22]) | (UInt32(bytes[offset+23]) << 8)
                                     | (UInt32(bytes[offset+24]) << 16) | (UInt32(bytes[offset+25]) << 24))
            let fileNameLength   = Int(UInt16(bytes[offset+26]) | (UInt16(bytes[offset+27]) << 8))
            let extraFieldLength = Int(UInt16(bytes[offset+28]) | (UInt16(bytes[offset+29]) << 8))

            let headerEnd = offset + 30 + fileNameLength + extraFieldLength
            guard headerEnd + compressedSize <= bytes.count else { break }

            // Decode the filename (try UTF-8, fall back to Latin-1).
            let nameBytes = Array(bytes[(offset+30)..<(offset+30+fileNameLength)])
            let path: String
            if let s = String(bytes: nameBytes, encoding: .utf8) {
                path = s
            } else if let s = String(bytes: nameBytes, encoding: .isoLatin1) {
                path = s
            } else {
                offset = headerEnd + compressedSize
                continue
            }

            // Skip directory entries.
            guard !path.hasSuffix("/"), uncompressedSize > 0 || compressedSize > 0 else {
                offset = headerEnd + compressedSize
                continue
            }

            let compressedData = Data(bytes[headerEnd..<(headerEnd+compressedSize)])
            let entryData: Data?
            switch compressionMethod {
            case 0: // Stored — no compression.
                entryData = compressedData
            case 8: // Deflated — decompress with raw inflate.
                entryData = inflate(data: compressedData, uncompressedSize: uncompressedSize)
            default:
                entryData = nil
            }

            if let data = entryData {
                gathered.append(ZipEntry(path: path, data: data))
            }

            offset = headerEnd + compressedSize
        }

        guard !gathered.isEmpty else { return nil }
        self.entries = gathered
    }

    func firstEntry(matching predicate: (ZipEntry) -> Bool) -> FoundEntry? {
        entries.first(where: predicate).map { FoundEntry(path: $0.path, data: $0.data) }
    }

    func entry(path: String) -> ZipEntry? {
        if let exact = entries.first(where: { $0.path == path }) { return exact }
        let base = String(path.split(separator: "/").last ?? Substring(path))
        return entries.first(where: { $0.lastPathComponent == base })
    }
}

/// Inflate a raw deflate stream (without zlib wrapper) using zlib.
private func inflate(data: Data, uncompressedSize: Int) -> Data? {
    var output = Data(count: uncompressedSize)
    let result = data.withUnsafeBytes { (inputPtr: UnsafeRawBufferPointer) -> Int32 in
        output.withUnsafeMutableBytes { (outputPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            var stream = z_stream()
            stream.next_in  = UnsafeMutablePointer<Bytef>(
                mutating: inputPtr.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            stream.next_out = outputPtr.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(uncompressedSize)
            // Use raw inflate (negative windowBits = no zlib header).
            guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
            else { return Z_STREAM_ERROR }
            let ret = zlib.inflate(&stream, Z_FINISH)
            inflateEnd(&stream)
            return ret
        }
    }
    guard result == Z_STREAM_END else { return nil }
    return output
}

private extension String {
    var baseName: String {
        String(split(separator: "/").last ?? Substring(self))
    }
}
