//
//  VoicePluginTests.swift
//  OmniTAKMobileTests
//
//  Pure-logic coverage for the X Voice plugin: Mumble varints, the hand-rolled
//  protobuf reader/writer, legacy voice packets, Opus packet sizing (10 ms
//  Android XV vs 20 ms frames), a real Opus encode/decode through Apple's
//  codec at both frame sizes, XV usernames, BLE PTT device matching and the
//  talk-permit tone tables.
//

import XCTest
import AVFoundation
import CoreBluetooth
@testable import OmniTAK

final class VoicePluginTests: XCTestCase {

    // MARK: Mumble varint

    func testVarintRoundTrip() {
        let values: [UInt64] = [0, 1, 0x7F, 0x80, 0x3FFF, 0x4000, 0x1F_FFFF, 0x20_0000,
                                0x0FFF_FFFF, 0x1000_0000, 0xFFFF_FFFF, 0x1_0000_0000, UInt64.max >> 1]
        for v in values {
            let d = MumbleVarint.encode(v)
            var i = d.startIndex
            XCTAssertEqual(MumbleVarint.decode(d, &i), v, "value \(v)")
            XCTAssertEqual(i, d.endIndex, "consumed all bytes for \(v)")
        }
    }

    func testVarintEncodedLengths() {
        XCTAssertEqual(MumbleVarint.encode(0x7F).count, 1)
        XCTAssertEqual(MumbleVarint.encode(0x80).count, 2)
        XCTAssertEqual(MumbleVarint.encode(0x4000).count, 3)
        XCTAssertEqual(MumbleVarint.encode(0x20_0000).count, 4)
        XCTAssertEqual(MumbleVarint.encode(0x1000_0000).count, 5)
        XCTAssertEqual(MumbleVarint.encode(0x1_0000_0000).count, 9)
    }

    func testVarintTruncatedReturnsNil() {
        var i = 0
        XCTAssertNil(MumbleVarint.decode(Data([0x80]), &i))      // 2-byte form, 1 byte present
        i = 0
        XCTAssertNil(MumbleVarint.decode(Data(), &i))
    }

    func testVarintNegationPrefixCannotRecurse() {
        // One 0xF8 ("negated varint follows") is valid...
        var i = 0
        XCTAssertEqual(MumbleVarint.decode(Data([0xF8, 0x05]), &i), ~UInt64(5))
        // ...a run of them from a hostile server must be rejected, not recursed
        // into once per byte (that overflowed the stack).
        i = 0
        XCTAssertNil(MumbleVarint.decode(Data([0xF8, 0xF8, 0x05]), &i))
        i = 0
        XCTAssertNil(MumbleVarint.decode(Data(repeating: 0xF8, count: 200_000), &i))
    }

    // MARK: Protobuf

    func testProtoRoundTrip() {
        var w = MumbleProtoWriter()
        w.uint32(1, 60)
        w.string(3, "ALPHA-1---1e374fVS1")
        w.uint32(5, 35)
        w.bool(8, true)
        w.uint(9, 300)
        guard let f = MumbleProtoFields(w.data) else { return XCTFail("parse failed") }
        XCTAssertEqual(f.uint32(1), 60)
        XCTAssertEqual(f.string(3), "ALPHA-1---1e374fVS1")
        XCTAssertEqual(f.uint32(5), 35)
        XCTAssertEqual(f.bool(8), true)
        XCTAssertEqual(f.uint(9), 300)
        XCTAssertFalse(f.has(2))
    }

    func testProtoSkipsFixedFieldsAndRejectsGarbage() {
        // field 2 fixed64, field 3 fixed32, field 4 varint 7
        var d = Data([0x11]) + Data(repeating: 0xAB, count: 8)
        d += Data([0x1D]) + Data(repeating: 0xCD, count: 4)
        d += Data([0x20, 0x07])
        let f = MumbleProtoFields(d)
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.uint(4), 7)
        XCTAssertNil(MumbleProtoFields(Data([0x0A, 0x05, 0x01])))   // length past end
    }

    func testProtoRejectsHugeDeclaredLength() {
        // Field 1, length-delimited, declared length 2^64-1: used to trap in
        // Int(len). Must be rejected as malformed.
        let huge = Data([0x0A]) + Data(repeating: 0xFF, count: 9) + Data([0x01])
        XCTAssertNil(MumbleProtoFields(huge))
        // 2^63 exactly (the smallest value that doesn't fit Int).
        let justOver = Data([0x0A]) + Data(repeating: 0x80, count: 9) + Data([0x01])
        XCTAssertNil(MumbleProtoFields(justOver))
    }

    // MARK: Voice packets

    func testVoicePacketEncodeLayout() {
        let opus = Data([1, 2, 3])
        let p = MumbleVoicePacket.encode(sequence: 2, opus: opus, terminator: false)
        XCTAssertEqual(p, Data([0x80, 0x02, 0x03, 1, 2, 3]))      // 4<<5, seq 2, len 3
        let t = MumbleVoicePacket.encode(sequence: 4, opus: Data(), terminator: true)
        XCTAssertEqual(t, Data([0x80, 0x04, 0xA0, 0x00]))          // len 0 | 0x2000 → 2-byte varint
    }

    func testVoicePacketDecodeInbound() {
        // server → client: header, session 72, seq 10, len 2, opus, + positional junk
        var p = Data([0x80]) + MumbleVarint.encode(72) + MumbleVarint.encode(10) + MumbleVarint.encode(2)
        p += Data([0xF8, 0xFF]) + Data([9, 9, 9, 9])
        let pkt = MumbleVoicePacket.decode(p)
        XCTAssertEqual(pkt?.session, 72)
        XCTAssertEqual(pkt?.sequence, 10)
        XCTAssertEqual(pkt?.opus, Data([0xF8, 0xFF]))
        XCTAssertEqual(pkt?.terminator, false)

        let term = Data([0x80]) + MumbleVarint.encode(72) + MumbleVarint.encode(11) + MumbleVarint.encode(0x2000)
        XCTAssertEqual(MumbleVoicePacket.decode(term)?.terminator, true)
        XCTAssertEqual(MumbleVoicePacket.decode(term)?.opus.count, 0)
    }

    func testVoicePacketRejectsNonOpusAndTruncated() {
        XCTAssertNil(MumbleVoicePacket.decode(Data([0x20, 0x01, 0x01, 0x01])))   // ping-type codec 1
        var short = Data([0x80]) + MumbleVarint.encode(1) + MumbleVarint.encode(1) + MumbleVarint.encode(10)
        short += Data([1, 2])
        XCTAssertNil(MumbleVoicePacket.decode(short))
        XCTAssertNil(MumbleVoicePacket.decode(Data()))
    }

    func testTxSequenceStepIsInTenMsUnits() {
        XCTAssertEqual(VoiceAudioEngine.frameSamples % 480, 0)
        XCTAssertEqual(VoiceAudioEngine.frameSamples / 480, 2, "20 ms frames advance the sequence by 2")
    }

    // MARK: Opus TOC sizing

    func testOpusSamplesFromToc() {
        func toc(config: UInt8, code: UInt8) -> UInt8 { config << 3 | code }
        XCTAssertEqual(VoiceAudioEngine.opusSamples(Data([toc(config: 0, code: 0)])), 480)     // SILK 10 ms
        XCTAssertEqual(VoiceAudioEngine.opusSamples(Data([toc(config: 1, code: 0)])), 960)     // SILK 20 ms
        XCTAssertEqual(VoiceAudioEngine.opusSamples(Data([toc(config: 3, code: 0)])), 2880)    // SILK 60 ms
        XCTAssertEqual(VoiceAudioEngine.opusSamples(Data([toc(config: 12, code: 0)])), 480)    // Hybrid 10 ms
        XCTAssertEqual(VoiceAudioEngine.opusSamples(Data([toc(config: 13, code: 0)])), 960)    // Hybrid 20 ms
        XCTAssertEqual(VoiceAudioEngine.opusSamples(Data([toc(config: 30, code: 0)])), 480)    // CELT 10 ms
        XCTAssertEqual(VoiceAudioEngine.opusSamples(Data([toc(config: 31, code: 0)])), 960)    // CELT 20 ms
        XCTAssertEqual(VoiceAudioEngine.opusSamples(Data([toc(config: 31, code: 1)])), 1920)   // 2 frames
        XCTAssertEqual(VoiceAudioEngine.opusSamples(Data([toc(config: 30, code: 3), 0x03])), 1440)  // 3 × 10 ms
        XCTAssertNil(VoiceAudioEngine.opusSamples(Data([toc(config: 31, code: 3)])))           // count byte missing
        XCTAssertNil(VoiceAudioEngine.opusSamples(Data([toc(config: 31, code: 3), 0x07])))     // 140 ms > 120 ms
        XCTAssertNil(VoiceAudioEngine.opusSamples(Data()))
    }

    // MARK: Apple Opus codec, both frame sizes

    private func opusFormat(_ samples: UInt32) -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: samples, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)!
    }
    private let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    /// Encode a 440 Hz tone at `samples` per packet; return the packets.
    private func encodeTone(samplesPerPacket n: UInt32, packets: Int) throws -> [Data] {
        let enc = try XCTUnwrap(AVAudioConverter(from: pcm, to: opusFormat(n)))
        var out: [Data] = []
        var phase = 0.0
        for _ in 0..<(packets + 4) {   // extra input for encoder lookahead
            let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: n)!
            buf.frameLength = n
            for i in 0..<Int(n) { phase += 2 * .pi * 440 / 48_000; buf.floatChannelData![0][i] = Float(sin(phase)) * 0.5 }
            let comp = AVAudioCompressedBuffer(format: opusFormat(n), packetCapacity: 1, maximumPacketSize: 1500)
            var fed = false
            var err: NSError?
            _ = enc.convert(to: comp, error: &err) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return buf
            }
            XCTAssertNil(err)
            if comp.packetCount > 0 { out.append(Data(bytes: comp.data, count: Int(comp.byteLength))) }
            if out.count == packets { break }
        }
        return out
    }

    /// Decode with a persistent per-stream decoder, as the app does per talker.
    private func decode(_ packet: Data, samples: Int, with dec: AVAudioConverter) throws -> AVAudioFrameCount {
        let fmt = opusFormat(UInt32(samples))
        let inBuf = AVAudioCompressedBuffer(format: fmt, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { inBuf.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        inBuf.byteLength = UInt32(packet.count)
        inBuf.packetCount = 1
        inBuf.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                         mDataByteSize: UInt32(packet.count))
        let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 5760)!
        var fed = false
        var err: NSError?
        _ = dec.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        XCTAssertNil(err, "decode error")
        return out.frameLength
    }

    func testOpusTwentyMsEncodeDecode() throws {
        let packets = try encodeTone(samplesPerPacket: 960, packets: 5)
        XCTAssertEqual(packets.count, 5)
        try assertStreamDecodes(packets, samples: 960)
    }

    /// The Android XV case: 10 ms packets must decode with a 480-sample decoder.
    func testOpusTenMsEncodeDecode() throws {
        let packets = try encodeTone(samplesPerPacket: 480, packets: 5)
        try XCTSkipIf(packets.isEmpty, "this Opus encoder doesn't produce 10 ms packets")
        try assertStreamDecodes(packets, samples: 480)
    }

    /// Every packet sizes correctly from its TOC and decodes through one
    /// decoder. Apple's decoder withholds 120 samples (2.5 ms) of the first
    /// packet of a stream; after that each packet yields its full size.
    private func assertStreamDecodes(_ packets: [Data], samples n: Int) throws {
        let dec = try XCTUnwrap(AVAudioConverter(from: opusFormat(UInt32(n)), to: pcm))
        for (i, p) in packets.enumerated() {
            XCTAssertEqual(VoiceAudioEngine.opusSamples(p), n)
            let got = Int(try decode(p, samples: n, with: dec))
            if i == 0 { XCTAssertGreaterThanOrEqual(got, n - 120, "first packet") }
            else { XCTAssertEqual(got, n, "packet \(i)") }
        }
    }

    // MARK: Identity

    func testUsernameFormat() {
        let u1 = MumbleClient.username(callsign: "ALPHA 1", deviceUid: "IOS-TEST", slot: 1)
        let u2 = MumbleClient.username(callsign: "ALPHA 1", deviceUid: "IOS-TEST", slot: 2)
        XCTAssertTrue(u1.hasPrefix("ALPHA_1---"))
        XCTAssertTrue(u1.hasSuffix("VS1"))
        XCTAssertTrue(u2.hasSuffix("VS2"))
        XCTAssertEqual(u1.count, "ALPHA_1---".count + 6 + 3)
        XCTAssertEqual(u1.dropLast(3), u2.dropLast(3), "same device hash for both slots")
        XCTAssertTrue(MumbleClient.username(callsign: "", deviceUid: "x").hasPrefix("ATAK---"))
        XCTAssertEqual(MumbleClient.displayName("FANTOM---d5e350VS1"), "FANTOM")
        XCTAssertEqual(MumbleClient.displayName("desktop-user"), "desktop-user")
    }

    // MARK: BLE PTT matching

    func testBlePttClassify() {
        XCTAssertEqual(BLEPTTManager.classify(name: "APTT-1234", services: []), .ainaV2)
        XCTAssertEqual(BLEPTTManager.classify(name: "B02PTT-xyz", services: []), .bt02)
        XCTAssertEqual(BLEPTTManager.classify(name: "Pryme BT-PTT-Z", services: []), .pryme)
        XCTAssertEqual(BLEPTTManager.classify(name: "PTT-Z", services: [CBUUID(string: "FFE0")]), .pryme)
        // FFE0 alone is a generic UART service: never a PTT button without the name.
        XCTAssertNil(BLEPTTManager.classify(name: nil, services: [CBUUID(string: "FFE0")]))
        XCTAssertNil(BLEPTTManager.classify(name: "HMSoft", services: [CBUUID(string: "FFE0")]))
        XCTAssertNil(BLEPTTManager.classify(name: "AirPods Pro", services: []))
    }

    // MARK: Tones

    func testPermitToneDurations() {
        func ms(_ t: TalkPermitTone) -> Int? { VoiceTones.permit(t).map(VoiceTones.durationMs) }
        XCTAssertNil(VoiceTones.permit(.none))
        XCTAssertEqual(ms(.astro25), 150)
        XCTAssertEqual(ms(.dmr), 160)
        XCTAssertEqual(ms(.nextel), 150)
        XCTAssertEqual(ms(.nextelAlt), 250)
        XCTAssertEqual(ms(.vertex), 100)
        XCTAssertEqual(VoiceTones.durationMs(VoiceTones.interruptChirp()), 120)
        XCTAssertEqual(VoiceTones.durationMs(VoiceTones.bonk()), 250)
        XCTAssertEqual(VoiceTones.durationMs(VoiceTones.deny()), 330)
    }

    func testTonesStayInRangeAndStartSilent() {
        for t in TalkPermitTone.allCases {
            guard let s = VoiceTones.permit(t) else { continue }
            XCTAssertLessThanOrEqual(s.map(abs).max() ?? 0, 0.86, "\(t) peak")
            XCTAssertEqual(s.first ?? 1, 0, accuracy: 0.01, "\(t) starts at zero (no click)")
        }
    }

    // MARK: BLE button decoding

    func testAinaDecodeEdges() {
        typealias K = BLEPTTManager.Kind
        var (ev, m) = BLEPTTManager.decodeButtons(kind: K.ainaV2, byte: 0x01, previousAinaMask: 0)
        XCTAssertEqual(ev, [.pttDown(slot: 1)])
        (ev, m) = BLEPTTManager.decodeButtons(kind: K.ainaV2, byte: 0x81, previousAinaMask: m)   // heartbeat bit only
        XCTAssertEqual(ev, [])
        (ev, m) = BLEPTTManager.decodeButtons(kind: K.ainaV2, byte: 0x05, previousAinaMask: m)   // + PTTS
        XCTAssertEqual(ev, [.pttDown(slot: 2)])
        (ev, m) = BLEPTTManager.decodeButtons(kind: K.ainaV2, byte: 0x00, previousAinaMask: m)   // both released
        XCTAssertEqual(ev, [.pttUp(slot: 1), .pttUp(slot: 2)])
        (ev, m) = BLEPTTManager.decodeButtons(kind: K.ainaV2, byte: 0x02, previousAinaMask: m)
        XCTAssertEqual(ev, [.emergency(down: true)])
        (ev, m) = BLEPTTManager.decodeButtons(kind: K.ainaV2, byte: 0x20, previousAinaMask: m)   // PTTE up, MFB (unmapped)
        XCTAssertEqual(ev, [.emergency(down: false)])
        XCTAssertEqual(m, 0x20)
    }

    func testPrymeAndBt02Decode() {
        XCTAssertEqual(BLEPTTManager.decodeButtons(kind: .pryme, byte: 0x01, previousAinaMask: 0).0, [.pttDown(slot: 1)])
        XCTAssertEqual(BLEPTTManager.decodeButtons(kind: .pryme, byte: 0x00, previousAinaMask: 0).0, [.pttUp(slot: 1)])
        XCTAssertEqual(BLEPTTManager.decodeButtons(kind: .bt02, byte: 0x01, previousAinaMask: 0).0, [.pttDown(slot: 1)])
        XCTAssertEqual(BLEPTTManager.decodeButtons(kind: .bt02, byte: 0x00, previousAinaMask: 0).0, [.pttUp(slot: 1)])
        XCTAssertEqual(BLEPTTManager.decodeButtons(kind: .bt02, byte: 0x08, previousAinaMask: 0).0,
                       [.emergency(down: true), .emergency(down: false)])
        XCTAssertEqual(BLEPTTManager.decodeButtons(kind: .bt02, byte: 0x03, previousAinaMask: 0).0, [.function(code: 0x03)])   // top button
        XCTAssertEqual(BLEPTTManager.decodeButtons(kind: .bt02, byte: 0x02, previousAinaMask: 0).0, [.function(code: 0x02)])
        XCTAssertEqual(BLEPTTManager.decodeButtons(kind: .bt02, byte: 0x04, previousAinaMask: 0).0, [.function(code: 0x04)])
        XCTAssertEqual(BLEPTTManager.decodeButtons(kind: .bt02, byte: 0x7F, previousAinaMask: 0).0, [])
    }

    // MARK: Emergency press/hold

    func testEmergencyShortPressFires() {
        var t = EmergencyPressTracker()
        let t0 = Date()
        t.press(at: t0)
        XCTAssertEqual(t.release(at: t0.addingTimeInterval(0.3)), .fire)
    }

    func testEmergencyPulseFires() {   // Inrico BT02: down+up at the same instant
        var t = EmergencyPressTracker()
        let t0 = Date()
        t.press(at: t0)
        XCTAssertEqual(t.release(at: t0), .fire)
    }

    func testEmergencyLongHoldCancelsAtThresholdOnce() {
        var t = EmergencyPressTracker()
        let t0 = Date()
        t.press(at: t0)
        XCTAssertEqual(t.thresholdReached(), .cancel)
        XCTAssertEqual(t.thresholdReached(), .none)
        XCTAssertEqual(t.release(at: t0.addingTimeInterval(3)), .none, "release after the threshold cancel does nothing")
    }

    func testEmergencyLateReleaseBeforeTimerCancels() {
        var t = EmergencyPressTracker()
        let t0 = Date()
        t.press(at: t0)
        XCTAssertEqual(t.release(at: t0.addingTimeInterval(1.2)), .cancel)
        XCTAssertEqual(t.thresholdReached(), .none, "a late timer after release does nothing")
    }

    func testEmergencyReleaseWithoutPressIgnored() {
        var t = EmergencyPressTracker()
        XCTAssertEqual(t.release(at: Date()), .none)
    }

    // MARK: TX timeout tones

    func testTimeoutTones() {
        XCTAssertEqual(VoiceTones.durationMs(VoiceTones.timeoutWarning()), 190)
        XCTAssertEqual(VoiceTones.durationMs(VoiceTones.timeoutCutoff()), 1200)
        XCTAssertLessThanOrEqual(VoiceTones.timeoutCutoff().map(abs).max() ?? 0, 0.81)
    }

    func testStatusChirps() {
        XCTAssertEqual(VoiceTones.durationMs(VoiceTones.joinChirp()), 120)
        XCTAssertEqual(VoiceTones.durationMs(VoiceTones.leaveChirp()), 120)
        XCTAssertLessThanOrEqual(VoiceTones.joinChirp().map(abs).max() ?? 0, 0.36)
        XCTAssertEqual(VoiceTones.durationMs(VoiceTones.voiceLost()), 190)
    }

    func testAinaClassifiedByService() {
        XCTAssertEqual(BLEPTTManager.classify(name: "Unnamed",
                       services: [CBUUID(string: "127FACE1-CB21-11E5-93D0-0002A5D5C51B")]), .ainaV2)
    }

    func testGainAndSoftLimiter() {
        var x: [Float] = [0.1, -0.2, 0.5, -0.5, 0.95]
        VoiceAudioEngine.applyGain(&x, 2)
        XCTAssertEqual(x[0], 0.2, accuracy: 1e-6)
        XCTAssertEqual(x[1], -0.4, accuracy: 1e-6)
        XCTAssertGreaterThan(x[2], 0.9)                 // 1.0 → soft knee
        XCTAssertLessThan(x[2], 1.0)
        XCTAssertEqual(x[3], -x[2], accuracy: 1e-6)     // symmetric
        XCTAssertLessThanOrEqual(abs(x[4]), 1.0)        // never clips past full scale
        var y: [Float] = [0.3]
        VoiceAudioEngine.applyGain(&y, 1)
        XCTAssertEqual(y[0], 0.3)
    }
}
