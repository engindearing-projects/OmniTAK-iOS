//
//  VoiceAudioEngine.swift
//  OmniTAKMobile
//
//  Microphone capture + Opus encode (transmit) and Opus decode + playback
//  (receive) for the voice plugin. Uses Apple's built-in Opus codec through
//  AVAudioConverter (kAudioFormatOpus), so there is no third-party codec
//  dependency. Wire format: 48 kHz mono, 20 ms frames (960 samples), which is
//  what Mumble clients (including TAK-XVoice on Android) use.
//
//  Bluetooth: the session uses .playAndRecord + .allowBluetooth (HFP), so a
//  paired Bluetooth speaker-mic/headset becomes the mic and speaker when it is
//  connected. Hardware PTT buttons on such devices are NOT handled here yet.
//

import AVFoundation
import AudioToolbox

final class VoiceAudioEngine {
    static let sampleRate: Double = 48_000
    static let frameSamples: AVAudioFrameCount = 960        // 20 ms @ 48 kHz
    static let opusBitrate = 40_000

    /// Called (on an internal queue) with each encoded Opus packet while
    /// transmitting. Arguments: packet bytes.
    var onEncodedFrame: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    /// One player per voice slot so each slot's level can be set on its own
    /// (ducking). Index 1 = slot 1, 2 = slot 2.
    private let players: [Int: AVAudioPlayerNode] = [1: AVAudioPlayerNode(), 2: AVAudioPlayerNode()]
    /// Local-only cue player (talk permit / refusal tones); never ducked and
    /// never transmitted.
    private let tonePlayer = AVAudioPlayerNode()
    private var toneToken = 0

    /// What happens to microphone audio (the mic itself runs whenever the
    /// engine runs, like Android's pre-started capture):
    /// - off:      ignored.
    /// - listen:   measured (priming) and DISCARDED — used for PRIMING, the
    ///             cold-Bluetooth hold and the whole talk-permit tone, so the
    ///             tone can never reach the wire.
    /// - transmit: encoded and sent, through a 60 ms trailing delay.
    enum MicMode { case off, listen, transmit }
    private var micMode: MicMode = .off
    /// While `listen`: called on the audio queue with (samples, rms on the
    /// 16-bit scale) for each mic buffer, for the PRIMING gates.
    var onMicLevel: ((Int, Float) -> Void)?
    /// Encoded frames held back before sending (Android TRAILING_FRAMES = 6 ×
    /// 10 ms = 60 ms; here 3 × 20 ms). Discarded at PTT-up to swallow the
    /// button click.
    static let trailingFrames = 3
    private var trailing: [Data] = []
    /// Level applied to a ducked slot (about -12 dB).
    static let duckedVolume: Float = 0.25
    private let queue = DispatchQueue(label: "omnitak.voice.audio")

    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sampleRate, channels: 1, interleaved: false)!
    private lazy var opusFormat: AVAudioFormat = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: Self.frameSamples, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)!
    }()

    private var inputConverter: AVAudioConverter?     // mic format -> 48k mono float
    private var encoder: AVAudioConverter?            // 48k float -> Opus
    private var decoders: [UInt32: AVAudioConverter] = [:]   // per-speaker Opus -> 48k float
    private var decoderSamples: [UInt32: Int] = [:]          // packet duration each decoder was built for
    private var pending = [Float]()                   // mic samples awaiting a full 20 ms frame
    private(set) var isRunning = false
    private var txStats: (framesIn: Int, packets: Int, empty: Int, bytes: Int, start: Date) = (0, 0, 0, 0, Date())

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.allowBluetooth, .defaultToSpeaker])
        try session.setPreferredSampleRate(Self.sampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        engine.attach(tonePlayer)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: pcmFormat)
        for p in players.values {
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: pcmFormat)
            p.volume = 1
        }

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        inputConverter = AVAudioConverter(from: inFormat, to: pcmFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
        engine.prepare()
        try engine.start()
        players.values.forEach { $0.play() }
        tonePlayer.play()
        isRunning = true
        print("[VoiceAudio] started, input \(inFormat.sampleRate) Hz x\(inFormat.channelCount), route: \(Self.routeDescription())")
    }

    func stop() {
        guard isRunning else { return }
        queue.sync { micMode = .off; trailing.removeAll() }
        engine.inputNode.removeTap(onBus: 0)
        players.values.forEach { $0.stop() }
        tonePlayer.stop()
        engine.stop()
        players.values.forEach { engine.detach($0) }
        engine.detach(tonePlayer)
        queue.sync {
            decoders.removeAll(); decoderSamples.removeAll()
            encoder = nil
            pending.removeAll()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    static func routeDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let ins = route.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let outs = route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        return "in: [\(ins)] out: [\(outs)]"
    }

    // MARK: - Tones

    /// Play a local cue. With `padded`, the buffer is [80 ms silence][tone]
    /// [100 ms silence] (Android's TPT pre/post-roll). `completion` runs on
    /// main once the WHOLE buffer has actually been played out of the speaker
    /// (.dataPlayedBack — the equivalent of Android's AudioTrack marker), not
    /// when it was scheduled. A newer tone cancels an older one's completion.
    func playTone(_ samples: [Float], padded: Bool = false, completion: (() -> Void)? = nil) {
        guard isRunning, !samples.isEmpty else { DispatchQueue.main.async { completion?() }; return }
        let pre = padded ? Int(Self.sampleRate * 0.080) : 0
        let post = padded ? Int(Self.sampleRate * 0.100) : 0
        let all = [Float](repeating: 0, count: pre) + samples + [Float](repeating: 0, count: post)
        guard let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(all.count)) else {
            DispatchQueue.main.async { completion?() }; return
        }
        buf.frameLength = AVAudioFrameCount(all.count)
        all.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: all.count) }
        toneToken += 1
        let token = toneToken
        tonePlayer.scheduleBuffer(buf, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.toneToken == token else { return }
                completion?()
            }
        }
    }

    // MARK: - Transmit

    func setMicMode(_ mode: MicMode) {
        queue.async {
            let old = self.micMode
            if mode == .transmit && old != .transmit {
                self.pending.removeAll()
                self.trailing.removeAll()
                self.encoder = self.makeEncoder()
                self.txStats = (0, 0, 0, 0, Date())
            }
            if old == .transmit && mode != .transmit {
                // PTT-up: drop the held-back frames (button click), like Android.
                let dropped = self.trailing.count
                self.trailing.removeAll()
                self.pending.removeAll()
                let st = self.txStats
                let secs = Date().timeIntervalSince(st.start)
                let kbps = secs > 0 ? Double(st.bytes * 8) / secs / 1000 : 0
                print(String(format: "[VoiceAudio] TX burst: %.1fs, frames in %d, packets sent %d, empty encodes %d, trailing dropped %d, %d bytes (%.1f kbps)",
                             secs, st.framesIn, st.packets, st.empty, dropped, st.bytes, kbps))
            }
            if mode == .listen && old != .listen { self.pending.removeAll() }
            self.micMode = mode
        }
    }

    private func makeEncoder() -> AVAudioConverter? {
        guard let enc = AVAudioConverter(from: pcmFormat, to: opusFormat) else {
            print("[VoiceAudio] Opus encoder unavailable")
            return nil
        }
        enc.bitRate = Self.opusBitrate
        return enc
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard micMode != .off, let conv = inputConverter else { return }
        // Resample/downmix to 48 kHz mono float.
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        queue.async { self.processMic(samples) }
    }

    private func processMic(_ samples: [Float]) {
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
                guard let packet = encode(frame) else { txStats.empty += 1; continue }
                trailing.append(packet)
                // Send only once more than `trailingFrames` are queued.
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
        let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: 1500)
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

    /// Decode one Opus packet from `speaker` (Mumble session id) and queue it
    /// for playback. Safe to call from any thread.
    func playOpus(_ packet: Data, speaker: UInt32, slot: Int = 1) {
        queue.async { self.decodeAndPlay(packet, speaker: speaker, slot: slot) }
    }

    /// Drop the decoder for a speaker whose transmission ended.
    func endOfStream(speaker: UInt32) {
        queue.async { self.decoders[speaker] = nil; self.decoderSamples[speaker] = nil }
    }

    /// Duck (lower) or restore one slot's received audio. Full duplex: the
    /// slot you are talking on is never ducked; only the other one.
    func setDucked(slot: Int, _ ducked: Bool) {
        queue.async { self.players[slot]?.volume = ducked ? Self.duckedVolume : 1 }
    }

    /// Samples (at 48 kHz) in an Opus packet, from its TOC byte (RFC 6716 §3.1).
    /// Senders differ: TAK-XVoice on Android sends 10 ms (480), desktop Mumble
    /// and this app 20 ms (960).
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

    private func decodeAndPlay(_ packet: Data, speaker: UInt32, slot: Int) {
        guard isRunning, !packet.isEmpty else { return }
        guard let samples = Self.opusSamples(packet) else {
            print("[VoiceAudio] unparseable Opus packet from \(speaker) (\(packet.count) B)"); return
        }
        // Apple's Opus decoder is set up for one packet duration, so keep one
        // decoder per (speaker, duration) and rebuild when a sender changes it.
        let dec: AVAudioConverter
        if let d = decoders[speaker], decoderSamples[speaker] == samples { dec = d }
        else {
            let fmt = opusFormat(samples: samples)
            guard let d = AVAudioConverter(from: fmt, to: pcmFormat) else {
                print("[VoiceAudio] Opus decoder unavailable for \(samples)-sample packets"); return
            }
            if decoderSamples[speaker] != nil { print("[VoiceAudio] speaker \(speaker) packet size → \(samples) samples") }
            decoders[speaker] = d; decoderSamples[speaker] = samples; dec = d
        }
        let inBuf = AVAudioCompressedBuffer(format: dec.inputFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { inBuf.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        inBuf.byteLength = UInt32(packet.count)
        inBuf.packetCount = 1
        inBuf.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

        // Opus packets can hold up to 120 ms; size the output for that.
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 5760) else { return }
        var fed = false
        var err: NSError?
        let status = dec.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        guard status != .error, err == nil, out.frameLength > 0 else {
            print("[VoiceAudio] decode failed slot \(slot) speaker \(speaker): status \(status.rawValue) err \(String(describing: err)) frames \(out.frameLength)")
            return
        }
        if let p = players[slot], !p.isPlaying { print("[VoiceAudio] slot \(slot) player not playing — restarting"); p.play() }
        (players[slot] ?? players[1]!).scheduleBuffer(out, completionHandler: nil)
    }
}
