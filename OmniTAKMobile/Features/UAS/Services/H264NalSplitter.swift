//
//  H264NalSplitter.swift
//  OmniTAKMobile
//
//  Splits an H264 Annex B byte stream into complete NAL units.
//
//  Annex B framing: each NAL unit is preceded by a start code —
//  either the 3-byte form `00 00 01` or the 4-byte form `00 00 00 01`.
//  The NAL payload runs until the next start code.
//
//  Bytes are fed in via `push(_:)`. Each call returns 0+ complete NAL
//  units that were closed by the just-received bytes (i.e. a fresh
//  start code arrived after their payload). The trailing, open NAL is
//  held internally until the next push — this is correct for live UDP
//  streaming where we never see EOF.
//
//  Bytes arriving *before* the very first start code are discarded;
//  they're either decoder garbage or the tail of a NAL we joined
//  mid-stream and cannot decode. After the first start code, NAL
//  emission is deterministic.
//
//  Trailing `0x00` (CABAC padding) between NAL units is absorbed into
//  the subsequent start code (detected as the 4-byte form), which is
//  benign for H264 RBSP per ISO 14496-10 Annex B.
//
//  Thread safety: not thread-safe — call from a single network thread.
//
//  Ported from the Android sibling:
//  OmniTAK-Android/app/src/main/kotlin/…/data/uas/H264NalSplitter.kt
//

import Foundation

final class H264NalSplitter {
    // Accumulated bytes (prefix of most recent start code onward, or
    // all bytes if no start code seen yet).
    private var buf = Data()

    // Offset within `buf` where the current NAL's *payload* starts
    // (i.e. the byte right after the start code's `01` byte).
    // -1 = no start code has been seen yet.
    private var payloadBase: Int = -1

    // MARK: - Public API

    /// Feed bytes from the network. Returns NAL unit payloads (without
    /// the leading start code) that were finalized by this push.
    @discardableResult
    func push(_ bytes: Data) -> [Data] {
        buf.append(bytes)
        return drain()
    }

    /// Convenience overload accepting a raw byte buffer.
    @discardableResult
    func push(_ bytes: [UInt8]) -> [Data] {
        push(Data(bytes))
    }

    /// Drop all buffered state. Call on reconnect or stream restart.
    func reset() {
        buf = Data()
        payloadBase = -1
    }

    // MARK: - Internal drain

    private func drain() -> [Data] {
        var out: [Data] = []

        // Start scanning from where the current payload begins
        // (to skip bytes already confirmed as payload from prior pushes).
        // If we have no start code yet, scan from byte 0.
        var i = payloadBase >= 0 ? payloadBase : 0

        while i + 2 < buf.count {
            guard buf[i] == 0x00, buf[i + 1] == 0x00, buf[i + 2] == 0x01 else {
                i += 1
                continue
            }

            // Walk back over any leading 0x00 so that a 4-byte start
            // code (00 00 00 01) is treated as one boundary, not
            // [CABAC-trailing-zero] + [3-byte-sc].
            let floor = payloadBase >= 0 ? payloadBase : 0
            var nalEnd = i
            while nalEnd > floor, buf[nalEnd - 1] == 0x00 {
                nalEnd -= 1
            }

            // Close the in-progress NAL (if any).
            if payloadBase >= 0 {
                let len = nalEnd - payloadBase
                if len > 0 {
                    out.append(Data(buf[payloadBase ..< nalEnd]))
                }
            }

            // The new NAL's payload starts right after the `01` byte.
            payloadBase = i + 3
            i = payloadBase
        }

        // Trim buf to retain only the open (incomplete) NAL.
        if payloadBase > 0 {
            buf = Data(buf[payloadBase...])
            payloadBase = 0   // payload now starts at index 0 of new buf
        } else if payloadBase < 0 {
            // No start code yet — discard to prevent unbounded growth.
            if buf.count > 16_384 {
                buf = Data()
            }
        }
        // payloadBase == 0: buf already starts at the current payload; leave it.

        return out
    }
}

// MARK: - H264NalType helpers

extension H264NalSplitter {
    /// NAL unit type extracted from the first byte of a NAL payload
    /// (the NAL header byte, after the start code). Values from
    /// ISO 14496-10 Table 7-1.
    enum NalType: UInt8 {
        // Coded slices
        case nonIdrSlice = 1
        case idrSlice    = 5
        // Parameter sets
        case sps         = 7
        case pps         = 8
        // Supplemental
        case sei         = 6
        case aud         = 9
        case unknown     = 0xFF

        init(nalByte: UInt8) {
            let typeId = nalByte & 0x1F
            self = NalType(rawValue: typeId) ?? .unknown
        }

        var isSps:    Bool { self == .sps }
        var isPps:    Bool { self == .pps }
        var isIdr:    Bool { self == .idrSlice }
        var isNonIdr: Bool { self == .nonIdrSlice }
        var isSlice:  Bool { isIdr || isNonIdr }
    }

    /// Classify a NAL payload (no start code prefix).
    static func nalType(of nal: Data) -> NalType {
        guard let first = nal.first else { return .unknown }
        return NalType(nalByte: first)
    }
}
