//
//  MeshtasticChannelKey.swift
//  OmniTAK Mobile
//
//  What the operator typed in the key field of a channel, read without ever
//  turning something that is not a key into "no key" (#148).
//
//  A Meshtastic channel key is 16 bytes (AES-128) or 32 bytes (AES-256), or one
//  byte, the shorthand for one of the well-known default keys. Anything else
//  the radio either rejects or treats as no encryption. The old reader returned
//  empty Data for anything that was not even-length hex, and an empty key was
//  written as "remove the key", so a base64 key pasted from the stock app, or a
//  typo, left the radio with an open channel while the screen said "applied".
//
//  Accepted: hex (with or without spaces, colons or a 0x prefix) and base64
//  (standard or URL-safe, with or without padding), decoding to 1, 16 or 32
//  bytes. When a string reads as both, it is hex.
//
//  An empty field is not a key and not "no key": it is `.blank`, and what that
//  means (keep the radio's key, or ask for one) is the caller's decision.
//  Removing a key is a separate, explicit choice.
//

import Foundation

enum MeshtasticChannelKey {

    /// The lengths a key may have: the one-byte default-key shorthand, AES-128
    /// and AES-256.
    static let validLengths: Set<Int> = [1, 16, 32]

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
        + "(or 2 hex digits for the one-byte default-key shorthand)."

    static func parse(_ text: String) -> Input {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .blank }

        if let bytes = hexBytes(trimmed), validLengths.contains(bytes.count) {
            return .key(bytes)
        }
        if let bytes = base64Bytes(trimmed), validLengths.contains(bytes.count) {
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
