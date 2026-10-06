//
//  ProtoFieldsTests.swift
//  OmniTAKMobileTests
//
//  ProtoFields reads a protobuf message as top-level fields, changes some of
//  them and writes it back with the rest byte for byte (#148). A radio replaces
//  a whole sub-config with what it is sent, so a field this app does not know
//  about, or a value it would have written differently, must come back exactly
//  as the radio sent it. These tests pin that, and that no input can trap it.
//
//  Messages are built from field numbers and wire types, with made-up values.
//

import XCTest
@testable import OmniTAK

final class ProtoFieldsTests: XCTestCase {

    /// One field of every wire type the reader handles, an unknown field with a
    /// two-byte tag, the highest legal field number, an empty length-delimited
    /// field, and field 1 twice.
    private func everyWireType() -> ProtoFixture {
        ProtoFixture()
            .varint(1, 150)
            .fixed64(2, 0x0102_0304_0506_0708)
            .string(3, "hello")
            .fixed32(4, 0xDEAD_BEEF)
            .varint(RadioProto.futureField, 1)
            .bytes(ProtoFields.maxFieldNumber, Data([1, 2, 3]))
            .bytes(5, Data())
            .varint(1, 7)
    }

    private func patched(_ message: ProtoFixture, _ edits: [ProtoFields.Edit],
                         file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        try XCTUnwrap(ProtoFields.patch(message.data, edits), "patch returned nil", file: file, line: line)
    }

    // MARK: - Reading and writing back

    func testParseThenSerializeGivesTheSameBytes() throws {
        let message = everyWireType().data
        let fields = try XCTUnwrap(ProtoFields.parse(message))
        XCTAssertEqual(ProtoFields.serialize(fields), message)
    }

    func testParseReportsEachFieldsNumberWireTypeRawBytesAndValue() throws {
        let fields = try XCTUnwrap(ProtoFields.parse(everyWireType().data))
        XCTAssertEqual(fields.map(\.number), [1, 2, 3, 4, 300, 536_870_911, 5, 1])
        XCTAssertEqual(fields.map(\.wireType), [0, 1, 2, 5, 0, 2, 2, 0])

        XCTAssertEqual(fields[0].raw, Data([0x08, 0x96, 0x01]))
        XCTAssertEqual(fields[0].value, Data([0x96, 0x01]))
        XCTAssertEqual(fields[0].varintValue, 150)

        XCTAssertEqual(fields[2].raw, Data([0x1A, 0x05]) + Data("hello".utf8))
        XCTAssertEqual(fields[2].value, Data("hello".utf8))
        XCTAssertNil(fields[2].varintValue, "a length-delimited field has no varint value")

        // field 300, wire 0: tag (300 << 3) = 2400 = E0 12
        XCTAssertEqual(fields[4].raw, Data([0xE0, 0x12, 0x01]))

        XCTAssertEqual(fields[6].raw, Data([0x2A, 0x00]))
        XCTAssertEqual(fields[6].value, Data())
    }

    func testAnEmptyMessageIsValidAndHasNoFields() throws {
        XCTAssertEqual(ProtoFields.parse(Data()), [])
        XCTAssertEqual(ProtoFields.serialize([]), Data())
    }

    func testVarintsThatAreLongerThanNeededKeepTheirBytes() throws {
        // Field 1 with the tag written in two bytes (88 00) and the value 1 in
        // two bytes (81 00), then field 2 normally.
        let message = Data([0x88, 0x00, 0x81, 0x00]) + ProtoFixture().varint(2, 5).data
        let fields = try XCTUnwrap(ProtoFields.parse(message))
        XCTAssertEqual(fields[0].number, 1)
        XCTAssertEqual(fields[0].varintValue, 1)
        XCTAssertEqual(ProtoFields.serialize(fields), message)

        // Editing another field leaves those four bytes as they were.
        let edited = try XCTUnwrap(ProtoFields.patch(message, [.varint(2, 6)]))
        XCTAssertEqual(edited, Data([0x88, 0x00, 0x81, 0x00]) + ProtoFixture().varint(2, 6).data)
    }

    func testASliceThatStartsPastZeroParsesTheSame() throws {
        let message = everyWireType().data
        let padded = Data([0xDE, 0xAD, 0xBE, 0xEF]) + message
        let slice = padded.dropFirst(4)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(ProtoFields.parse(slice), ProtoFields.parse(message))
        XCTAssertEqual(ProtoFields.patch(slice, []), message)
    }

    func testVarintsOfEveryMagnitudeRoundTrip() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 16_383, 16_384, 1 << 32, UInt64.max - 1, UInt64.max] {
            let field = ProtoFields.varintField(1, value)
            let parsed = try XCTUnwrap(ProtoFields.parse(field.raw)?.first, "value \(value)")
            XCTAssertEqual(parsed.varintValue, value)
            XCTAssertEqual(parsed, field)
        }
        XCTAssertEqual(ProtoFields.varintField(1, 300).raw, Data([0x08, 0xAC, 0x02]))
    }

    func testTheFieldEncodersWriteWhatTheReaderExpects() throws {
        XCTAssertEqual(ProtoFields.boolField(2, true).raw, Data([0x10, 0x01]))
        XCTAssertEqual(ProtoFields.boolField(2, false).raw, Data([0x10, 0x00]))
        XCTAssertEqual(ProtoFields.stringField(3, "héllo").raw, Data([0x1A, 0x06]) + Data("héllo".utf8))
        XCTAssertEqual(ProtoFields.bytesField(4, Data([9, 8])).raw, Data([0x22, 0x02, 9, 8]))

        // A body of 200 bytes takes a two-byte length.
        let body = Data(repeating: 0x5A, count: 200)
        let message = ProtoFields.messageField(5, body)
        XCTAssertEqual(message.raw.prefix(3), Data([0x2A, 0xC8, 0x01]))
        XCTAssertEqual(message.value, body)
        XCTAssertEqual(ProtoFields.parse(message.raw)?.first, message)
    }

    func testTheLastCopyOfAVarintIsTheOneRead() throws {
        let fields = try XCTUnwrap(ProtoFields.parse(everyWireType().data))
        XCTAssertEqual(ProtoFields.varint(1, in: fields), 7)
        XCTAssertNil(ProtoFields.varint(99, in: fields), "absent")
        XCTAssertNil(ProtoFields.varint(3, in: fields), "present, but a string")
    }

    // MARK: - Replace, insert, clear

    func testSetReplacesTheFieldWhereItWas() throws {
        let base = ProtoFixture().varint(1, 1).varint(2, 2).varint(3, 3)
        XCTAssertEqual(try patched(base, [.varint(2, 99)]),
                       ProtoFixture().varint(1, 1).varint(2, 99).varint(3, 3).data)
    }

    func testSetReplacesEveryCopyOfAFieldWithOne() throws {
        let base = ProtoFixture().varint(2, 1).string(3, "x").varint(2, 2).varint(2, 3)
        XCTAssertEqual(try patched(base, [.varint(2, 9)]),
                       ProtoFixture().varint(2, 9).string(3, "x").data)
    }

    func testSetReplacesAFieldWhateverWireTypeItWasWrittenWith() throws {
        let base = ProtoFixture().string(2, "not a varint").varint(3, 3)
        XCTAssertEqual(try patched(base, [.varint(2, 4)]), ProtoFixture().varint(2, 4).varint(3, 3).data)
    }

    func testSetInsertsAMissingFieldBeforeTheFirstHigherNumber() throws {
        let base = ProtoFixture().varint(1, 1).varint(5, 5).varint(9, 9)
        XCTAssertEqual(try patched(base, [.varint(3, 3)]),
                       ProtoFixture().varint(1, 1).varint(3, 3).varint(5, 5).varint(9, 9).data)
    }

    func testSetInsertsAtTheEndWhenNothingHasAHigherNumber() throws {
        let base = ProtoFixture().varint(1, 1).varint(5, 5)
        XCTAssertEqual(try patched(base, [.varint(12, 12)]),
                       ProtoFixture().varint(1, 1).varint(5, 5).varint(12, 12).data)
    }

    func testSetInsertsAtTheFrontWhenEverythingHasAHigherNumber() throws {
        let base = ProtoFixture().varint(5, 5).varint(9, 9)
        XCTAssertEqual(try patched(base, [.varint(1, 1)]),
                       ProtoFixture().varint(1, 1).varint(5, 5).varint(9, 9).data)
    }

    func testTheProto3DefaultRemovesTheField() throws {
        let base = ProtoFixture().varint(1, 1).varint(2, 2).varint(3, 3)
        let withoutTwo = ProtoFixture().varint(1, 1).varint(3, 3).data
        XCTAssertEqual(try patched(base, [.varint(2, 0)]), withoutTwo, "0")
        XCTAssertEqual(try patched(base, [.bool(2, false)]), withoutTwo, "false")
        XCTAssertEqual(try patched(base, [.string(2, "")]), withoutTwo, "empty string")
        XCTAssertEqual(try patched(base, [.bytes(2, Data())]), withoutTwo, "empty bytes")
    }

    func testANonDefaultValueIsWrittenAsAField() throws {
        let base = ProtoFixture().varint(1, 1)
        XCTAssertEqual(try patched(base, [.bool(2, true)]), ProtoFixture().varint(1, 1).bool(2, true).data)
        XCTAssertEqual(try patched(base, [.string(2, "x")]), ProtoFixture().varint(1, 1).string(2, "x").data)
        XCTAssertEqual(try patched(base, [.bytes(2, Data([7]))]), ProtoFixture().varint(1, 1).bytes(2, Data([7])).data)
    }

    func testRemovingAFieldThatIsNotThereChangesNothing() throws {
        let base = ProtoFixture().varint(1, 1).varint(3, 3)
        XCTAssertEqual(try patched(base, [.remove(2)]), base.data)
        XCTAssertEqual(try patched(base, [.varint(2, 0)]), base.data)
    }

    func testNoEditsGivesTheSameBytes() throws {
        XCTAssertEqual(try patched(everyWireType(), []), everyWireType().data)
    }

    func testFieldsThatWereNotEditedKeepTheirBytesAndTheirOrder() throws {
        let before = try XCTUnwrap(ProtoFields.parse(everyWireType().data))
        let after = try XCTUnwrap(ProtoFields.parse(try patched(everyWireType(), [.string(3, "changed")])))
        XCTAssertEqual(after.map(\.number), before.map(\.number), "same fields in the same order")
        for (old, new) in zip(before, after) where old.number != 3 {
            XCTAssertEqual(new.raw, old.raw, "field \(old.number) must come back byte for byte")
        }
        XCTAssertEqual(after[2].value, Data("changed".utf8))
    }

    func testFieldsTheCallerHasNeverHeardOfComeBackByteForByte() throws {
        let base = ProtoFixture()
            .fixed32(99, 0x1122_3344)
            .varint(1, 1)
            .bytes(RadioProto.futureField, Data([0xFF, 0x00, 0x7F]))
            .fixed64(ProtoFields.maxFieldNumber, 42)
        let result = try patched(base, [.varint(1, 2)])
        XCTAssertEqual(result, ProtoFixture()
            .fixed32(99, 0x1122_3344)
            .varint(1, 2)
            .bytes(RadioProto.futureField, Data([0xFF, 0x00, 0x7F]))
            .fixed64(ProtoFields.maxFieldNumber, 42).data)
    }

    func testEditsApplyInTheOrderGiven() throws {
        let base = ProtoFixture().varint(1, 1)
        XCTAssertEqual(try patched(base, [.varint(1, 2), .varint(1, 3)]), ProtoFixture().varint(1, 3).data)
        XCTAssertEqual(try patched(base, [.varint(1, 2), .remove(1)]), Data())
        XCTAssertEqual(try patched(base, [.remove(1), .varint(1, 4)]), ProtoFixture().varint(1, 4).data)
    }

    func testAnEditMakesAMessageThatReadsBackAsTheEdit() throws {
        let result = try patched(everyWireType(), [.varint(1, 4_000_000_000)])
        let fields = try XCTUnwrap(ProtoFields.parse(result))
        XCTAssertEqual(ProtoFields.varint(1, in: fields), 4_000_000_000)
        XCTAssertEqual(fields.filter { $0.number == 1 }.count, 1, "the two copies became one")
    }

    // MARK: - Nested messages

    func testANestedEditChangesOneInnerFieldAndKeepsTheOthers() throws {
        let inner = ProtoFixture().varint(1, 1).varint(2, 2).string(3, "keep").fixed32(60, 7)
        let outer = ProtoFixture().varint(1, 9).message(2, inner).varint(3, 3)

        let expectedInner = ProtoFixture().varint(1, 1).varint(2, 22).string(3, "keep").fixed32(60, 7)
        XCTAssertEqual(try patched(outer, [.nested(2, [.varint(2, 22)])]),
                       ProtoFixture().varint(1, 9).message(2, expectedInner).varint(3, 3).data)
    }

    func testANestedEditCreatesTheMessageWhenItIsNotThere() throws {
        let outer = ProtoFixture().varint(1, 9).varint(3, 3)
        XCTAssertEqual(try patched(outer, [.nested(2, [.varint(1, 5)])]),
                       ProtoFixture().varint(1, 9).message(2, ProtoFixture().varint(1, 5)).varint(3, 3).data)
    }

    func testANestedMessageStaysPresentWhenItsLastFieldIsCleared() throws {
        let outer = ProtoFixture().message(2, ProtoFixture().varint(1, 5))
        let result = try patched(outer, [.nested(2, [.varint(1, 0)])])
        XCTAssertEqual(result, Data([0x12, 0x00]), "field 2 present with an empty body")
        XCTAssertEqual(ProtoFields.parse(result)?.first?.number, 2)
    }

    func testANestedEditJoinsCopiesOfTheMessageIntoOne() throws {
        // A message field written twice is one message, the two bodies merged.
        let outer = ProtoFixture()
            .message(2, ProtoFixture().varint(1, 1))
            .varint(3, 3)
            .message(2, ProtoFixture().varint(2, 2))
        let result = try patched(outer, [.nested(2, [.varint(1, 10)])])
        XCTAssertEqual(result, ProtoFixture()
            .message(2, ProtoFixture().varint(1, 10).varint(2, 2))
            .varint(3, 3).data)
    }

    func testANestedEditGoesTwoLevelsDown() throws {
        let deepest = ProtoFixture().varint(1, 13).bool(2, true)
        let middle = ProtoFixture().string(3, "id").message(7, deepest).varint(40, 9)
        let outer = ProtoFixture().varint(1, 1).message(2, middle)

        let result = try patched(outer, [.nested(2, [.nested(7, [.varint(1, 0)])])])

        let expectedMiddle = ProtoFixture().string(3, "id").message(7, ProtoFixture().bool(2, true)).varint(40, 9)
        XCTAssertEqual(result, ProtoFixture().varint(1, 1).message(2, expectedMiddle).data)
    }

    func testANestedEditOfAFieldThatIsNotAMessageIsRefused() {
        let outer = ProtoFixture().varint(2, 5)
        XCTAssertNil(ProtoFields.patch(outer.data, [.nested(2, [.varint(1, 1)])]))
    }

    func testANestedEditOfAMalformedInnerMessageIsRefused() {
        // The inner body is a length-delimited field that claims 5 bytes and has 1.
        let outer = ProtoFixture().message(2, ProtoFixture().raw([0x12, 0x05, 0x01]))
        XCTAssertNotNil(ProtoFields.parse(outer.data), "the outer message is well formed")
        XCTAssertNil(ProtoFields.patch(outer.data, [.nested(2, [.varint(1, 1)])]))
    }

    // MARK: - Malformed input

    private let truncated: [(name: String, bytes: [UInt8])] = [
        ("a tag with no value", [0x08]),
        ("a varint cut off", [0x08, 0x80]),
        ("a tag cut off", [0x80]),
        ("a fixed32 with 3 bytes", [0x15, 1, 2, 3]),
        ("a fixed64 with 7 bytes", [0x11, 1, 2, 3, 4, 5, 6, 7]),
        ("a length that needs 5 bytes and has 1", [0x1A, 0x05, 0x61]),
        ("a length varint cut off", [0x1A, 0x80]),
        ("a length with no bytes after it", [0x1A, 0x01]),
    ]

    func testTruncatedFieldsAreRejected() {
        for (name, bytes) in truncated {
            XCTAssertNil(ProtoFields.parse(Data(bytes)), name)
            XCTAssertNil(ProtoFields.patch(Data(bytes), [.varint(1, 1)]), "patch of \(name)")
        }
    }

    func testAGoodFieldBeforeABadOneDoesNotMakeAPartialResult() {
        let message = ProtoFixture().varint(1, 1).raw([0x1A, 0x05, 0x61])
        XCTAssertNil(ProtoFields.parse(message.data))
        XCTAssertNil(ProtoFields.patch(message.data, [.varint(1, 2)]))
    }

    func testALengthThatCannotBeAnIntIsRejectedWithoutTrapping() {
        let aboveIntMax: [UInt8] = Array(repeating: 0xFF, count: 9) + [0x01]   // UInt64.max
        let equalToIntMax: [UInt8] = Array(repeating: 0xFF, count: 8) + [0x7F] // Int.max
        let oneMoreThanLeft: [UInt8] = [0x04, 0x61, 0x62, 0x63]                // says 4, has 3
        for (name, length) in [("above Int.max", aboveIntMax), ("Int.max", equalToIntMax),
                               ("one more than is left", oneMoreThanLeft)] {
            let message = Data([0x1A] + length)
            XCTAssertNil(ProtoFields.parse(message), name)
            XCTAssertNil(ProtoFields.patch(message, [.nested(3, [])]), "patch with \(name)")
        }
    }

    func testTagsThatAreNotValidAreRejected() {
        let cases: [(name: String, bytes: [UInt8])] = [
            ("field number 0", [0x00, 0x00]),
            ("start-group wire type 3", [0x0B]),
            ("end-group wire type 4", [0x0C]),
            ("wire type 6", [0x0E, 0x00]),
            ("wire type 7", [0x0F, 0x00]),
            ("field number 2^29", [0x80, 0x80, 0x80, 0x80, 0x10, 0x00]),
        ]
        for (name, bytes) in cases {
            XCTAssertNil(ProtoFields.parse(Data(bytes)), name)
        }
        // The highest legal number is accepted.
        let highest = ProtoFixture().varint(ProtoFields.maxFieldNumber, 1).data
        XCTAssertEqual(ProtoFields.parse(highest)?.first?.number, ProtoFields.maxFieldNumber)
    }

    func testAVarintThatDoesNotFitIn64BitsIsRejected() {
        let max: [UInt8] = Array(repeating: 0xFF, count: 9) + [0x01]
        XCTAssertEqual(ProtoFields.parse(Data([0x08] + max))?.first?.varintValue, UInt64.max)

        let tenthByteTooBig: [UInt8] = Array(repeating: 0xFF, count: 9) + [0x02]
        XCTAssertNil(ProtoFields.parse(Data([0x08] + tenthByteTooBig)), "bit 64 set")

        let elevenBytes: [UInt8] = Array(repeating: 0x80, count: 10) + [0x00]
        XCTAssertNil(ProtoFields.parse(Data([0x08] + elevenBytes)), "eleven bytes")
        XCTAssertNil(ProtoFields.parse(Data(elevenBytes + [0x00])), "an eleven-byte tag")
    }

    func testEveryPrefixOfAMessageIsRejectedOrReadsBackAsItself() {
        let message = [UInt8](everyWireType().data)
        var rejected = 0
        for end in 0..<message.count {
            let prefix = Data(message[0..<end])
            if let fields = ProtoFields.parse(prefix) {
                XCTAssertEqual(ProtoFields.serialize(fields), prefix, "prefix of \(end) bytes")
            } else {
                rejected += 1
            }
        }
        XCTAssertGreaterThan(rejected, message.count / 2, "most cut points land inside a field")
    }

    func testArbitraryBytesNeverTrapAndWhatIsAcceptedRoundTrips() {
        // A fixed seed, so a failure is the same failure next time.
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        // Bytes that make tags, lengths and continuation bits likely.
        let alphabet: [UInt8] = [0x00, 0x01, 0x02, 0x05, 0x08, 0x0A, 0x12, 0x15, 0x1A, 0x7F, 0x80, 0xFF, 0xE0, 0x12, 0xC8]
        var accepted = 0
        for _ in 0..<4000 {
            let length = Int(next() % 24)
            let bytes = (0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] }
            let data = Data(bytes)
            if let fields = ProtoFields.parse(data) {
                accepted += 1
                XCTAssertEqual(ProtoFields.serialize(fields), data)
                _ = ProtoFields.patch(data, [.varint(1, 5), .nested(2, [.bool(1, true)]), .remove(3)])
            } else {
                XCTAssertNil(ProtoFields.patch(data, [.varint(1, 5)]))
            }
        }
        XCTAssertGreaterThan(accepted, 100, "the generator should produce some valid messages too")
    }
}
