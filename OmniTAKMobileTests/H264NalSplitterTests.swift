//
//  H264NalSplitterTests.swift
//  OmniTAKMobileTests
//
//  Unit tests for H264NalSplitter — the Annex B NAL depacketiser
//  used by the Raw H264 UDP video backend (issue #40).
//
//  Mirrors the Android test suite:
//  OmniTAK-Android/app/src/test/…/data/uas/H264NalSplitterTest.kt
//
//  All tests are pure data transformations — no network, no VideoToolbox,
//  no simulator required. The splitter is injected directly.
//

import XCTest
@testable import OmniTAK

final class H264NalSplitterTests: XCTestCase {

    // Convenience: build a [UInt8] from Int literals (avoids UInt8() casts).
    private func b(_ ints: Int...) -> [UInt8] {
        ints.map { UInt8($0 & 0xFF) }
    }

    // MARK: - Basic emission

    func testSingleNalFollowedByStartCodeEmitsOneNal() {
        // Buffer: [sc3, 0xAA, 0xBB, sc3, 0xCC]
        // First NAL closes when the second start code arrives.
        let splitter = H264NalSplitter()
        let out = splitter.push(b(0x00, 0x00, 0x01, 0xAA, 0xBB, 0x00, 0x00, 0x01, 0xCC))
        XCTAssertEqual(1, out.count, "One complete NAL should be emitted")
        XCTAssertEqual([UInt8]([0xAA, 0xBB]), Array(out[0]))
    }

    func testIncompleteFirstNalEmitsNothing() {
        // Start code present but no second start code to close the NAL.
        let splitter = H264NalSplitter()
        let out = splitter.push(b(0x00, 0x00, 0x01, 0xAA, 0xBB))
        XCTAssertTrue(out.isEmpty, "Trailing open NAL must not be emitted until closed")
    }

    func testNalSplitAcrossTwoPushesEmitsOnSecond() {
        let splitter = H264NalSplitter()
        let first = splitter.push(b(0x00, 0x00, 0x01, 0xAA, 0xBB))
        XCTAssertTrue(first.isEmpty, "No NAL complete after first datagram")
        let second = splitter.push(b(0xCC, 0x00, 0x00, 0x01, 0xDD))
        XCTAssertEqual(1, second.count)
        XCTAssertEqual([UInt8]([0xAA, 0xBB, 0xCC]), Array(second[0]))
    }

    func testTwoNalsInOnePushEmitsBoth() {
        let splitter = H264NalSplitter()
        // [sc, NAL1-bytes, sc, NAL2-bytes, sc, ...]
        // The final start code opens the third NAL (not yet emitted).
        let out = splitter.push(b(
            0x00, 0x00, 0x01, 0x67,          // SPS NAL header
            0x11, 0x22,
            0x00, 0x00, 0x01, 0x68,          // PPS NAL header
            0x33, 0x44,
            0x00, 0x00, 0x01, 0x65           // IDR NAL header — opens, not emitted yet
        ))
        XCTAssertEqual(2, out.count, "Two NALs closed by two subsequent start codes")
        XCTAssertEqual([UInt8]([0x67, 0x11, 0x22]), Array(out[0]))
        XCTAssertEqual([UInt8]([0x68, 0x33, 0x44]), Array(out[1]))
    }

    // MARK: - 4-byte start code (00 00 00 01)

    func testFourByteStartCode() {
        let splitter = H264NalSplitter()
        // [sc4, 0xAA, 0xBB, sc4, 0xCC]
        let out = splitter.push(b(
            0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB,
            0x00, 0x00, 0x00, 0x01, 0xCC
        ))
        XCTAssertEqual(1, out.count)
        XCTAssertEqual([UInt8]([0xAA, 0xBB]), Array(out[0]))
    }

    func testMixed3And4ByteStartCodes() {
        let splitter = H264NalSplitter()
        // First sc3, second sc4.
        let out = splitter.push(b(
            0x00, 0x00, 0x01, 0xAA, 0xBB,
            0x00, 0x00, 0x00, 0x01, 0xCC
        ))
        XCTAssertEqual(1, out.count)
        XCTAssertEqual([UInt8]([0xAA, 0xBB]), Array(out[0]))
    }

    // MARK: - CABAC trailing zeros

    func testCabacTrailingZerosAbsorbedIntoNextStartCode() {
        // Some encoders pad with extra 0x00 before the next sc3.
        // That 0x00 should not appear in the emitted NAL payload.
        let splitter = H264NalSplitter()
        let out = splitter.push(b(
            0x00, 0x00, 0x01, 0xAA, 0xBB,
            0x00,                              // CABAC trailing zero
            0x00, 0x00, 0x01, 0xCC
        ))
        XCTAssertEqual(1, out.count)
        // Payload should be 0xAA, 0xBB — not 0xAA, 0xBB, 0x00
        XCTAssertEqual([UInt8]([0xAA, 0xBB]), Array(out[0]),
                       "CABAC trailing zero must be absorbed into the 4-byte start code")
    }

    // MARK: - Byte-at-a-time feeding (stress: one byte per push)

    func testByteAtATimeFeedingEmitsCorrectNals() {
        let splitter = H264NalSplitter()
        let stream = b(0x00, 0x00, 0x01, 0xAA, 0xBB, 0x00, 0x00, 0x01, 0xCC)
        var collected: [Data] = []
        for byte in stream {
            collected += splitter.push([byte])
        }
        XCTAssertEqual(1, collected.count)
        XCTAssertEqual([UInt8]([0xAA, 0xBB]), Array(collected[0]))
    }

    // MARK: - Pre-start-code garbage is discarded

    func testGarbageBeforeFirstStartCodeIsDiscarded() {
        let splitter = H264NalSplitter()
        // Raw garbage before any start code.
        let first = splitter.push(b(0xDE, 0xAD, 0xBE, 0xEF))
        XCTAssertTrue(first.isEmpty)
        // Now feed a complete NAL.
        let second = splitter.push(b(0x00, 0x00, 0x01, 0x67, 0x11,
                                     0x00, 0x00, 0x01, 0x68))
        XCTAssertEqual(1, second.count, "Only the valid NAL after the first sc should be emitted")
        XCTAssertEqual([UInt8]([0x67, 0x11]), Array(second[0]))
    }

    // MARK: - Reset

    func testResetClearsPendingState() {
        let splitter = H264NalSplitter()
        // Start a NAL but don't close it.
        _ = splitter.push(b(0x00, 0x00, 0x01, 0xAA))
        splitter.reset()
        // After reset, old bytes must not bleed into new stream.
        let out = splitter.push(b(0x00, 0x00, 0x01, 0xBB, 0xCC,
                                  0x00, 0x00, 0x01, 0xDD))
        XCTAssertEqual(1, out.count)
        XCTAssertEqual([UInt8]([0xBB, 0xCC]), Array(out[0]))
    }

    // MARK: - Empty / degenerate inputs

    func testEmptyPushReturnsEmpty() {
        let splitter = H264NalSplitter()
        XCTAssertTrue(splitter.push([]).isEmpty)
        XCTAssertTrue(splitter.push(Data()).isEmpty)
    }

    func testSingleByteNalPayload() {
        let splitter = H264NalSplitter()
        // Smallest possible NAL: sc + 1 byte + sc.
        let out = splitter.push(b(0x00, 0x00, 0x01, 0x09,
                                  0x00, 0x00, 0x01, 0x67))
        XCTAssertEqual(1, out.count)
        XCTAssertEqual([UInt8]([0x09]), Array(out[0]))
    }

    // MARK: - NAL type classification

    func testNalTypeClassifiesSps() {
        let nal = Data([0x67, 0x42, 0xC0])  // 0x67 & 0x1F == 7 == SPS
        XCTAssertTrue(H264NalSplitter.nalType(of: nal).isSps)
    }

    func testNalTypeClassifiesPps() {
        let nal = Data([0x68, 0xCE])         // 0x68 & 0x1F == 8 == PPS
        XCTAssertTrue(H264NalSplitter.nalType(of: nal).isPps)
    }

    func testNalTypeClassifiesIdr() {
        let nal = Data([0x65, 0xB8])         // 0x65 & 0x1F == 5 == IDR
        XCTAssertTrue(H264NalSplitter.nalType(of: nal).isIdr)
    }

    func testNalTypeClassifiesNonIdr() {
        let nal = Data([0x41, 0x9A])         // 0x41 & 0x1F == 1 == non-IDR
        XCTAssertTrue(H264NalSplitter.nalType(of: nal).isNonIdr)
    }

    func testNalTypeOnEmptyDataReturnsUnknown() {
        XCTAssertEqual(.unknown, H264NalSplitter.nalType(of: Data()))
    }

    // MARK: - Straddling packets (split exactly on start code boundary)

    func testStartCodeStraddlesPacketBoundary() {
        // Packet 1 ends with 0x00 0x00; packet 2 starts with 0x01.
        let splitter = H264NalSplitter()
        _ = splitter.push(b(0x00, 0x00, 0x01, 0xAA, 0xBB, 0x00, 0x00))
        let out = splitter.push(b(0x01, 0xCC))
        // A new start code 00 00 01 was assembled across the boundary —
        // the first NAL (AA BB) should now be emitted.
        XCTAssertEqual(1, out.count, "Start code straddling boundary must be detected")
        XCTAssertEqual([UInt8]([0xAA, 0xBB]), Array(out[0]))
    }

    func testFourByteStartCodeStraddlesPacketBoundary() {
        let splitter = H264NalSplitter()
        _ = splitter.push(b(0x00, 0x00, 0x01, 0xAA, 0x00, 0x00, 0x00))
        let out = splitter.push(b(0x01, 0xBB))
        XCTAssertEqual(1, out.count)
        // CABAC trailing zero absorbed → NAL payload is just 0xAA
        XCTAssertEqual([UInt8]([0xAA]), Array(out[0]))
    }
}
