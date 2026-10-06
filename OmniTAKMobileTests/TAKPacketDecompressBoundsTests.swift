//
//  TAKPacketDecompressBoundsTests.swift
//  OmniTAKMobileTests
//
//  The text fields of a TAKPacket are unishox2-compressed bytes that arrive from
//  other radios. The compressed stream alone decides how much text comes out, so
//  the decoder has to be held to the size of its buffer.
//

import XCTest
@testable import OmniTAK

final class TAKPacketDecompressBoundsTests: XCTestCase {

    /// SplitMix64. A fixed sequence, so a failing case can be replayed from its iteration number.
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func bytes(_ count: Int) -> Data {
            var out = Data(capacity: count)
            for _ in 0..<count { out.append(UInt8(truncatingIfNeeded: next())) }
            return out
        }
    }

    // MARK: - The library call itself

    func testRandomBytesNeverWritePastTheLimit() {
        var generator = Generator(state: 0x5EED)
        let limit = 256
        let guardLength = 512
        let canary: CChar = 0x55
        for iteration in 0..<20_000 {
            let input = generator.bytes(10 + Int(generator.next() % 224))
            var buffer = [CChar](repeating: canary, count: limit + guardLength)
            let written = TAKPacketCodec.decompressRaw(input, into: &buffer, limit: limit)
            if written > Int32(limit) + 1 {
                return XCTFail("iteration \(iteration): reported \(written) bytes for a limit of \(limit)")
            }
            if buffer[limit...].contains(where: { $0 != canary }) {
                return XCTFail("iteration \(iteration): wrote past the limit of \(limit) bytes")
            }
        }
    }

    func testAShortLimitIsHonouredForTextThatReallyIsLong() {
        let long = String(repeating: "ALPHA BRAVO ", count: 200)
        let compressed = TAKPacketCodec.compress(long)
        XCTAssertLessThan(compressed.count, long.utf8.count / 4, "the repeats must compress, or this test proves nothing")

        let limit = 64
        let canary: CChar = 0x55
        var buffer = [CChar](repeating: canary, count: limit + 4096)
        let written = TAKPacketCodec.decompressRaw(compressed, into: &buffer, limit: limit)

        XCTAssertGreaterThan(written, Int32(limit), "text that does not fit must be reported as not fitting")
        XCTAssertFalse(buffer[limit...].contains(where: { $0 != canary }), "wrote past the limit")
    }

    // MARK: - The Swift wrapper

    func testTextLongerThanTheLimitIsRefusedAndTextThatFitsStillDecodes() {
        let long = String(repeating: "ALPHA BRAVO ", count: 200)
        let size = long.utf8.count
        let compressed = TAKPacketCodec.compress(long)

        XCTAssertEqual(TAKPacketCodec.decompress(compressed), long)
        XCTAssertEqual(TAKPacketCodec.decompress(compressed, maxOutputBytes: size), long, "an exact fit decodes")
        XCTAssertNil(TAKPacketCodec.decompress(compressed, maxOutputBytes: size - 1))
        XCTAssertNil(TAKPacketCodec.decompress(compressed, maxOutputBytes: 100))
    }

    func testTextAboveTheDefaultLimitIsRefused() {
        let tooLong = String(repeating: "x", count: TAKPacketCodec.maxDecompressedBytes + 1)
        let compressed = TAKPacketCodec.compress(tooLong)
        XCTAssertLessThan(compressed.count, 233, "this much text fits in one LoRa payload once compressed")
        XCTAssertNil(TAKPacketCodec.decompress(compressed))
    }

    func testOrdinaryTextStillRoundTrips() {
        for text in ["ALPHA1", "ANDROID-1234abcd", "Moving to OBJ Bravo", "RTO actual, sitrep?", "Grüße aus Köln", "台灣 第一小隊", "ok 👍"] {
            XCTAssertEqual(TAKPacketCodec.decompress(TAKPacketCodec.compress(text)), text, text)
        }
    }

    func testEmptyInputIsRefused() {
        XCTAssertNil(TAKPacketCodec.decompress(Data()))
        var buffer = [CChar](repeating: 0, count: 8)
        XCTAssertLessThan(TAKPacketCodec.decompressRaw(Data(), into: &buffer, limit: 8), 0)
    }

    // MARK: - The packet decoder, fed hostile fields

    func testAPacketWithGarbageInItsCompressedFieldsDoesNotCrashTheDecoder() {
        var generator = Generator(state: 0xC0FFEE)
        for iteration in 0..<5_000 {
            let packet = Self.compressedGeoChatPacket(
                callsign: generator.bytes(1 + Int(generator.next() % 60)),
                deviceCallsign: generator.bytes(1 + Int(generator.next() % 60)),
                message: generator.bytes(1 + Int(generator.next() % 200)),
                to: generator.bytes(1 + Int(generator.next() % 60)),
                toCallsign: generator.bytes(1 + Int(generator.next() % 60))
            )
            guard let decoded = TAKPacketCodec.decode(packet) else { continue }
            for text in [decoded.callsign, decoded.deviceCallsign, decoded.chatMessage, decoded.chatTo, decoded.chatToCallsign] {
                guard let text else { continue }
                // Four UTF-8 bytes can become one replacement character of three, never more text.
                XCTAssertLessThanOrEqual(
                    text.utf8.count, TAKPacketCodec.maxDecompressedBytes * 3,
                    "iteration \(iteration): a field decoded to \(text.utf8.count) bytes"
                )
            }
        }
    }

    func testAPacketWhoseFieldsExpandPastTheLimitStillDecodesItsOtherFields() {
        let bomb = TAKPacketCodec.compress(String(repeating: "x", count: TAKPacketCodec.maxDecompressedBytes + 1))
        let packet = Self.compressedGeoChatPacket(
            callsign: TAKPacketCodec.compress("ALPHA1"),
            deviceCallsign: TAKPacketCodec.compress("ANDROID-1234abcd"),
            message: bomb,
            to: TAKPacketCodec.compress("All Chat Rooms"),
            toCallsign: Data("BRAVO2".utf8)
        )
        guard let decoded = TAKPacketCodec.decode(packet) else {
            return XCTFail("the packet is well formed and must decode")
        }
        XCTAssertEqual(decoded.callsign, "ALPHA1")
        XCTAssertEqual(decoded.deviceCallsign, "ANDROID-1234abcd")
        XCTAssertNotEqual(decoded.chatMessage?.utf8.count, TAKPacketCodec.maxDecompressedBytes + 1)
    }

    // MARK: - Hand-rolled TAKPacket { is_compressed = true, contact, chat }

    private static func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while v > 0x7F {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    private static func lengthDelimited(_ field: UInt64, _ payload: Data) -> Data {
        varint(field << 3 | 2) + varint(UInt64(payload.count)) + payload
    }

    private static func compressedGeoChatPacket(
        callsign: Data, deviceCallsign: Data, message: Data, to: Data, toCallsign: Data
    ) -> Data {
        let contact = lengthDelimited(1, callsign) + lengthDelimited(2, deviceCallsign)
        let chat = lengthDelimited(1, message) + lengthDelimited(2, to) + lengthDelimited(3, toCallsign)
        return varint(1 << 3 | 0) + varint(1) + lengthDelimited(2, contact) + lengthDelimited(6, chat)
    }
}
