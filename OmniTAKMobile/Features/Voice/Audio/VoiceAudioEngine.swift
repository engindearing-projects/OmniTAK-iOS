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

    // MARK: Gain (TAK-XVoice: fixed +5 dB mic boost on the Inrico BT02 over
    // SCO, on top of the platform voice DSP). Here: operator-adjustable mic
    // and receive boosts plus the BT02 +5 dB, each through a soft limiter so
    // loud peaks are rounded off instead of clipping.
    static let micBoostKey = "voice.micBoostDb"
    static let rxBoostKey = "voice.rxBoostDb"
    static let defaultMicBoostDb: Double = 3
    static let defaultRxBoostDb: Double = 6
    static let bt02MicBoostDb: Double = 5
    private var micGain: Float = 1      // linear, recomputed per burst / route
    private var rxGain: Float = 1

    static func dbSetting(_ key: String, _ def: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.double(forKey: key)
    }

    /// Apply linear gain with a soft knee above 0.9 FS (tanh into 1.0).
    static func applyGain(_ x: inout [Float], _ g: Float) {
        guard g != 1 else { return }
        for i in x.indices {
            let v = x[i] * g
            let a = abs(v)
            if a > 0.9 {
                let soft = 0.9 + 0.1 * Float(tanh(Double((a - 0.9) / 0.1)))
                x[i] = v < 0 ? -soft : soft
            } else {
                x[i] = v
            }
        }
    }

    private func refreshGains() {
        let r = AVAudioSession.sharedInstance().currentRoute
        let bt02 = r.inputs.contains { $0.portType == .bluetoothHFP && $0.portName.uppercased().hasPrefix("B02PTT") }
        let micDb = Self.dbSetting(Self.micBoostKey, Self.defaultMicBoostDb) + (bt02 ? Self.bt02MicBoostDb : 0)
        let rxDb = Self.dbSetting(Self.rxBoostKey, Self.defaultRxBoostDb)
        micGain = Float(pow(10, micDb / 20))
        rxGain = Float(pow(10, rxDb / 20))
    }

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
    /// Recreated with every engine build: a player node moved between
    /// engines was seen reporting .dataPlayedBack immediately after a wake.
    private var tonePlayer = AVAudioPlayerNode()
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
    /// Planned switches/rebuilds post their own config-change notifications;
    /// ignore those for a moment so they don't trigger another rebuild.
    private var quietUntil = Date.distantPast

    private var micMode: MicMode = .off          // queue copy
    private var trailing: [Data] = []
    private var pending = [Float]()
    private var inputConverter: AVAudioConverter?
    private var encoder: AVAudioConverter?
    private var toneToken = 0
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private var txStats: (framesIn: Int, packets: Int, empty: Int, bytes: Int, gated: Int, start: Date) = (0, 0, 0, 0, 0, Date())
    /// Raw mic level per TX burst (before mic boost), split by whether received
    /// audio was playing — shows if the speaker-mic quiets its own mic during RX.
    private struct MicLevelStats { var frames = 0, voiced = 0; var peak: Float = 0, sumSq: Double = 0 }
    private var micDuringRx = MicLevelStats()
    private var micQuiet = MicLevelStats()

    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sampleRate, channels: 1, interleaved: false)!
    private lazy var opusTxFormat: AVAudioFormat = opusFormat(samples: Int(Self.frameSamples))

    var isRunning: Bool { queue.sync { running } }

    static func ts() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
    }

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

    // MARK: - Lifecycle / standby
    //
    // Two profiles, like Android's SCO handling:
    //  - standby: engine STOPPED and the audio session released — no mic and
    //    no output, so nothing is routed to a Bluetooth speaker-mic (neither
    //    the HFP/SCO voice link nor an A2DP stream of silence, which keeps its
    //    amplifier on and hissing). The app stays alive in the background
    //    through its location/bluetooth background modes, and the Mumble
    //    connection keeps running independently of audio.
    //  - active:  .playAndRecord/.voiceChat, voice processing, mic tap. Needed
    //    to transmit, and to play received audio on an HFP-only speaker-mic.
    // Wake-ups: PTT (controller calls activate first) and received audio when
    // the last active route used Bluetooth HFP — RX is held in a buffer of up
    // to 4 s while the link comes up, then played. Back to standby after 5 s
    // with no TX and 8 s with no RX (Android SCO_COOL_DOWN / SCO_HOT).

    enum Profile { case standby, active }
    private var profile: Profile = .active
    private var activateWaiters: [() -> Void] = []
    private var pendingRX: [(packet: Data, speaker: UInt32, slot: Int)] = []
    private var pendingRXSamples = 0
    private var lastTxActivity = Date()
    private var lastRxActivity = Date.distantPast
    /// Whether the most recent ACTIVE route used Bluetooth HFP (a speaker-mic).
    private var hfpOnLastActiveRoute = false
    /// Set by the controller for the whole of a PTT press (ACQUIRING through
    /// release): the engine never drops to standby while it is true.
    private var busy = false
    static let txHoldSeconds: TimeInterval = 5
    static let rxHoldSeconds: TimeInterval = 8
    static let maxPendingRXSamples = 4 * 48_000

    /// True when the engine is in standby (a PTT press is a "cold" start).
    var isStandby: Bool { queue.sync { profile == .standby } }

    // MARK: System-managed session (Apple PushToTalk)
    // The app never activates/deactivates the audio session: the PushToTalk
    // system does, when a transmission starts or a remote participant is set.
    // The engine builds on systemDidActivate() and tears down on
    // systemDidDeactivate(). Received audio in standby asks for a session;
    // the idle timer asks for it to be released.
    enum SessionNeed { case receive }
    /// Main thread: received audio arrived in standby — set a remote participant.
    var onSessionNeeded: ((SessionNeed) -> Void)?
    /// Main thread: idle (no TX 5 s, no RX 8 s) — clear the remote participant.
    var onSessionIdle: (() -> Void)?
    /// Main thread: the system was asked for audio (RX participant or a
    /// transmission) and never activated it — reset the remote participant.
    var onActivationStalled: (() -> Void)?
    private var idleNotified = false
    private var sessionRequested = false
    private var sessionRequestedAt = Date.distantPast
    /// We have named a remote participant to the system (it holds the session
    /// open while RX plays). Named on ANY received audio, also mid-TX: otherwise
    /// the session drops at PTT-up and the re-request races the deactivation.
    private var participantNamed = false
    private var waitersSince: Date?
    private var stallHandled = false
    static let activationStallSeconds: TimeInterval = 2

    /// The PushToTalk system activated the audio session: build the engine.
    func systemDidActivate() {
        queue.async {
            guard self.running else { return }
            self.sessionRequested = false
            self.idleNotified = false
            self.waitersSince = nil
            self.stallHandled = false
            if self.profile == .active && self.engine.isRunning {
                let w = self.activateWaiters; self.activateWaiters.removeAll()
                w.forEach { DispatchQueue.main.async(execute: $0) }
                self.flushPendingRX()
                return
            }
            self.switchProfile(.active, reason: "system activated the audio session")
        }
    }

    /// The PushToTalk system deactivated the audio session: tear down.
    func systemDidDeactivate() {
        queue.async {
            guard self.running, self.profile == .active else { return }
            self.switchProfile(.standby, reason: "system deactivated the audio session")
        }
    }

    /// Drop waiters of a wake-up that won't happen (e.g. transmit refused).
    func cancelActivationWaiters() {
        queue.async { self.activateWaiters.removeAll(); self.waitersSince = nil }
    }
    /// True when the speaker-mic path is Bluetooth HFP.
    var usesBluetoothHFP: Bool { queue.sync { hfpOnLastActiveRoute } }

    func start() throws {
        var thrown: Error?
        queue.sync {
            guard !running else { return }
            do {
                // PushToTalk: set the category only; the system activates the
                // session (and we build the engine) when audio is needed.
                profile = .standby
                try configureSession(.active)
                let r = AVAudioSession.sharedInstance().currentRoute
                hfpOnLastActiveRoute = (r.inputs + r.outputs).contains { $0.portType == .bluetoothHFP }
                running = true
                lastTxActivity = Date()
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
            pendingRX.removeAll(); pendingRXSamples = 0
            sweepTimer?.cancel(); sweepTimer = nil
            teardownGraph()
            // The PushToTalk system owns session activation.
        }
    }

    func setBusy(_ b: Bool) {
        queue.async {
            self.busy = b
            self.idleNotified = false
            self.lastTxActivity = Date()
        }
    }

    /// Bring the engine to ACTIVE (mic + HFP). `completion` runs on main once
    /// it is (immediately if it already is). Counts as TX activity so the idle
    /// timer can't drop back to standby between the wake and PRIMING.
    func activate(_ reason: String, completion: (() -> Void)? = nil) {
        queue.async {
            guard self.running else { return }
            self.lastTxActivity = Date()
            if self.profile == .active && self.engine.isRunning {
                if let c = completion { DispatchQueue.main.async(execute: c) }
                return
            }
            // The session is activated by the PushToTalk system (the caller
            // has requested a transmission); run `completion` when it is.
            if let c = completion { self.activateWaiters.append(c) }
            if self.waitersSince == nil { self.waitersSince = Date(); self.stallHandled = false }
            print("[VoiceAudio] waiting for the system to activate audio — \(reason)")
        }
    }

    /// Must run on `queue`.
    /// Must run on `queue`. A fresh engine on every wake: keeping the graph
    /// across standby and only restarting it was tried — it saved no time
    /// (the wait is engine.start() waiting for the Bluetooth SCO link, ~0.5 s)
    /// and the restarted engine's OUTPUT stayed silent after the PushToTalk
    /// system had torn the session down and brought it back (no RX audio).
    private func switchProfile(_ p: Profile, reason: String) {
        print("[VoiceAudio] \(Self.ts()) \(p == .active ? "waking (active)" : "standby") — \(reason)")
        setGate(.off, 0)
        micMode = .off; trailing.removeAll(); pending.removeAll()
        teardownGraph()
        engine = AVAudioEngine()
        slotMixers = [1: AVAudioMixerNode(), 2: AVAudioMixerNode()]
        tonePlayer = AVAudioPlayerNode()
        profile = p
        if p == .standby {
            print("[VoiceAudio] standby: engine stopped")
            return
        }
        do {
            try configureSession(p)
            try buildAndStart(p)
        } catch {
            print("[VoiceAudio] \(p) start failed: \(error)")
        }
        lastTxActivity = Date()
        let waiters = activateWaiters; activateWaiters.removeAll()
        waiters.forEach { w in DispatchQueue.main.async(execute: w) }
        flushPendingRX()
    }

    private func configureSession(_ p: Profile) throws {
        let session = AVAudioSession.sharedInstance()
        switch p {
        case .active:
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetooth, .defaultToSpeaker])
            try? session.setPreferredIOBufferDuration(0.02)
        case .standby:
            try session.setCategory(.playback, mode: .default, options: [])
        }
        try? session.setPreferredSampleRate(Self.sampleRate)
        // No setActive: the PushToTalk system activates the session.
    }

    /// Build the graph for the CURRENT route and start it. Must run on `queue`.
    private func buildAndStart(_ p: Profile) throws {
        engine.attach(tonePlayer)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: pcmFormat)
        for (slot, m) in slotMixers {
            engine.attach(m)
            engine.connect(m, to: engine.mainMixerNode, format: pcmFormat)
            m.outputVolume = slotVolume[slot] ?? 1
        }
        gateLock.lock(); engineID = ObjectIdentifier(engine); quietUntil = Date().addingTimeInterval(1.0); gateLock.unlock()
        var inDesc = "none (standby)"
        if p == .active {
            let input = engine.inputNode
            // Apple voice processing (AEC/NS/AGC) only for the phone's own
            // mic + speaker, where full duplex needs echo cancellation. On a
            // Bluetooth HFP speaker-mic the mic is away from the speaker and
            // the link handles echo; skipping it saves start-up time (it
            // rebuilds the I/O unit) and stops its AGC pulling levels down.
            let route = AVAudioSession.sharedInstance().currentRoute
            let onBluetooth = (route.inputs + route.outputs).contains { $0.portType == .bluetoothHFP }
            if !onBluetooth {
                do { try input.setVoiceProcessingEnabled(true) } catch {
                    print("[VoiceAudio] voice processing (AEC) unavailable: \(error)")
                }
            }
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
                throw NSError(domain: "VoiceAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
            }
            inputConverter = AVAudioConverter(from: inFormat, to: pcmFormat)
            gateLock.lock(); tapConverter = inputConverter; gateLock.unlock()
            input.installTap(onBus: 0, bufferSize: 960, format: inFormat) { [weak self] buffer, when in
                self?.handleMic(buffer, when: when)
            }
            let r = AVAudioSession.sharedInstance().currentRoute
            hfpOnLastActiveRoute = (r.inputs + r.outputs).contains { $0.portType == .bluetoothHFP }
            inDesc = "\(inFormat.sampleRate) Hz x\(inFormat.channelCount), AEC \(input.isVoiceProcessingEnabled ? "on" : "off")"
        }
        refreshGains()
        engine.prepare()
        try engine.start()
        tonePlayer.play()
        print("[VoiceAudio] \(Self.ts()) started (\(p)), input \(inDesc), route: \(Self.routeDescription())")
    }

    /// Must run on `queue`.
    private func teardownGraph() {
        if profile == .active || inputConverter != nil { engine.inputNode.removeTap(onBus: 0) }
        for s in speakers.values { s.player.stop(); engine.detach(s.player) }
        speakers.removeAll()
        tonePlayer.stop()
        engine.stop()
        if engine.attachedNodes.contains(tonePlayer) { engine.detach(tonePlayer) }
        for m in slotMixers.values where engine.attachedNodes.contains(m) { engine.detach(m) }
        inputConverter = nil
        gateLock.lock(); tapConverter = nil; gateLock.unlock()
    }

    /// Rebuild (same profile) after a route/config change, interruption end or
    /// media reset.
    private func rebuild(_ reason: String, newEngine: Bool = false) {
        queue.async {
            guard self.running, self.profile == .active else { return }   // standby: nothing running
            print("[VoiceAudio] rebuilding engine: \(reason)")
            self.setGate(.off, 0)
            self.micMode = .off; self.trailing.removeAll(); self.pending.removeAll()
            self.teardownGraph()
            self.engine = AVAudioEngine()
            self.slotMixers = [1: AVAudioMixerNode(), 2: AVAudioMixerNode()]
            self.tonePlayer = AVAudioPlayerNode()
            do {
                try self.configureSession(self.profile)
                try self.buildAndStart(self.profile)
            } catch {
                print("[VoiceAudio] rebuild failed: \(error) — retrying in 1 s")
                self.queue.asyncAfter(deadline: .now() + 1) { self.rebuild("retry after failure") }
            }
            DispatchQueue.main.async { self.onEngineRestart?(reason) }
        }
    }

    /// Must run on `queue`.
    private func flushPendingRX() {
        guard !pendingRX.isEmpty else { return }
        let items = pendingRX
        pendingRX.removeAll(); pendingRXSamples = 0
        print("[VoiceAudio] playing \(items.count) buffered packets after wake-up")
        for i in items { decodeAndPlay(i.packet, speaker: i.speaker, slot: i.slot) }
    }

    private func observe() {
        let nc = NotificationCenter.default
        if #available(iOS 17.0, *) {
            // System-wide input mute (call-style sessions; a headset button can
            // toggle it). While on, the mic delivers digital silence.
            // The AINA's main PTT button also sends a headset mute command
            // (alongside its BLE button event), which iOS applies ~10 ms after
            // the transmission starts: undo it while we are transmitting.
            observers.append(nc.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: nil) { [weak self] n in
                let muted = (n.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue
                print("[VoiceAudio] \(Self.ts()) system input mute changed → \(muted.map { $0 ? "MUTED" : "unmuted" } ?? "?")")
                guard muted == true, let self = self else { return }
                self.queue.async {
                    guard self.micMode == .transmit else { return }
                    do {
                        try AVAudioApplication.shared.setInputMuted(false)
                        print("[VoiceAudio] \(Self.ts()) unmuted the system input (transmitting)")
                    } catch { print("[VoiceAudio] unmute failed: \(error)") }
                }
            })
        }
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] n in
            guard let self = self, let e = n.object as? AVAudioEngine else { return }
            self.gateLock.lock()
            let mine = self.engineID == ObjectIdentifier(e), quiet = Date() < self.quietUntil
            self.gateLock.unlock()
            guard mine, !quiet else { return }
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
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] n in
            guard let self = self,
                  let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            // A device came or went (Bluetooth speaker-mic, headset): rebuild so
            // the tap and graph match the new input/output.
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .override else { return }
            let prev = (n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                .inputs.first?.uid
            let now = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            guard prev != now else { return }
            self.rebuild("audio route changed (\(reason.rawValue)): \(Self.routeDescription())")
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
    /// A cue that must be heard even while idle (e.g. emergency sent). If PTT
    /// audio is live it plays through the engine; in standby — no session
    /// under PushToTalk — it briefly activates the app's own session for a
    /// short in-memory clip and releases it afterwards. iOS only allows that
    /// in the foreground; in the background the caller's vibration remains.
    private var cuePlayer: AVAudioPlayer?

    func playCue(_ samples: [Float]) {
        queue.async {
            if self.running, self.profile == .active, self.engine.isRunning {
                DispatchQueue.main.async { self.playTone(samples) }
                return
            }
            let wav = Self.wavData(samples)
            DispatchQueue.main.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setActive(true)
                    let p = try AVAudioPlayer(data: wav)
                    p.volume = 0.5      // on top of the low-level cue: call volume is loud
                    p.prepareToPlay()
                    p.play()
                    self.cuePlayer = p
                    let secs = Double(samples.count) / Self.sampleRate + 0.25
                    DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                        self.cuePlayer = nil
                        let standby = self.queue.sync { self.profile == .standby }
                        if standby { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
                    }
                    print("[VoiceAudio] cue played outside PTT (\(Int(secs * 1000)) ms)")
                } catch {
                    print("[VoiceAudio] cue not playable now (\(error.localizedDescription)) — vibration only")
                }
            }
        }
    }

    /// 16-bit mono PCM WAV at 48 kHz from float samples.
    static func wavData(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8)); d.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for x in samples {
            let v = Int16(max(-1, min(1, x)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    func playTone(_ samples: [Float], padded: Bool = false, completion: ((UInt64) -> Void)? = nil) {
        queue.async {
            // Standby: no audio session (the system owns it) — cues are
            // skipped; the system plays its own PTT sounds.
            guard self.running, self.engine.isRunning, !samples.isEmpty else {
                let now = mach_absolute_time()
                DispatchQueue.main.async { completion?(now) }; return
            }
            let pre = padded ? Int(Self.sampleRate * 0.080) : 0
            let post = padded ? Int(Self.sampleRate * 0.100) : 0
            var all = [Float](repeating: 0, count: pre) + samples + [Float](repeating: 0, count: post)
            #if DEBUG
            // Silent testing: -XVoiceToneGain 0 keeps the whole tone path
            // (timing, completion, TX gate) but plays nothing audible.
            if let g = UserDefaults.standard.object(forKey: "XVoiceToneGain") as? NSNumber ?? (UserDefaults.standard.string(forKey: "XVoiceToneGain").flatMap(Double.init).map { NSNumber(value: $0) }) {
                let gain = Float(truncating: g)
                all = all.map { $0 * gain }
            }
            #endif
            guard let buf = AVAudioPCMBuffer(pcmFormat: self.pcmFormat, frameCapacity: AVAudioFrameCount(all.count)) else {
                let now = mach_absolute_time()
                DispatchQueue.main.async { completion?(now) }; return
            }
            buf.frameLength = AVAudioFrameCount(all.count)
            all.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: all.count) }
            self.toneToken += 1
            let token = self.toneToken
            self.lastTxActivity = Date()   // a playing tone keeps the engine awake
            let player = self.tonePlayer
            if !player.isPlaying { player.play() }
            let started = mach_absolute_time()
            let length = Double(all.count) / Self.sampleRate
            player.scheduleBuffer(buf, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                let now = mach_absolute_time()
                let elapsed = AVAudioTime.seconds(forHostTime: now - started)
                // Never report "played" before the buffer could have played:
                // if the callback is early, wait out the rest (+50 ms) so the
                // TX gate can't open while the tone is still audible.
                let shortfall = elapsed < length ? length - elapsed + 0.05 : 0
                if shortfall > 0 {
                    print(String(format: "[VoiceAudio] tone completion %.0f ms early — waiting it out", shortfall * 1000))
                }
                self?.queue.asyncAfter(deadline: .now() + shortfall) {
                    guard let self = self, self.toneToken == token else { return }
                    let done = now + AVAudioTime.hostTime(forSeconds: shortfall)
                    DispatchQueue.main.async { completion?(done) }
                }
            }
        }
    }

    // MARK: - Transmit

    /// Re-read the boost settings (call after the operator changes them).
    func reloadGains() { queue.async { self.refreshGains() } }

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
            if mode != .off || old != .off { self.lastTxActivity = Date() }
            if mode == .transmit && old != .transmit {
                if #available(iOS 17.0, *) {
                    let app = AVAudioApplication.shared
                    if app.isInputMuted {
                        print("[VoiceAudio] \(Self.ts()) system input was MUTED at TX start — unmuting")
                        do { try app.setInputMuted(false) } catch { print("[VoiceAudio] unmute failed: \(error)") }
                    }
                }
                self.pending.removeAll()
                self.trailing.removeAll()
                self.encoder = self.makeEncoder()
                self.refreshGains()
                self.txStats = (0, 0, 0, 0, 0, Date())
                self.micDuringRx = MicLevelStats(); self.micQuiet = MicLevelStats()
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
                print("[VoiceAudio] TX mic level: during RX \(Self.describe(self.micDuringRx)) | no RX \(Self.describe(self.micQuiet))")
            }
            if mode == .listen && old != .listen { self.pending.removeAll() }
            self.micMode = mode
            self.setGate(mode, gate)
        }
    }

    private static func accumulate(_ st: inout MicLevelStats, _ rms: Float) {
        st.frames += 1
        st.sumSq += Double(rms * rms)
        st.peak = max(st.peak, rms)
        if rms > 0.0056 { st.voiced += 1 }          // above -45 dBFS: speech, not room noise
    }

    private static func describe(_ st: MicLevelStats) -> String {
        guard st.frames > 0 else { return "-" }
        func db(_ x: Double) -> String { x > 0 ? String(format: "%.0f dBFS", 20 * log10(x)) : "silent" }
        let rms = (st.sumSq / Double(st.frames)).squareRoot()
        return "\(st.frames) frames, voiced \(st.voiced * 100 / st.frames)%, rms \(db(rms)), peak \(db(Double(st.peak)))"
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
        gateLock.lock(); var c = tapConverter; gateLock.unlock()
        if c == nil || c!.inputFormat != buffer.format {
            // Route changed (e.g. Bluetooth HFP at 16 kHz) without an engine
            // config notification: adapt to the format actually arriving.
            c = AVAudioConverter(from: buffer.format, to: pcmFormat)
            gateLock.lock(); tapConverter = c; gateLock.unlock()
            print("[VoiceAudio] mic format now \(buffer.format.sampleRate) Hz x\(buffer.format.channelCount)")
        }
        guard let conv = c else { return [] }
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
                var fsum: Float = 0
                for v in frame { fsum += v * v }
                let frms = (fsum / Float(n)).squareRoot()
                let rxOn = Date().timeIntervalSince(lastRxActivity) < 0.3
                if rxOn { Self.accumulate(&micDuringRx, frms) } else { Self.accumulate(&micQuiet, frms) }
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
                var boosted = frame
                Self.applyGain(&boosted, micGain)
                guard let packet = encode(boosted) else { txStats.empty += 1; continue }
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
        guard running, !packet.isEmpty else { return }
        lastRxActivity = Date()
        // Standby: hold RX (≤4 s) and wake the audio path.
        if profile == .standby {
            pendingRX.append((packet, key, slot))
            pendingRXSamples += Self.opusSamples(packet) ?? 960
            while pendingRXSamples > Self.maxPendingRXSamples, !pendingRX.isEmpty {
                pendingRXSamples -= Self.opusSamples(pendingRX.removeFirst().packet) ?? 960
            }
            if !sessionRequested {
                sessionRequested = true
                sessionRequestedAt = Date()
                participantNamed = true
                stallHandled = false
                print("[VoiceAudio] incoming audio in standby — asking the system for a session")
                DispatchQueue.main.async { self.onSessionNeeded?(.receive) }
            }
            return
        }
        if idleNotified || !participantNamed {
            // Talk resumed after we asked to release, or began while we were
            // transmitting: name the talker so the system keeps the session.
            idleNotified = false
            participantNamed = true
            DispatchQueue.main.async { self.onSessionNeeded?(.receive) }
        }
        guard engine.isRunning else { return }
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
        if rxGain != 1, let ch = out.floatChannelData?[0] {
            var tmp = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            Self.applyGain(&tmp, rxGain)
            tmp.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: tmp.count) }
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
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            // Asked the system for audio and it never came: reset so the next
            // packet / press asks afresh instead of waiting forever.
            if self.profile == .standby, !self.stallHandled {
                let rxStalled = self.sessionRequested && now.timeIntervalSince(self.sessionRequestedAt) > Self.activationStallSeconds
                let txStalled = !self.activateWaiters.isEmpty && (self.waitersSince.map { now.timeIntervalSince($0) > Self.activationStallSeconds } ?? false)
                if rxStalled || txStalled {
                    self.stallHandled = true
                    self.sessionRequested = false
                    self.participantNamed = false
                    print("[VoiceAudio] system never activated audio (\(rxStalled ? "RX" : "TX") request) — resetting the remote participant")
                    DispatchQueue.main.async { self.onActivationStalled?() }
                }
            }
            // Standby with a participant still named and nothing heard: clear it.
            if self.profile == .standby, self.participantNamed, !self.sessionRequested,
               now.timeIntervalSince(self.lastRxActivity) > Self.rxHoldSeconds {
                self.participantNamed = false
                print("[VoiceAudio] no RX \(Int(Self.rxHoldSeconds)) s in standby — clearing the remote participant")
                DispatchQueue.main.async { self.onSessionIdle?() }
            }
            if self.profile == .active, !self.busy, self.micMode == .off, self.activateWaiters.isEmpty,
               now.timeIntervalSince(self.lastTxActivity) > Self.txHoldSeconds,
               now.timeIntervalSince(self.lastRxActivity) > Self.rxHoldSeconds,
               self.speakers.values.allSatisfy({ $0.queued == 0 }) {
                if !self.idleNotified {
                    self.idleNotified = true
                    self.participantNamed = false
                    print("[VoiceAudio] idle (no TX \(Int(Self.txHoldSeconds)) s, no RX \(Int(Self.rxHoldSeconds)) s) — releasing the session")
                    DispatchQueue.main.async { self.onSessionIdle?() }
                }
                return
            }
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
