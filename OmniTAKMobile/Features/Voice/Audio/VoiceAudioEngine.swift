//
//  VoiceAudioEngine.swift
//  OmniTAKMobile
//
//  Microphone capture + Opus encode (transmit) and Opus decode + playback
//  (receive) for the voice plugin. Uses Apple's built-in Opus codec through
//  AVAudioConverter (kAudioFormatOpus) — no third-party codec. TX: 48 kHz
//  mono, 20 ms frames. RX: any Opus frame size (Android XV sends 10 ms).
//
//  Threading: every engine/graph/codec mutation happens on `queue`. The mic
//  tap thread only reads the TX gate through `gateLock`.
//
//  Echo: voice processing (Apple's AEC/AGC/NS) is enabled on the input node,
//  so received audio from the speaker is not sent back in full duplex.
//
//  Robustness: the engine is rebuilt after a configuration change (route /
//  Bluetooth HFP connect, sample-rate change), an interruption (call, Siri) and
//  a media-services reset. `onEngineRestart` tells the controller, which aborts
//  any burst in progress.
//
//  Playback: one player per remote speaker (so two talkers mix instead of
//  interleaving), feeding a per-slot mixer (ducking = mixer volume). A speaker
//  whose queued audio exceeds 250 ms has packets dropped so latency can't grow.
//  Idle speakers are freed after 10 s.
//

import AVFoundation
import AudioToolbox

final class VoiceAudioEngine {
    static let sampleRate: Double = 48_000
    static let frameSamples: AVAudioFrameCount = 960        // 20 ms @ 48 kHz
    static let opusBitrate = 40_000
    /// Level applied to a ducked slot (about -12 dB).
    static let duckedVolume: Float = 0.25
    /// Max queued playback per speaker before packets are dropped.
    static let maxBacklogSamples: AVAudioFrameCount = 12_000   // 250 ms
    /// Encoded frames held back before sending (Android TRAILING_FRAMES = 6 ×
    /// 10 ms = 60 ms; here 3 × 20 ms). Discarded at PTT-up (button click).
    static let trailingFrames = 3

    /// Called on `queue` with each encoded Opus packet while transmitting.
    var onEncodedFrame: ((Data) -> Void)?
    /// While `listen`: called on `queue` with (samples, rms on the 16-bit
    /// scale) per mic buffer, for the PRIMING gates. Set via `setMicLevelHandler`.
    private var onMicLevel: ((Int, Float) -> Void)?
    /// Called on main after the engine had to be rebuilt (reason).
    var onEngineRestart: ((String) -> Void)?

    /// What happens to microphone audio (the mic runs whenever the engine runs):
    /// - off:      ignored.
    /// - listen:   measured (priming) and DISCARDED — PRIMING, cold-Bluetooth
    ///             hold and the whole talk-permit tone.
    /// - transmit: encoded and sent through the trailing delay — but only mic
    ///             audio CAPTURED after `notBeforeHost` (tone end + guard +
    ///             input latency). Earlier audio is dropped by its timestamp,
    ///             not by when it happens to arrive.
    enum MicMode { case off, listen, transmit }

    private let queue = DispatchQueue(label: "omnitak.voice.audio")
    private var engine = AVAudioEngine()
    private let tonePlayer = AVAudioPlayerNode()
    private var slotMixers: [Int: AVAudioMixerNode] = [1: AVAudioMixerNode(), 2: AVAudioMixerNode()]
    private var slotVolume: [Int: Float] = [1: 1, 2: 1]

    private struct Speaker {
        let player: AVAudioPlayerNode
        let slot: Int
        var decoder: AVAudioConverter?
        var decoderSamples = 0
        var queued: AVAudioFrameCount = 0
        var lastHeard = Date()
        var dropped = 0
    }
    private var speakers: [UInt32: Speaker] = [:]
    private var sweepTimer: DispatchSourceTimer?

    // TX gate, read on the tap thread.
    private let gateLock = NSLock()
    private var gateMode: MicMode = .off
    private var gateNotBeforeHost: UInt64 = 0
    /// Also under gateLock: read by the tap thread / notification threads,
    /// which must never block on `queue` (removeTap on `queue` waits for the
    /// tap callback to return).
    private var tapConverter: AVAudioConverter?
    private var engineID: ObjectIdentifier?

    private var micMode: MicMode = .off          // queue copy
    private var trailing: [Data] = []
    private var pending = [Float]()
    private var inputConverter: AVAudioConverter?
    private var encoder: AVAudioConverter?
    private var toneToken = 0
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private var txStats: (framesIn: Int, packets: Int, empty: Int, bytes: Int, gated: Int, start: Date) = (0, 0, 0, 0, 0, Date())

    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sampleRate, channels: 1, interleaved: false)!
    private lazy var opusTxFormat: AVAudioFormat = opusFormat(samples: Int(Self.frameSamples))

    var isRunning: Bool { queue.sync { running } }

    #if DEBUG
    /// Self-test leak probe: for the first frames of each burst, measure how
    /// much of the to-be-encoded mic audio sits at the permit tone's frequency.
    var leakProbeHz: Double?
    private var leakProbeLeft = 0
    private var leakProbeIndex = 0

    /// Fraction (0…1) of a frame's energy at `hz` (Goertzel). ~1 for a pure tone.
    static func toneFraction(_ x: [Float], hz: Double, rate: Double = 48_000) -> Double {
        let w = 2 * Double.pi * hz / rate, c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0, energy = 0.0
        for v in x {
            let s0 = Double(v) + c * s1 - s2
            s2 = s1; s1 = s0
            energy += Double(v) * Double(v)
        }
        let power = s1 * s1 + s2 * s2 - c * s1 * s2
        return energy > 0 ? min(1, power / (Double(x.count) * energy / 2)) : 0
    }
    #endif

    // MARK: - Lifecycle

    func start() throws {
        var thrown: Error?
        queue.sync {
            guard !running else { return }
            do {
                try configureSession()
                try buildAndStart()
                running = true
                startSweep()
            } catch { thrown = error }
        }
        if let e = thrown { throw e }
        if observers.isEmpty { observe() }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        queue.sync {
            guard running else { return }
            running = false
            setGate(.off, 0)
            micMode = .off; trailing.removeAll(); pending.removeAll(); encoder = nil
            sweepTimer?.cancel(); sweepTimer = nil
            teardownGraph()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.allowBluetooth, .defaultToSpeaker])
        try? session.setPreferredSampleRate(Self.sampleRate)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    /// Build the graph for the CURRENT route and start it. Must run on `queue`.
    private func buildAndStart() throws {
        let input = engine.inputNode
        do { try input.setVoiceProcessingEnabled(true) } catch {
            print("[VoiceAudio] voice processing (AEC) unavailable: \(error)")
        }
        engine.attach(tonePlayer)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: pcmFormat)
        for (slot, m) in slotMixers {
            engine.attach(m)
            engine.connect(m, to: engine.mainMixerNode, format: pcmFormat)
            m.outputVolume = slotVolume[slot] ?? 1
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "VoiceAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
        }
        inputConverter = AVAudioConverter(from: inFormat, to: pcmFormat)
        gateLock.lock(); tapConverter = inputConverter; engineID = ObjectIdentifier(engine); gateLock.unlock()
        input.installTap(onBus: 0, bufferSize: 960, format: inFormat) { [weak self] buffer, when in
            self?.handleMic(buffer, when: when)
        }
        engine.prepare()
        try engine.start()
        tonePlayer.play()
        print("[VoiceAudio] started, input \(inFormat.sampleRate) Hz x\(inFormat.channelCount), AEC \(input.isVoiceProcessingEnabled ? "on" : "off"), route: \(Self.routeDescription())")
    }

    /// Must run on `queue`.
    private func teardownGraph() {
        engine.inputNode.removeTap(onBus: 0)
        for s in speakers.values { s.player.stop(); engine.detach(s.player) }
        speakers.removeAll()
        tonePlayer.stop()
        engine.stop()
        if engine.attachedNodes.contains(tonePlayer) { engine.detach(tonePlayer) }
        for m in slotMixers.values where engine.attachedNodes.contains(m) { engine.detach(m) }
        inputConverter = nil
        gateLock.lock(); tapConverter = nil; gateLock.unlock()
    }

    /// Rebuild after a route/config change, interruption end or media reset.
    private func rebuild(_ reason: String, newEngine: Bool = false) {
        queue.async {
            guard self.running else { return }
            print("[VoiceAudio] rebuilding engine: \(reason)")
            self.setGate(.off, 0)
            self.micMode = .off; self.trailing.removeAll(); self.pending.removeAll()
            self.teardownGraph()
            if newEngine {
                self.engine = AVAudioEngine()
                self.slotMixers = [1: AVAudioMixerNode(), 2: AVAudioMixerNode()]
            }
            do {
                try self.configureSession()
                try self.buildAndStart()
            } catch {
                print("[VoiceAudio] rebuild failed: \(error) — retrying in 1 s")
                self.queue.asyncAfter(deadline: .now() + 1) { self.rebuild("retry after failure", newEngine: newEngine) }
            }
            DispatchQueue.main.async { self.onEngineRestart?(reason) }
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] n in
            guard let self = self, let e = n.object as? AVAudioEngine else { return }
            self.gateLock.lock(); let mine = self.engineID == ObjectIdentifier(e); self.gateLock.unlock()
            guard mine else { return }
            self.rebuild("engine configuration changed (route: \(Self.routeDescription()))")
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
            guard let self = self,
                  let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                print("[VoiceAudio] interruption began")
                self.queue.async { self.setGate(.off, 0); self.micMode = .off }
                DispatchQueue.main.async { self.onEngineRestart?("interrupted") }
            } else {
                self.rebuild("interruption ended")
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.rebuild("media services were reset", newEngine: true)
        })
    }

    static func routeDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let ins = route.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let outs = route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        return "in: [\(ins)] out: [\(outs)]"
    }

    // MARK: - Tones

    /// Play a local cue (never transmitted). With `padded`, the buffer is
    /// [80 ms silence][tone][100 ms silence] (Android's TPT pre/post-roll).
    /// `completion(hostTime)` runs on main once the WHOLE buffer has actually
    /// been played (.dataPlayedBack, Android's AudioTrack marker); hostTime is
    /// when that was reported. A newer tone cancels an older one's completion.
    func playTone(_ samples: [Float], padded: Bool = false, completion: ((UInt64) -> Void)? = nil) {
        queue.async {
            guard self.running, self.engine.isRunning, !samples.isEmpty else {
                let now = mach_absolute_time()
                DispatchQueue.main.async { completion?(now) }; return
            }
            let pre = padded ? Int(Self.sampleRate * 0.080) : 0
            let post = padded ? Int(Self.sampleRate * 0.100) : 0
            let all = [Float](repeating: 0, count: pre) + samples + [Float](repeating: 0, count: post)
            guard let buf = AVAudioPCMBuffer(pcmFormat: self.pcmFormat, frameCapacity: AVAudioFrameCount(all.count)) else {
                let now = mach_absolute_time()
                DispatchQueue.main.async { completion?(now) }; return
            }
            buf.frameLength = AVAudioFrameCount(all.count)
            all.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: all.count) }
            self.toneToken += 1
            let token = self.toneToken
            if !self.tonePlayer.isPlaying { self.tonePlayer.play() }
            self.tonePlayer.scheduleBuffer(buf, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                let done = mach_absolute_time()
                self?.queue.async {
                    guard let self = self, self.toneToken == token else { return }
                    DispatchQueue.main.async { completion?(done) }
                }
            }
        }
    }

    // MARK: - Transmit

    func setMicLevelHandler(_ h: ((Int, Float) -> Void)?) {
        queue.async { self.onMicLevel = h }
    }

    /// `notBeforeHost`: for `.transmit`, drop mic audio captured before this
    /// host time (0 = no limit). Input latency is added here.
    func setMicMode(_ mode: MicMode, notBeforeHost: UInt64 = 0) {
        queue.async {
            var gate = notBeforeHost
            if mode == .transmit && gate > 0 {
                let s = AVAudioSession.sharedInstance()
                gate += AVAudioTime.hostTime(forSeconds: s.inputLatency + s.ioBufferDuration)
            }
            let old = self.micMode
            if mode == .transmit && old != .transmit {
                self.pending.removeAll()
                self.trailing.removeAll()
                self.encoder = self.makeEncoder()
                self.txStats = (0, 0, 0, 0, 0, Date())
                #if DEBUG
                if self.leakProbeHz != nil { self.leakProbeLeft = 15; self.leakProbeIndex = 0 }
                #endif
            }
            if old == .transmit && mode != .transmit {
                // PTT-up: drop the held-back frames (button click), like Android.
                let dropped = self.trailing.count
                self.trailing.removeAll()
                self.pending.removeAll()
                let st = self.txStats
                let secs = Date().timeIntervalSince(st.start)
                let kbps = secs > 0 ? Double(st.bytes * 8) / secs / 1000 : 0
                print(String(format: "[VoiceAudio] TX burst: %.1fs, frames %d, sent %d, empty %d, pre-gate mic buffers dropped %d, trailing dropped %d, %d bytes (%.1f kbps)",
                             secs, st.framesIn, st.packets, st.empty, st.gated, dropped, st.bytes, kbps))
            }
            if mode == .listen && old != .listen { self.pending.removeAll() }
            self.micMode = mode
            self.setGate(mode, gate)
        }
    }

    private func setGate(_ mode: MicMode, _ host: UInt64) {
        gateLock.lock(); gateMode = mode; gateNotBeforeHost = host; gateLock.unlock()
    }

    private func makeEncoder() -> AVAudioConverter? {
        guard let enc = AVAudioConverter(from: pcmFormat, to: opusTxFormat) else {
            print("[VoiceAudio] Opus encoder unavailable")
            return nil
        }
        enc.bitRate = Self.opusBitrate
        return enc
    }

    /// Tap thread.
    private func handleMic(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        gateLock.lock()
        let mode = gateMode, notBefore = gateNotBeforeHost
        gateLock.unlock()
        guard mode != .off else { return }

        // Drop (or trim) mic audio captured before the TX gate, by timestamp.
        var skipIn = 0
        if mode == .transmit, notBefore > 0, when.isHostTimeValid {
            let start = when.hostTime
            if start < notBefore {
                let gapSec = AVAudioTime.seconds(forHostTime: notBefore - start)
                skipIn = Int((gapSec * buffer.format.sampleRate).rounded(.up))
                if skipIn >= Int(buffer.frameLength) {
                    queue.async { self.txStats.gated += 1 }
                    return
                }
            }
        }
        let samples = convertToPCM(buffer)
        guard !samples.isEmpty else { return }
        let skipOut = min(samples.count, Int(Double(skipIn) * Self.sampleRate / buffer.format.sampleRate))
        let kept = skipOut > 0 ? Array(samples[skipOut...]) : samples
        queue.async { self.processMic(kept, capturedAs: mode) }
    }

    /// Tap thread. Resample/downmix to 48 kHz mono float.
    private func convertToPCM(_ buffer: AVAudioPCMBuffer) -> [Float] {
        gateLock.lock(); let c = tapConverter; gateLock.unlock()
        guard let conv = c, conv.inputFormat == buffer.format else { return [] }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }

    private func processMic(_ samples: [Float], capturedAs: MicMode) {
        // The mode may have changed since capture; both must agree.
        guard micMode == capturedAs else { return }
        switch micMode {
        case .off:
            return
        case .listen:
            // Measured for PRIMING, then thrown away. Nothing here is encoded.
            var sum: Float = 0
            for x in samples { sum += x * x }
            let rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot() * 32768
            onMicLevel?(samples.count, rms)
        case .transmit:
            pending.append(contentsOf: samples)
            let n = Int(Self.frameSamples)
            while pending.count >= n {
                let frame = Array(pending[0..<n])
                pending.removeFirst(n)
                txStats.framesIn += 1
                #if DEBUG
                if let hz = leakProbeHz, leakProbeLeft > 0 {
                    leakProbeLeft -= 1
                    var sum: Float = 0
                    for v in frame { sum += v * v }
                    let rms = (sum / Float(frame.count)).squareRoot() * 32768
                    let frac = Self.toneFraction(frame, hz: hz)
                    print(String(format: "[SelfTest] TX frame %2d  rms %7.1f  %4.0f Hz share %5.1f%%%@",
                                 leakProbeIndex, rms, hz, frac * 100, (frac > 0.3 && rms > 300) ? "  <-- TONE LEAK" : ""))
                    leakProbeIndex += 1
                }
                #endif
                guard let packet = encode(frame) else { txStats.empty += 1; continue }
                trailing.append(packet)
                while trailing.count > Self.trailingFrames {
                    let out = trailing.removeFirst()
                    txStats.packets += 1; txStats.bytes += out.count
                    onEncodedFrame?(out)
                }
            }
        }
    }

    private func encode(_ frame: [Float]) -> Data? {
        guard let enc = encoder,
              let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: Self.frameSamples) else { return nil }
        pcm.frameLength = Self.frameSamples
        frame.withUnsafeBufferPointer { src in
            pcm.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        let out = AVAudioCompressedBuffer(format: opusTxFormat, packetCapacity: 1, maximumPacketSize: 1500)
        var fed = false
        var err: NSError?
        let status = enc.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return pcm
        }
        guard status != .error, err == nil, out.packetCount > 0, out.byteLength > 0 else { return nil }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }

    // MARK: - Receive

    /// Decode one Opus packet from `speaker` (a per-slot unique key) and queue
    /// it for playback on that slot. Safe to call from any thread.
    func playOpus(_ packet: Data, speaker: UInt32, slot: Int = 1) {
        queue.async { self.decodeAndPlay(packet, speaker: speaker, slot: slot) }
    }

    /// A speaker's transmission ended: reset its decoder (new stream next time).
    func endOfStream(speaker: UInt32) {
        queue.async { self.speakers[speaker]?.decoder = nil }
    }

    /// Duck (lower) or restore one slot's received audio. Full duplex: the
    /// slot you are talking on is never ducked; only the other one.
    func setDucked(slot: Int, _ ducked: Bool) {
        queue.async {
            let v: Float = ducked ? Self.duckedVolume : 1
            self.slotVolume[slot] = v
            self.slotMixers[slot]?.outputVolume = v
        }
    }

    /// Samples (at 48 kHz) in an Opus packet, from its TOC byte (RFC 6716 §3.1).
    static func opusSamples(_ p: Data) -> Int? {
        guard let toc = p.first else { return nil }
        let config = Int(toc >> 3)
        let frame: Int   // samples per frame at 48 kHz
        switch config {
        case 0...11: frame = [480, 960, 1920, 2880][config % 4]       // SILK 10/20/40/60 ms
        case 12...15: frame = config % 2 == 0 ? 480 : 960             // Hybrid 10/20 ms
        default: frame = [120, 240, 480, 960][config % 4]            // CELT 2.5/5/10/20 ms
        }
        let count: Int
        switch toc & 0x03 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard p.count > 1 else { return nil }
            count = Int(p[p.startIndex + 1] & 0x3F)
        }
        let total = frame * count
        return total > 0 && total <= 5760 ? total : nil
    }

    private func opusFormat(samples: Int) -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(samples), mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)!
    }

    private func decodeAndPlay(_ packet: Data, speaker key: UInt32, slot: Int) {
        guard running, engine.isRunning, !packet.isEmpty else { return }
        guard let samples = Self.opusSamples(packet) else {
            print("[VoiceAudio] unparseable Opus packet from \(key) (\(packet.count) B)"); return
        }
        var sp: Speaker
        if let existing = speakers[key] { sp = existing }
        else {
            guard let mixer = slotMixers[slot] ?? slotMixers[1] else { return }
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: mixer, format: pcmFormat)
            p.play()
            sp = Speaker(player: p, slot: slot)
        }
        sp.lastHeard = Date()
        // Bound latency: if this speaker already has >250 ms queued, drop.
        if sp.queued > Self.maxBacklogSamples {
            sp.dropped += 1
            if sp.dropped == 1 || sp.dropped % 50 == 0 { print("[VoiceAudio] speaker \(key) backlog full — dropped \(sp.dropped) packets") }
            speakers[key] = sp
            return
        }
        // Apple's Opus decoder is set up for one packet duration: rebuild when
        // a sender changes it.
        if sp.decoder == nil || sp.decoderSamples != samples {
            guard let d = AVAudioConverter(from: opusFormat(samples: samples), to: pcmFormat) else {
                print("[VoiceAudio] Opus decoder unavailable for \(samples)-sample packets"); return
            }
            sp.decoder = d; sp.decoderSamples = samples
        }
        let dec = sp.decoder!
        let inBuf = AVAudioCompressedBuffer(format: dec.inputFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { inBuf.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        inBuf.byteLength = UInt32(packet.count)
        inBuf.packetCount = 1
        inBuf.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 5760) else { return }
        var fed = false
        var err: NSError?
        let status = dec.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        guard status != .error, err == nil, out.frameLength > 0 else {
            print("[VoiceAudio] decode failed slot \(slot) speaker \(key): status \(status.rawValue) err \(String(describing: err))")
            speakers[key] = sp
            return
        }
        if !sp.player.isPlaying { sp.player.play() }
        let n = out.frameLength
        sp.queued += n
        speakers[key] = sp
        sp.player.scheduleBuffer(out, at: nil, options: [], completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.queue.async {
                guard let self = self, var s = self.speakers[key] else { return }
                s.queued = s.queued > n ? s.queued - n : 0
                self.speakers[key] = s
            }
        }
    }

    /// Free players/decoders of speakers silent for 10 s (e.g. no terminator).
    private func startSweep() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            for (k, s) in self.speakers where now.timeIntervalSince(s.lastHeard) > 10 && s.queued == 0 {
                s.player.stop()
                self.engine.detach(s.player)
                self.speakers[k] = nil
            }
        }
        t.resume()
        sweepTimer = t
    }
}
