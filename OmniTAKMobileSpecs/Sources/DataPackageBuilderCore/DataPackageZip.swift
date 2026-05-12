//
//  DataPackageZip.swift
//  OmniTAKMobile  (mirrored into OmniTAKMobileSpecs for `swift test`)
//
//  Minimal "STORED" (uncompressed) ZIP writer + reader for TAK data
//  packages. The existing `ZipArchive` reader in KMZHandler.swift
//  handles compression method 0 (stored) and 8 (deflate); we write
//  only stored entries so the file round-trips through both ATAK
//  and our own importer without pulling in a ZIP framework.
//
//  This is intentionally small — not a general-purpose ZIP library.
//  Data packages are typically a handful of small XML files; the
//  size hit from skipping deflate is negligible compared to the
//  KML/photos that get optionally bundled later.
//

import Foundation
#if canImport(zlib)
import zlib
#endif

// MARK: - ZIP Writer

public enum DataPackageZipWriter {

    public static func write(files: [(name: String, data: Data)]) throws -> Data {
        var out = Data()
        var centralDirEntries: [Data] = []
        var offsets: [UInt32] = []

        for entry in files {
            offsets.append(UInt32(out.count))
            let nameBytes = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)

            // Local file header (signature 0x04034b50)
            var local = Data()
            local.appendU32(0x04034b50)        // signature
            local.appendU16(20)                // version needed
            local.appendU16(0)                 // gp flags
            local.appendU16(0)                 // method = stored
            local.appendU16(0)                 // mod time
            local.appendU16(0)                 // mod date
            local.appendU32(crc)               // crc-32
            local.appendU32(size)              // compressed size
            local.appendU32(size)              // uncompressed size
            local.appendU16(UInt16(nameBytes.count))
            local.appendU16(0)                 // extra length
            local.append(contentsOf: nameBytes)
            out.append(local)
            out.append(entry.data)

            // Central directory entry (signature 0x02014b50)
            var central = Data()
            central.appendU32(0x02014b50)
            central.appendU16(20)              // version made by
            central.appendU16(20)              // version needed
            central.appendU16(0)               // gp flags
            central.appendU16(0)               // method
            central.appendU16(0)               // mod time
            central.appendU16(0)               // mod date
            central.appendU32(crc)
            central.appendU32(size)
            central.appendU32(size)
            central.appendU16(UInt16(nameBytes.count))
            central.appendU16(0)               // extra length
            central.appendU16(0)               // comment length
            central.appendU16(0)               // disk number start
            central.appendU16(0)               // internal attrs
            central.appendU32(0)               // external attrs
            central.appendU32(offsets.last ?? 0)
            central.append(contentsOf: nameBytes)
            centralDirEntries.append(central)
        }

        let centralDirOffset = UInt32(out.count)
        var centralDirSize: UInt32 = 0
        for cd in centralDirEntries {
            out.append(cd)
            centralDirSize += UInt32(cd.count)
        }

        // End of Central Directory record (signature 0x06054b50)
        var eocd = Data()
        eocd.appendU32(0x06054b50)
        eocd.appendU16(0)                       // disk number
        eocd.appendU16(0)                       // start disk
        eocd.appendU16(UInt16(files.count))
        eocd.appendU16(UInt16(files.count))
        eocd.appendU32(centralDirSize)
        eocd.appendU32(centralDirOffset)
        eocd.appendU16(0)                       // comment length
        out.append(eocd)

        return out
    }

    // MARK: - CRC-32 (PKZIP polynomial 0xEDB88320)

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            table[i] = c
        }
        return table
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[idx]
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendU32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

// MARK: - ZIP Reader (test/round-trip use)

public enum DataPackageZipReader {

    public struct Entry: Equatable {
        public let fileName: String
        public let data: Data
    }

    public enum ReadError: Error {
        case missingEOCD
        case truncatedCentralDirectory
        case truncatedLocalHeader
        case unsupportedCompression(UInt16)
    }

    public static func read(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard let eocdOffset = findEOCD(bytes: bytes) else {
            throw ReadError.missingEOCD
        }
        let centralDirOffset = Int(read32(bytes, eocdOffset + 16))
        let numEntries = Int(read16(bytes, eocdOffset + 10))

        var entries: [Entry] = []
        var cd = centralDirOffset
        for _ in 0..<numEntries {
            guard cd + 46 <= bytes.count else {
                throw ReadError.truncatedCentralDirectory
            }
            let method = read16(bytes, cd + 10)
            let compressedSize = Int(read32(bytes, cd + 20))
            let uncompressedSize = Int(read32(bytes, cd + 24))
            let nameLen = Int(read16(bytes, cd + 28))
            let extraLen = Int(read16(bytes, cd + 30))
            let commentLen = Int(read16(bytes, cd + 32))
            let localOffset = Int(read32(bytes, cd + 42))

            let nameStart = cd + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= bytes.count else {
                throw ReadError.truncatedCentralDirectory
            }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)

            guard localOffset + 30 <= bytes.count else {
                throw ReadError.truncatedLocalHeader
            }
            let localNameLen = Int(read16(bytes, localOffset + 26))
            let localExtraLen = Int(read16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            let dataEnd = dataStart + compressedSize

            guard dataEnd <= bytes.count else {
                throw ReadError.truncatedLocalHeader
            }

            let entryData: Data
            if method == 0 {
                entryData = Data(bytes[dataStart..<dataEnd])
            } else {
                // Reader only needs to handle stored entries for our
                // round-trip tests; if a deflated entry shows up we
                // surface it loudly.
                throw ReadError.unsupportedCompression(method)
            }
            _ = uncompressedSize

            entries.append(Entry(fileName: name, data: entryData))
            cd = nameEnd + extraLen + commentLen
        }
        return entries
    }

    private static func findEOCD(bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var i = bytes.count - 22
        while i >= 0 {
            if read32(bytes, i) == 0x06054b50 {
                return i
            }
            i -= 1
        }
        return nil
    }

    private static func read16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }
    private static func read32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) |
        (UInt32(b[o + 1]) << 8) |
        (UInt32(b[o + 2]) << 16) |
        (UInt32(b[o + 3]) << 24)
    }
}
