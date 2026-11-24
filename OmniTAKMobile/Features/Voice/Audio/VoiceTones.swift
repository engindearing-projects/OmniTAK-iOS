//
//  VoiceTones.swift
//  OmniTAKMobile
//
//  Talk Permit Tones (TPT) and PTT cues, synthesized as sine waves (no sampled
//  audio), ported from TAK-XVoice's TptTone / TptToneGenerator with the same
//  segments, levels and envelopes:
//
//  - Permit (TPT): when TX is granted. Peak 0.85, ≤2 ms attack / ≤4 ms
//    release per segment.
//  - Interrupt chirp: replaces the TPT when a peer is already talking
//    (660 → 880 Hz, 60 ms each, peak 0.71).
//  - Deny: PTT refused (not connected / listen-only), 2 × 380→260 Hz slides.
//  - Bonk: the mic never came alive, 305→245 Hz over 250 ms.
//
//  These buffers are played locally only. WHEN they play, and how the mic is
//  kept from transmitting them, is the TX state machine in VoiceController.
//

import Foundation

enum TalkPermitTone: String, CaseIterable, Identifiable {
    case none, astro25, dmr, nextel, nextelAlt, vertex

    static let `default`: TalkPermitTone = .astro25
    static let settingsKey = "voice.tptTone"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .astro25: return "ASTRO 25 (P25)"
        case .dmr: return "DMR / MOTOTRBO"
        case .nextel: return "Nextel (sim)"
        case .nextelAlt: return "Nextel iDEN (alt)"
        case .vertex: return "Vertex Standard"
        }
    }

    static var current: TalkPermitTone {
        UserDefaults.standard.string(forKey: settingsKey).flatMap(TalkPermitTone.init) ?? .default
    }

    /// (frequency Hz, duration ms); 0 Hz = silence.
    fileprivate var segments: [(Double, Int)] {
        switch self {
        case .none: return []
        case .astro25: return [(910, 30), (0, 20), (910, 30), (0, 20), (910, 50)]
        case .dmr: return [(1569, 40), (1046, 40), (1569, 40), (1317, 40)]
        case .nextel: return [(1800, 30), (0, 20), (1800, 30), (0, 20), (1800, 50)]
        case .nextelAlt: return Array(repeating: [(911.0, 25), (1800.0, 25)], count: 5).flatMap { $0 }
        case .vertex: return [(1050, 20), (0, 20), (1050, 20), (0, 20), (1050, 20)]
        }
    }
}

enum VoiceTones {
    static let sampleRate = 48_000.0

    /// The permit tone, or nil for "None".
    static func permit(_ tone: TalkPermitTone = .current) -> [Float]? {
        guard tone != .none else { return nil }
        var out = [Float]()
        for (hz, ms) in tone.segments {
            let n = Int(sampleRate * Double(ms) / 1000)
            if hz <= 0 { out += [Float](repeating: 0, count: n); continue }
            out += sine(hz, n: n, peak: 0.85,
                        attack: min(n / 8, Int(sampleRate * 0.002)),
                        release: min(n / 4, Int(sampleRate * 0.004)))
        }
        return out
    }

    static func interruptChirp() -> [Float] {
        let n = Int(sampleRate * 0.060)
        let a = Int(sampleRate * 0.004), r = Int(sampleRate * 0.010)
        return sine(660, n: n, peak: 0.71, attack: a, release: r) + sine(880, n: n, peak: 0.71, attack: a, release: r)
    }

    /// 305 → 245 Hz over 250 ms.
    static func bonk() -> [Float] { slide(from: 305, to: 245, ms: 250) }

    /// Two 380 → 260 Hz slides with a 50 ms gap (330 ms total).
    static func deny() -> [Float] {
        let one = slide(from: 380, to: 260, ms: 140)
        return one + [Float](repeating: 0, count: Int(sampleRate * 0.05)) + one
    }

    /// Status chirps (TAK-XVoice StatusTones): two 60 ms beeps at -9 dBFS.
    /// Join = ascending 660 → 880 Hz ("you're in"), leave = descending.
    static func joinChirp() -> [Float] { twoBeep(660, 880) }
    static func leaveChirp() -> [Float] { twoBeep(880, 660) }
    /// Voice lost / channel lost use the same double 850 Hz warning chirp.
    static func voiceLost() -> [Float] { timeoutWarning() }

    private static func twoBeep(_ a: Double, _ b: Double) -> [Float] {
        let n = Int(sampleRate * 0.060)
        let att = min(n / 8, Int(sampleRate * 0.002)), rel = min(n / 4, Int(sampleRate * 0.004))
        return sine(a, n: n, peak: 0.355, attack: att, release: rel) + sine(b, n: n, peak: 0.355, attack: att, release: rel)
    }

    /// TX-timeout warning, 5 s before cutoff: two 850 Hz beeps, 50 ms each,
    /// 90 ms apart (190 ms), peak 0.80.
    static func timeoutWarning() -> [Float] {
        let beep = sine(850, n: Int(sampleRate * 0.050), peak: 0.80,
                        attack: Int(sampleRate * 0.002), release: Int(sampleRate * 0.004))
        return beep + [Float](repeating: 0, count: Int(sampleRate * 0.090)) + beep
    }

    /// Emergency-sent cue for a speaker-mic key: alternating 1000 / 700 Hz,
    /// 120 ms each with 60 ms gaps, twice (~1 s), at a LOW peak (0.12, about
    /// -18 dBFS). It plays at the speaker-mic's call volume, which on an
    /// Inrico BT02 is very loud — 0.3 was still painful on device.
    static func emergencyCue() -> [Float] {
        let n = Int(sampleRate * 0.120)
        let gap = [Float](repeating: 0, count: Int(sampleRate * 0.060))
        let a = Int(sampleRate * 0.004), r = Int(sampleRate * 0.010)
        let hi = sine(1000, n: n, peak: 0.12, attack: a, release: r)
        let lo = sine(700, n: n, peak: 0.12, attack: a, release: r)
        let once = hi + gap + lo + gap
        return once + once
    }

    /// TX-timeout cutoff: 500 Hz for 1.2 s, 25 ms attack, 80 ms release, peak 0.80.
    static func timeoutCutoff() -> [Float] {
        sine(500, n: Int(sampleRate * 1.2), peak: 0.80,
             attack: Int(sampleRate * 0.025), release: Int(sampleRate * 0.080))
    }

    static func durationMs(_ samples: [Float]) -> Int { Int(Double(samples.count) / sampleRate * 1000) }

    private static func sine(_ hz: Double, n: Int, peak: Float, attack: Int, release: Int) -> [Float] {
        let step = 2 * Double.pi * hz / sampleRate
        var out = [Float](repeating: 0, count: n)
        let tailStart = n - release
        for i in 0..<n {
            var amp = peak
            if attack > 0 && i < attack { amp *= Float(i) / Float(attack) }
            if release > 0 && i > tailStart { amp *= max(0, 1 - Float(i - tailStart) / Float(release)) }
            out[i] = Float(sin(step * Double(i))) * amp
        }
        return out
    }

    private static func slide(from a: Double, to b: Double, ms: Int) -> [Float] {
        let n = Int(sampleRate * Double(ms) / 1000)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        let edge = Int(sampleRate * 0.004)
        for i in 0..<n {
            let f = a + (b - a) * Double(i) / Double(n)
            phase += 2 * .pi * f / sampleRate
            var amp: Float = 0.85
            if i < edge { amp *= Float(i) / Float(edge) }
            if i > n - edge { amp *= Float(n - i) / Float(edge) }
            out[i] = Float(sin(phase)) * amp
        }
        return out
    }
}
