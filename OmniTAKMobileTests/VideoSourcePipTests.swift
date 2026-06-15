//
//  VideoSourcePipTests.swift
//  OmniTAKMobileTests
//
//  Tests for VideoSource.isActive — the predicate that gates whether
//  the PIP overlay appears on the map screen (issue #88).
//
//  All tests are pure enum logic — no simulator, no VLC, no networking.
//

import XCTest
@testable import OmniTAK

final class VideoSourcePipTests: XCTestCase {

    // MARK: - isActive

    func testNoneIsNotActive() {
        XCTAssertFalse(VideoSource.none.isActive)
    }

    func testRtspIsActive() {
        let src = VideoSource.rtsp(fromString: "rtsp://10.0.0.1:8554/live")
        XCTAssertTrue(src.isActive)
    }

    func testRawH264UdpIsActive() {
        let src = VideoSource.rawH264Udp(validating: 5000)
        XCTAssertTrue(src.isActive)
    }

    func testMpegTsUdpIsActive() {
        let src = VideoSource.mpegTsUdp(validating: 5010)
        XCTAssertTrue(src.isActive)
    }

    // MARK: - Validating factories collapse invalid input to .none

    func testRawH264UdpPortZeroCollapsesToNone() {
        XCTAssertEqual(VideoSource.rawH264Udp(validating: 0), VideoSource.none)
    }

    func testRawH264UdpPortAboveRangeCollapsesToNone() {
        XCTAssertEqual(VideoSource.rawH264Udp(validating: 65536), VideoSource.none)
    }

    func testMpegTsUdpPortZeroCollapsesToNone() {
        XCTAssertEqual(VideoSource.mpegTsUdp(validating: 0), VideoSource.none)
    }

    func testRtspEmptyStringCollapsesToNone() {
        XCTAssertEqual(VideoSource.rtsp(fromString: ""), VideoSource.none)
    }

    func testRtspBlankStringCollapsesToNone() {
        XCTAssertEqual(VideoSource.rtsp(fromString: "   "), VideoSource.none)
    }

    // MARK: - vlcURL

    func testNoneHasNoVlcURL() {
        XCTAssertNil(VideoSource.none.vlcURL)
    }

    func testRawH264UdpVlcURLScheme() {
        // VLC's h264:// scheme forces the raw H264 demuxer.
        let src = VideoSource.rawH264Udp(validating: 5000)
        XCTAssertEqual(src.vlcURL?.absoluteString, "udp://@:5000/h264")
    }

    func testMpegTsUdpVlcURL() {
        let src = VideoSource.mpegTsUdp(validating: 5010)
        XCTAssertEqual(src.vlcURL?.absoluteString, "udp://@:5010")
    }

    func testRtspVlcURLPassedThrough() {
        let urlStr = "rtsp://192.168.1.1:8554/live"
        let src = VideoSource.rtsp(fromString: urlStr)
        XCTAssertEqual(src.vlcURL?.absoluteString, urlStr)
    }

    // MARK: - displayName

    func testDisplayNames() {
        XCTAssertEqual(VideoSource.none.displayName, "Off")
        XCTAssertEqual(VideoSource.rawH264Udp(validating: 5000).displayName, "Raw H264 UDP")
        XCTAssertEqual(VideoSource.mpegTsUdp(validating: 5010).displayName, "MPEG-TS UDP")
        XCTAssertEqual(VideoSource.rtsp(fromString: "rtsp://x:554/live").displayName, "RTSP")
    }
}
