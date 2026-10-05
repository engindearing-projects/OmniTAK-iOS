//
//  MeshtasticChannelKey.swift
//  OmniTAK Mobile
//
//  What the operator typed in the key field of a channel, read without ever
//  turning something that is not a key into "no key" (#148).
//
//  What a key means is the radio's (Channels::getKey in the firmware), not the
//  app's:
//   - 16 or 32 bytes: a private key (AES-128 or AES-256).
//   - one byte, 1 to 10: the public default key, bumped by the byte. It is not
//     private: everyone has it.
//   - one byte, 0: encryption off. This is what "open" means.
//   - no bytes: on a SECONDARY channel, the primary channel's key; on the
//     PRIMARY, encryption off.
//  So a channel written with no key at all is not open: on a secondary it is
//  encrypted with the primary's key. Open is the single byte 0.
//
//  The old reader returned empty Data for anything that was not even-length hex,
//  and an empty key was written as "remove the key", so a base64 key pasted from
//  the stock app, or a typo, left the radio with a channel the screen did not
//  describe while it said "applied".
//
//  Accepted: hex (with or without spaces, colons or a 0x prefix) of 16 or 32
//  bytes, base64 (standard or URL-safe, with or without padding) of 16 or 32
//  bytes, and the one-byte shorthand only as two hex digits, 00 to 0A. A string
//  that reads as both hex and base64 is hex.
//
//  An empty field is not a key and not "no key": it is `.blank`, and what that
//  means (keep the radio's key, or ask for one) is the caller's decision.
//  Removing a key is a separate, explicit choice, and it writes the one byte 0.
//

import Foundation

enum MeshtasticChannelKey {

    /// The lengths of a private key: AES-128 and AES-256.
    static let privateLengths: Set<Int> = [16, 32]

    /// The one-byte values the radio gives a meaning: 0 turns encryption off,
    /// 1 to 10 are the public default key family.
    static let shorthandValues: ClosedRange<UInt8> = 0...10

    /// The key that means "no encryption": the one byte 0.
    static let open = Data([0])

    /// Whether the radio would take these bytes as a key for a channel. A key of
    /// no bytes is not one: what it means depends on the channel's role.
    static func isUsable(_ psk: Data) -> Bool {
        if privateLengths.contains(psk.count) { return true }
        return psk.count == 1 && shorthandValues.contains(psk[psk.startIndex])
    }

    /// What a channel's key amounts to, as the radio sees it.
    enum Kind: Equatable {
        /// Encryption off: the single byte 0, or no key on the primary.
        case open
        /// The public default key. Everyone has it.
        case defaultKey
        /// No key on a secondary channel: it uses the primary's key.
        case samePrimary
        /// A private key of 16 or 32 bytes.
        case privateKey
        /// Bytes the radio pads or expands in ways this app does not describe.
        case unusual(length: Int)

        var label: String {
            switch self {
            case .open:        return "open"
            case .defaultKey:  return "default key, not private"
            case .samePrimary: return "same key as primary"
            case .privateKey:  return "private key"
            case .unusual(let length): return "unusual key (\(length) bytes)"
            }
        }
    }

    /// The kind of key these bytes are on a primary or a secondary channel.
    static func kind(of psk: Data, isPrimary: Bool) -> Kind {
        switch psk.count {
        case 0:
            return isPrimary ? .open : .samePrimary
        case 1:
            let byte = psk[psk.startIndex]
            if byte == 0 { return .open }
            return shorthandValues.contains(byte) ? .defaultKey : .unusual(length: 1)
        case 16, 32:
            return .privateKey
        default:
            return .unusual(length: psk.count)
        }
    }

    /// What the operator typed.
    enum Input: Equatable, CustomStringConvertible {
        /// Nothing, or only spaces.
        case blank
        /// A key of a valid length.
        case key(Data)
        /// Something that is not a usable key. The text says what to type.
        case invalid(String)

        // Key bytes are never printed, not even by a failing assertion.
        var description: String {
            switch self {
            case .blank: return "blank"
            case .key(let data): return "key(\(data.count) bytes)"
            case .invalid(let reason): return "invalid(\(reason))"
            }
        }
    }

    static let invalidMessage =
        "That is not a usable key. Enter 32 or 64 hex digits, or base64 that decodes to 16 or 32 bytes "
        + "(or 2 hex digits, 00 to 0A, for the one-byte shorthand)."

    static func parse(_ text: String) -> Input {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .blank }

        if let bytes = hexBytes(trimmed), isUsable(bytes) {
            return .key(bytes)
        }
        // Base64 is for private keys only. The one-byte shorthand is two hex
        // digits: two base64 characters are too easily something else.
        if let bytes = base64Bytes(trimmed), privateLengths.contains(bytes.count) {
            return .key(bytes)
        }
        return .invalid(invalidMessage)
    }

    /// The bytes of a hex string, or nil when it is not hex.
    private static func hexBytes(_ text: String) -> Data? {
        var digits = text.filter { !$0.isWhitespace && $0 != ":" }
        if digits.lowercased().hasPrefix("0x") { digits = String(digits.dropFirst(2)) }
        guard !digits.isEmpty, digits.count % 2 == 0, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        var out = Data(capacity: digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// The bytes of a base64 string, standard or URL-safe, padded or not, or
    /// nil when it is not base64.
    private static func base64Bytes(_ text: String) -> Data? {
        var s = text.filter { !$0.isWhitespace }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !s.isEmpty else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard s.allSatisfy({ allowed.contains($0) }) else { return nil }
        // Padding is only ever at the end, and only up to two characters.
        let body = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard !body.contains("="), s.count - body.count <= 2 else { return nil }
        let remainder = body.count % 4
        guard remainder != 1 else { return nil }
        if remainder != 0 { s = body + String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
