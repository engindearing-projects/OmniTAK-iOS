//
//  MeshtasticChannelKeyTests.swift
//  OmniTAKMobileTests
//
//  #148: what the operator types in the key field is read as a key or refused,
//  and is never turned into "no key". The old reader returned empty Data for
//  anything that was not even-length hex, and an empty key was written as a
//  removal, so a base64 key from the stock app or a typo left the radio with an
//  open channel while the screen said "applied".
//
//  Every key here is made up.
//

import XCTest
@testable import OmniTAK

final class MeshtasticChannelKeyTests: XCTestCase {

    private let key32 = Data((0..<32).map { UInt8(0x50 &+ UInt8($0) &* 3) })
    private var key16: Data { Data(key32.prefix(16)) }

    private func parse(_ text: String) -> MeshtasticChannelKey.Input {
        MeshtasticChannelKey.parse(text)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // MARK: Blank

    func testNothingTypedIsBlankAndNotAKey() {
        XCTAssertEqual(parse(""), .blank)
        XCTAssertEqual(parse("   "), .blank)
        XCTAssertEqual(parse("\n\t "), .blank)
    }

    // MARK: Hex

    func testHexOfThe16And32ByteLengthsIsAKey() {
        XCTAssertEqual(parse(hex(key16)), .key(key16))
        XCTAssertEqual(parse(hex(key32)), .key(key32))
    }

    func testHexMayBeUpperCaseSpacedColonedOrPrefixed() {
        XCTAssertEqual(parse(hex(key32).uppercased()), .key(key32))
        let spaced = stride(from: 0, to: 64, by: 2).map { i -> String in
            let h = hex(key32)
            let start = h.index(h.startIndex, offsetBy: i)
            return String(h[start..<h.index(start, offsetBy: 2)])
        }
        XCTAssertEqual(parse(spaced.joined(separator: " ")), .key(key32))
        XCTAssertEqual(parse(spaced.joined(separator: ":")), .key(key32))
        XCTAssertEqual(parse("0x" + hex(key16)), .key(key16))
        XCTAssertEqual(parse("  \(hex(key16))  \n"), .key(key16))
    }

    func testTwoHexDigitsAreTheOneByteShorthandFromZeroToTen() {
        XCTAssertEqual(parse("00"), .key(Data([0x00])), "encryption off")
        XCTAssertEqual(parse("01"), .key(Data([0x01])))
        XCTAssertEqual(parse("0a"), .key(Data([0x0A])))
        XCTAssertEqual(parse("0A"), .key(Data([0x0A])))
    }

    func testAOneByteValueTheRadioGivesNoMeaningIsNotAKey() {
        for text in ["0b", "0B", "10", "7f", "ab", "AB", "ff"] {
            XCTAssertEqual(parse(text), .invalid(MeshtasticChannelKey.invalidMessage), text)
        }
    }

    // MARK: Base64

    func testBase64OfA16Or32ByteKeyIsAKey() {
        XCTAssertEqual(parse(key32.base64EncodedString()), .key(key32))
        XCTAssertEqual(parse(key16.base64EncodedString()), .key(key16))
    }

    func testBase64MayBeURLSafeOrUnpadded() {
        // A key that has +, / and = in its base64.
        let tricky = Data([0xFB, 0xEF, 0xBE, 0xFF, 0xFF, 0xFE] + [UInt8](repeating: 0x3E, count: 10))
        let standard = tricky.base64EncodedString()
        XCTAssertTrue(standard.contains("+") || standard.contains("/"))
        XCTAssertEqual(parse(standard), .key(tricky))
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(parse(urlSafe), .key(tricky))
        let unpadded = standard.replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(parse(unpadded), .key(tricky))
    }

    func testBase64IsNeverTheOneByteShorthand() {
        // Two base64 characters are too easily something else. "AA==" and "AQ=="
        // are one byte, 0 and 1, and the shorthand is only taken as hex.
        XCTAssertEqual(parse("AA=="), .invalid(MeshtasticChannelKey.invalidMessage))
        XCTAssertEqual(parse("AQ=="), .invalid(MeshtasticChannelKey.invalidMessage))
        XCTAssertEqual(parse("AA"), .invalid(MeshtasticChannelKey.invalidMessage))
        XCTAssertEqual(parse("ab"), .invalid(MeshtasticChannelKey.invalidMessage), "hex 0xAB is not a shorthand either")
    }

    func testAStringThatIsBothHexAndBase64IsReadAsHex() {
        // 32 characters of hex digits are also base64, of 24 bytes, which is not a key length.
        XCTAssertEqual(parse(hex(key16)), .key(key16))
        XCTAssertEqual(parse("0a"), .key(Data([0x0A])), "and two hex digits in range are the shorthand")
    }

    // MARK: Refused

    func testSomethingThatIsNotAKeyIsInvalidAndNeverBlankOrEmpty() {
        let bad = [
            "not a key",
            "hello world, this is not a key at all",
            "abc",                                  // odd number of hex digits
            "+f" + hex(key16).dropFirst(2),         // a sign is not a hex digit
            "zz" + hex(key32),
            "====",
            "AAAA=AAAA",                            // padding in the middle
            hex(key32) + "!",
        ]
        for text in bad {
            guard case .invalid(let reason) = parse(text) else {
                XCTFail("\(text.count) characters was taken for \(parse(text))")
                continue
            }
            XCTAssertEqual(reason, MeshtasticChannelKey.invalidMessage)
        }
    }

    func testAKeyOfTheWrongLengthIsInvalid() {
        for length in [2, 3, 8, 15, 17, 24, 31, 33, 48, 64] {
            let bytes = Data(repeating: 0x42, count: length)
            XCTAssertEqual(parse(hex(bytes)), .invalid(MeshtasticChannelKey.invalidMessage), "\(length) bytes as hex")
            XCTAssertEqual(parse(bytes.base64EncodedString()), .invalid(MeshtasticChannelKey.invalidMessage), "\(length) bytes as base64")
        }
    }

    func testTheMessageSaysWhatToType() {
        XCTAssertTrue(MeshtasticChannelKey.invalidMessage.contains("hex"))
        XCTAssertTrue(MeshtasticChannelKey.invalidMessage.contains("base64"))
        XCTAssertTrue(MeshtasticChannelKey.invalidMessage.contains("16 or 32 bytes"))
    }

    func testAKeyIsNeverPrinted() {
        XCTAssertEqual(MeshtasticChannelKey.Input.key(key32).description, "key(32 bytes)")
        XCTAssertFalse("\(MeshtasticChannelKey.Input.key(key32))".contains(hex(key32).prefix(8)))
    }

    func testThePrivateLengthsAreSixteenAndThirtyTwoBytes() {
        XCTAssertEqual(MeshtasticChannelKey.privateLengths, [16, 32])
    }

    func testAKeyIsUsableWhenTheRadioTakesItForAKey() {
        XCTAssertTrue(MeshtasticChannelKey.isUsable(key16))
        XCTAssertTrue(MeshtasticChannelKey.isUsable(key32))
        XCTAssertTrue(MeshtasticChannelKey.isUsable(Data([0])))
        XCTAssertTrue(MeshtasticChannelKey.isUsable(Data([10])))
        XCTAssertFalse(MeshtasticChannelKey.isUsable(Data([11])))
        XCTAssertFalse(MeshtasticChannelKey.isUsable(Data()), "no key at all means something else on each channel")
        XCTAssertFalse(MeshtasticChannelKey.isUsable(Data(repeating: 1, count: 15)))
        XCTAssertFalse(MeshtasticChannelKey.isUsable(Data(repeating: 1, count: 17)))
        XCTAssertEqual(MeshtasticChannelKey.open, Data([0]))
    }

    // MARK: What a key amounts to

    func testWhatAKeyAmountsToIsWhatTheRadioTakesItFor() {
        typealias Kind = MeshtasticChannelKey.Kind
        // One byte 0 is encryption off, on either channel.
        XCTAssertEqual(MeshtasticChannelKey.kind(of: Data([0]), isPrimary: false), .open)
        XCTAssertEqual(MeshtasticChannelKey.kind(of: Data([0]), isPrimary: true), .open)
        // One byte 1 to 10 is the public default key family.
        for value in UInt8(1)...UInt8(10) {
            XCTAssertEqual(MeshtasticChannelKey.kind(of: Data([value]), isPrimary: false), .defaultKey)
        }
        // No key: on a secondary, the primary's; on the primary, off.
        XCTAssertEqual(MeshtasticChannelKey.kind(of: Data(), isPrimary: false), .samePrimary)
        XCTAssertEqual(MeshtasticChannelKey.kind(of: Data(), isPrimary: true), .open)
        // A private key.
        XCTAssertEqual(MeshtasticChannelKey.kind(of: key16, isPrimary: false), .privateKey)
        XCTAssertEqual(MeshtasticChannelKey.kind(of: key32, isPrimary: true), .privateKey)
        // Anything else is not described as private or open.
        XCTAssertEqual(MeshtasticChannelKey.kind(of: Data(repeating: 1, count: 20), isPrimary: false), .unusual(length: 20))
        XCTAssertEqual(MeshtasticChannelKey.kind(of: Data([200]), isPrimary: false), .unusual(length: 1))
    }

    func testTheLabelsSayWhatItIs() {
        XCTAssertEqual(MeshtasticChannelKey.Kind.open.label, "open")
        XCTAssertEqual(MeshtasticChannelKey.Kind.defaultKey.label, "default key, not private")
        XCTAssertEqual(MeshtasticChannelKey.Kind.samePrimary.label, "same key as primary")
        XCTAssertEqual(MeshtasticChannelKey.Kind.privateKey.label, "private key")
        XCTAssertEqual(MeshtasticChannelKey.Kind.unusual(length: 20).label, "unusual key (20 bytes)")
    }

    func testASavedChannelIsLabelledByWhatItsKeyIs() {
        typealias Stored = MeshtasticManager.StoredChannel
        XCTAssertEqual(Stored(index: 2, name: "a", pskHex: "00", isPrimary: false).keyKind, .open)
        XCTAssertEqual(Stored(index: 2, name: "a", pskHex: "01", isPrimary: false).keyKind, .defaultKey)
        XCTAssertEqual(Stored(index: 2, name: "a", pskHex: hex(key32), isPrimary: false).keyKind, .privateKey)
        XCTAssertEqual(Stored(index: 2, name: "a", pskHex: "", isPrimary: false).keyKind, .samePrimary,
                       "a secondary channel with no key is not open")
        XCTAssertEqual(Stored(index: 0, name: "a", pskHex: "", isPrimary: true).keyKind, .open)
    }
}
