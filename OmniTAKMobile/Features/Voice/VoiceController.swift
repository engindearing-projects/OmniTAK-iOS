//
//  VoiceController.swift
//  OmniTAKMobile
//
//  Ties the voice pieces together for the plugin: two Mumble clients (dual
//  PTT: slot 1 = VS1, slot 2 = VS2, as on TAK-XVoice), the audio engine
//  (mic/speaker/Opus), the BLE PTT button manager, and push-to-talk
//  arbitration. Main-thread ObservableObject that the PTT overlay and the
//  settings screen observe.
//
//  Slot rules (from TAK-XVoice, with its gaps closed):
//  - Slot 1 always exists while the plugin is on and always has priority.
//  - Slot 2 is OFF until the operator picks a second channel. It connects only
//    after slot 1 is connected AND has settled in its channel, and it is taken
//    down whenever slot 1 drops or fails (it comes back with slot 1).
//  - The two slots never share a channel: picks are refused both ways (by id
//    and by configured name). If the server puts them together anyway, PTT 2
//    falls back to slot 1 and slot 2's duplicate received audio is dropped.
//  - Slot 2 failures stay local: a short retry ladder (3 s, 8 s) for Murmur's
//    lingering "ghost" session, then it stays down. Slot 1 is never touched.
//  - One microphone: only one slot transmits at a time; the first press wins.
//    PTT 2 falls back to slot 1 when slot 2 can't carry audio. Nothing
//    transmits while slot 1 is down. A listen-only (suppressed) slot can't
//    transmit.
//  - Within a slot, PTT is an OR-gate over sources (on-screen, Bluetooth).
//  - Full duplex: received audio keeps playing while transmitting (echo is
//    handled by the .voiceChat audio session), and transmitting is never
//    blocked by someone else talking. While transmitting on one slot, the
//    OTHER slot's received audio is ducked; the slot you talk on stays at full
//    level.
//

import Foundation
import AVFoundation
import Combine
import UIKit

enum PTTSource: Hashable { case onScreen, bluetooth }

final class VoiceController: ObservableObject {
    enum ConnState: Equatable { case off, noServer, noCertificate, connecting, connected, reconnecting, failed }

    struct SlotStatus: Equatable {
        var state: ConnState = .off
        var statusLine = "Off"
        var channels: [Channel] = []
        var currentChannelId: UInt32?
        var suppressed = false
        var settled = false
        var currentChannelName: String {
            guard let id = currentChannelId else { return "—" }
            return channels.first { $0.id == id }?.name ?? (id == 0 ? "Lobby" : "Channel \(id)")
        }
    }
    struct Channel: Equatable, Identifiable { let id: UInt32; let name: String }

    /// Index 0 = slot 1 (VS1), index 1 = slot 2 (VS2).
    @Published private(set) var slots = [SlotStatus(), SlotStatus()]
    /// The slot that owns the mic while transmitting (after any PTT 2 → slot 1
    /// fallback), nil otherwise.
    @Published private(set) var transmittingSlot: Int?
    /// The PTT button that started the current burst (1 or 2).
    @Published private(set) var pressedSlot: Int?
    @Published private(set) var activeSpeakers: [String] = []
    @Published private(set) var micPermission = "Unknown"
    @Published private(set) var audioRoute = ""
    @Published var notice: String?

    var statusLine: String { slots[0].statusLine }
    var isTransmitting: Bool { transmittingSlot != nil }

    let blePTT = BLEPTTManager()

    private static func channelKey(_ slot: Int) -> String { "voice.lastChannel.vs\(slot)" }
    private static func channelIdKey(_ slot: Int) -> String { "voice.lastChannelId.vs\(slot)" }

    /// The channel id a slot is set to join, when known (ids are unambiguous;
    /// names can repeat on a server).
    private func configuredId(_ slot: Int) -> UInt32? {
        (UserDefaults.standard.object(forKey: Self.channelIdKey(slot)) as? Int).map { UInt32($0) }
    }

    private func saveChannel(_ slot: Int, id: UInt32, name: String) {
        UserDefaults.standard.set(id == 0 ? "Lobby" : name, forKey: Self.channelKey(slot))
        UserDefaults.standard.set(Int(id), forKey: Self.channelIdKey(slot))
    }

    private func clearChannel(_ slot: Int) {
        UserDefaults.standard.removeObject(forKey: Self.channelKey(slot))
        UserDefaults.standard.removeObject(forKey: Self.channelIdKey(slot))
    }

    /// True if channel (`id`, `name`) is where `slot` is set to go.
    private func isConfigured(_ slot: Int, id: UInt32, name: String) -> Bool {
        if let cid = configuredId(slot) { return cid == id }
        return Self.sameName(configuredName(slot), id == 0 ? "Lobby" : name)
    }
    private weak var bridge: VoiceHostBridge?
    private var clients: [Int: MumbleClient] = [:]
    private let audio = VoiceAudioEngine()
    private var held: [Int: Set<PTTSource>] = [1: [], 2: []]
    private var speakerLastHeard: [UInt32: (slot: Int, session: UInt32, at: Date)] = [:]
    private var speakerTimer: Timer?
    private var routeObserver: NSObjectProtocol?
    private var bleCancellable: AnyCancellable?
    private var started = false
    private var startGeneration = 0
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Mirror of `transmittingSlot` for the audio callback (set on main).
    private var txSlotForAudio: Int?
    /// Same-channel state already logged (so it is logged once per change).
    private var loggedSameChannel = false

    init(bridge: VoiceHostBridge?) {
        self.bridge = bridge
        // Slot 2 became opt-in: clear any VS2 channel an earlier build saved.
        if !UserDefaults.standard.bool(forKey: "voice.vs2OptInMigrated") {
            clearChannel(2)
            UserDefaults.standard.set(true, forKey: "voice.vs2OptInMigrated")
        }
        // One-time migration of the single-slot channel key.
        if let old = UserDefaults.standard.string(forKey: "voice.lastChannel"),
           UserDefaults.standard.string(forKey: Self.channelKey(1)) == nil {
            UserDefaults.standard.set(old, forKey: Self.channelKey(1))
        }
        audio.onEncodedFrame = { [weak self] opus in
            // Hop to main so the clients dictionary is only touched on one thread.
            DispatchQueue.main.async {
                guard let self = self, let s = self.txSlotForAudio else { return }
                if self.dryRun { self.dryRunPackets += 1; return }
                self.clients[s]?.sendVoice(opus)
            }
        }
        blePTT.onEvent = { [weak self] e in
            switch e {
            case .pttDown(let slot): self?.pttDown(slot: slot, source: .bluetooth)
            case .pttUp(let slot): self?.pttUp(slot: slot, source: .bluetooth)
            case .emergency(let down): self?.onEmergencyButton(down: down)
            }
        }
        bleCancellable = blePTT.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        audio.onEngineRestart = { [weak self] reason in
            guard let self = self else { return }
            if self.txState != .idle {
                print("[Voice] audio engine restarted (\(reason)) — ending the burst in progress")
                self.held = [1: [], 2: []]
                self.stopBurst()
            }
            self.audioRoute = VoiceAudioEngine.routeDescription()
        }
        // The on-screen button can't be held while the app isn't active (and a
        // cancelled gesture never reports its release). Hardware/BLE PTT keeps
        // working in the background.
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseOnScreenPTT()
        })
    }

    deinit { lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: - Status chirps (TAK-XVoice StatusTones)
    //  join (ascending) when a slot lands in a channel, leave (descending)
    //  when PTT 2 is turned off, voice-lost (double 850 Hz) when slot 1's
    //  connection drops unexpectedly — which also cuts off a burst in
    //  progress. 5 s cooldown per kind. Setting "voice.statusTones" (default on).

    enum StatusTone: String { case join, leave, voiceLost }
    static let statusTonesKey = "voice.statusTones"
    private var lastStatusTone: [StatusTone: Date] = [:]
    private var lastChannelBySlot: [Int: UInt32] = [:]
    private var slot1WasConnected = false

    private func playStatus(_ kind: StatusTone) {
        let enabled = UserDefaults.standard.object(forKey: Self.statusTonesKey) as? Bool ?? true
        guard enabled, !dryRun else { return }
        let now = Date()
        if let last = lastStatusTone[kind], now.timeIntervalSince(last) < 5 {
            print("[Voice] status tone \(kind) suppressed (cooldown)"); return
        }
        lastStatusTone[kind] = now
        print("[Voice] status tone: \(kind)")
        switch kind {
        case .join: audio.playTone(VoiceTones.joinChirp())
        case .leave: audio.playTone(VoiceTones.leaveChirp())
        case .voiceLost: audio.playTone(VoiceTones.voiceLost())
        }
    }

    // MARK: - Emergency button (ported from TAK-XVoice EmergencyController)
    //
    //  PRESS:                    arm, schedule CANCEL at 1 s.
    //  RELEASE before 1 s:       FIRE the 911 alert (no-op if already active).
    //  HELD to 1 s:              CANCEL immediately (feedback at the threshold);
    //                            the later release does nothing.
    //  A stuck button can't keep firing, and holding the same button is how an
    //  operator affirmatively cancels. The Inrico BT02 key is a one-shot pulse
    //  (down+up), so on that device it always fires.

    static let emergencyLongPress: TimeInterval = EmergencyPressTracker.longPress
    private var emergency = EmergencyPressTracker()
    private var emergencyCancelTimer: DispatchWorkItem?

    func onEmergencyButton(down: Bool) {
        if down {
            emergency.press(at: Date())
            emergencyCancelTimer?.cancel()
            let t = DispatchWorkItem { [weak self] in
                guard let self = self, self.emergency.thresholdReached() == .cancel else { return }
                self.performEmergency(.cancel, detail: "held 1 s")
            }
            emergencyCancelTimer = t
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.emergencyLongPress, execute: t)
            print("[Voice] emergency button pressed (armed)")
        } else {
            emergencyCancelTimer?.cancel(); emergencyCancelTimer = nil
            performEmergency(emergency.release(at: Date()), detail: "released")
        }
    }

    private func performEmergency(_ action: EmergencyPressTracker.Action, detail: String) {
        switch action {
        case .none:
            return
        case .fire:
            print("[Voice] emergency \(detail) — FIRE")
            bridge?.setEmergency(active: true, reason: "speaker-mic emergency button")
            notice = "Emergency alert sent. Hold the emergency button 1 s to cancel."
        case .cancel:
            print("[Voice] emergency \(detail) — CANCEL")
            bridge?.setEmergency(active: false, reason: "speaker-mic emergency long-hold")
            audio.playTone(VoiceTones.deny())
            notice = "Emergency alert cancelled."
        }
    }

    /// If audio is on a supported Bluetooth speaker-mic (Inrico BT02, AINA),
    /// connect its BLE PTT button automatically.
    func autoConnectSpeakerMicButton() {
        let r = AVAudioSession.sharedInstance().currentRoute
        guard let port = (r.inputs + r.outputs).first(where: { $0.portType == .bluetoothHFP }) else { return }
        blePTT.autoConnect(matching: port.portName)
    }

    func reloadAudioLevels() { audio.reloadGains() }

    /// Release every on-screen PTT hold (gesture cancelled / view gone / app inactive).
    func releaseOnScreenPTT() {
        for slot in [1, 2] where held[slot, default: []].contains(.onScreen) {
            pttUp(slot: slot, source: .onScreen)
        }
    }

    // MARK: - Slot 2 configuration

    /// Slot 2 is enabled only while a second channel is chosen.
    var isSlot2Enabled: Bool { configuredName(2) != nil }

    /// The channel name a slot is set to join (persisted), if any.
    func configuredChannelName(_ slot: Int) -> String? { configuredName(slot) }

    /// True if `name` matches the other slot's configured channel ("Root" == "Lobby").
    func isConfiguredForOtherSlot(_ ch: Channel, slot: Int) -> Bool {
        let other = slot == 1 ? 2 : 1
        if other == 2 && !isSlot2Enabled { return false }
        return isConfigured(other, id: ch.id, name: ch.name)
    }

    private func configuredName(_ slot: Int) -> String? {
        let n = UserDefaults.standard.string(forKey: Self.channelKey(slot))
        return (n?.isEmpty ?? true) ? nil : n
    }

    /// Slot 2 is live and in its own channel (not shared with slot 1).
    private var isSlot2Usable: Bool {
        let s2 = slots[1]
        return clients[2] != nil && s2.state == .connected && s2.currentChannelId != nil && !slotsShareChannel
    }

    private var slotsShareChannel: Bool {
        guard clients[2] != nil, let a = slots[0].currentChannelId, let b = slots[1].currentChannelId else { return false }
        return a == b
    }

    private static func sameName(_ a: String?, _ b: String?) -> Bool {
        guard let a = a, let b = b else { return false }
        func norm(_ s: String) -> String { s.caseInsensitiveCompare("Root") == .orderedSame ? "lobby" : s.lowercased() }
        return norm(a) == norm(b)
    }

    // MARK: - Start / stop

    func start() {
        guard !started else { return }
        guard let bridge = bridge else { setSlot(1, .failed, "Host bridge unavailable"); return }
        guard let host = bridge.activeServerHost(), !host.isEmpty else {
            setSlot(1, .noServer, "No active TAK server")
            #if DEBUG
            // Self-test without a server (simulator): audio only, slot 1 faked
            // as connected, dry run so nothing could be sent anyway.
            if UserDefaults.standard.bool(forKey: "XVoiceSelfTest") {
                started = true
                requestMic { [weak self] ok in
                    guard let self = self, ok, (try? self.audio.start()) != nil else {
                        print("[SelfTest] cannot start audio (mic permission?)"); return
                    }
                    self.setSlot(1, .connected, "Connected (self-test, no server)")
                    self.runSelfTestIfRequested()
                }
            }
            #endif
            return
        }
        started = true
        startGeneration += 1
        let gen = startGeneration
        requestMic { [weak self] granted in
            guard let self = self, self.started, self.startGeneration == gen else { return }
            guard granted else { self.setSlot(1, .failed, "Microphone permission denied"); return }
            do { try self.audio.start() } catch {
                self.setSlot(1, .failed, "Audio error: \(error.localizedDescription)"); return
            }
            self.audioRoute = VoiceAudioEngine.routeDescription()
            self.observeRoute()
            self.startClient(slot: 1, host: host, bridge: bridge)
        }
        blePTT.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.autoConnectSpeakerMicButton() }
        startSpeakerTimer()
    }

    private func startClient(slot: Int, host: String, bridge: VoiceHostBridge) {
        guard clients[slot] == nil else { return }
        let c = MumbleClient(host: host, callsign: bridge.selfCallsign(), deviceUid: bridge.selfUid(), slot: slot) {
            [weak bridge] h, p in bridge?.makeServerTLSConnection(host: h, port: p)
        }
        c.delegate = self
        c.desiredChannelName = configuredName(slot)
        c.desiredChannelId = configuredId(slot)
        if slot == 2 { c.retryLadder = [3, 8] }
        clients[slot] = c
        setSlot(slot, .connecting, "Connecting…")
        c.start()
    }

    /// Bring slot 2 up if it is configured and slot 1 is connected and settled
    /// in a different channel. Called whenever slot 1's state changes.
    private func maybeStartSlot2() {
        guard started, isSlot2Enabled, clients[2] == nil else { return }
        let s1 = slots[0]
        guard s1.state == .connected, s1.settled, s1.currentChannelId != nil else {
            if slots[1].statusLine != "Waiting for PTT 1" { slots[1].statusLine = "Waiting for PTT 1" }
            return
        }
        if let cur = s1.currentChannelId, isConfigured(2, id: cur, name: s1.currentChannelName) {
            notice = "PTT 2's channel '\(configuredName(2) ?? "")' is PTT 1's channel — pick another for PTT 2"
            slots[1].statusLine = "Same channel as PTT 1"
            return
        }
        guard let bridge = bridge, let host = bridge.activeServerHost() else { return }
        startClient(slot: 2, host: host, bridge: bridge)
    }

    /// Take slot 2 down without forgetting its channel (it returns with slot 1).
    private func parkSlot2(_ why: String) {
        if burstSlot == 2 { endTX() }
        held[2] = []
        clients[2]?.stop(); clients[2] = nil
        var st = SlotStatus()
        st.statusLine = why
        slots[1] = st
    }

    func stop() {
        started = false
        if burstSlot != nil { endTX() }
        held = [1: [], 2: []]
        clients[2]?.stop(); clients[1]?.stop()   // slot 2 first, like Android
        clients.removeAll()
        audio.stop()
        blePTT.stop()
        speakerTimer?.invalidate(); speakerTimer = nil
        if let o = routeObserver { NotificationCenter.default.removeObserver(o); routeObserver = nil }
        speakerLastHeard.removeAll(); activeSpeakers = []
        slots = [SlotStatus(), SlotStatus()]
        setSlot(1, .off, "Voice off")
    }

    func reconnect() { stop(); start() }

    // MARK: - Channels

    /// Join a channel on a slot. Refused if the other slot is there (live or
    /// configured).
    func join(slot: Int, channelId: UInt32) {
        if slot == 2 { setSecondChannel(channelId); return }
        let name = slots[0].channels.first { $0.id == channelId }?.name ?? (channelId == 0 ? "Lobby" : "")
        if isSlot2Enabled && (slots[1].currentChannelId == channelId || isConfigured(2, id: channelId, name: name)) {
            notice = "'\(name)' is in use by PTT 2 — pick another or change PTT 2 first"
            return
        }
        notice = nil
        saveChannel(1, id: channelId, name: name)
        clients[1]?.join(channelId: channelId)
    }

    /// Choose slot 2's channel (from slot 1's directory, same server), or pass
    /// nil to turn slot 2 off.
    func setSecondChannel(_ channelId: UInt32?) {
        guard let id = channelId else {
            if clients[2] != nil { playStatus(.leave) }
            parkSlot2("Off")
            clearChannel(2)
            lastChannelBySlot[2] = nil
            notice = nil
            objectWillChange.send()
            print("[Voice VS2] off")
            return
        }
        let directory = slots[1].channels.isEmpty ? slots[0].channels : slots[1].channels
        let name = id == 0 ? "Lobby" : (directory.first { $0.id == id }?.name ?? "")
        guard !name.isEmpty else { return }
        if slots[0].currentChannelId == id || isConfigured(1, id: id, name: name) {
            notice = "'\(name)' is in use by PTT 1 — pick another or change PTT 1 first"
            return
        }
        notice = nil
        saveChannel(2, id: id, name: name)
        objectWillChange.send()
        if let c = clients[2], slots[1].state == .connected {
            c.join(channelId: id)
        } else {
            parkSlot2("Starting…")
            maybeStartSlot2()
        }
    }

    // MARK: - Status helpers

    private func setSlot(_ slot: Int, _ s: ConnState, _ line: String) {
        slots[slot - 1].state = s
        slots[slot - 1].statusLine = line
        print("[Voice VS\(slot)] \(line)")
    }

    private func refreshStatusLine(_ slot: Int) {
        var st = slots[slot - 1]
        guard st.state == .connected else { return }
        var line = "Connected · \(st.currentChannelName)"
        if st.suppressed { line += " · listen only" }
        if slot == 2 && slotsShareChannel { line = "Same channel as PTT 1 — paused" }
        st.statusLine = line
        slots[slot - 1] = st
    }

    private func checkSameChannel() {
        let same = slotsShareChannel
        if same != loggedSameChannel {
            loggedSameChannel = same
            print("[Voice] slot channels: VS1=\(slots[0].currentChannelId.map(String.init) ?? "nil") VS2=\(slots[1].currentChannelId.map(String.init) ?? "nil") configured VS1='\(configuredName(1) ?? "")' VS2='\(configuredName(2) ?? "")'")
            print(same ? "[Voice] slots share a channel — PTT 2 falls back to slot 1, slot 2 RX muted"
                       : "[Voice] slots in separate channels again")
            if same { notice = "The server put PTT 2 in PTT 1's channel — PTT 2 is paused. Pick another channel for PTT 2." }
        }
        refreshStatusLine(2)
    }

    private func requestMic(_ done: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: micPermission = "Granted"; done(true)
        case .denied: micPermission = "Denied"; done(false)
        default:
            session.requestRecordPermission { ok in
                DispatchQueue.main.async { self.micPermission = ok ? "Granted" : "Denied"; done(ok) }
            }
        }
    }

    private func observeRoute() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.audioRoute = VoiceAudioEngine.routeDescription()
            print("[Voice] audio route: \(self?.audioRoute ?? "")")
            self?.autoConnectSpeakerMicButton()
        }
    }

    // MARK: - PTT / TX state machine (ported from TAK-XVoice TxController)
    //
    //  PTT down ─► (refused → deny tone)
    //          ─► PRIMING: mic measured and DISCARDED until it is proven alive
    //               fast gates  : ≥5 frames, or rms ≥ 5,  500 ms timeout
    //               cold BT HFP : ≥30 non-silent frames, or rms ≥ 200, 1500 ms
    //               timeout with no mic audio at all → bonk, abandon
    //          ─► cold BT only: 700 ms hold (still discarding)
    //          ─► TPT: [80 ms silence][tone][100 ms silence] played; mic still
    //               discarded. Interrupt chirp instead if a peer is talking.
    //               Done = buffer actually played back (+350 ms on BT HFP);
    //               watchdog 2×tone+500 ms.
    //          ─► TRANSMITTING: encode + send through a 60 ms trailing delay.
    //  PTT up: before TRANSMITTING → no TX, no terminator (a playing tone is
    //          left to finish but starts nothing). During TRANSMITTING → drop
    //          the trailing 60 ms (click), send the terminator.
    //  Refractory: 200 ms between bursts (50 ms when Bluetooth is warm).
    //  "Cold" Bluetooth = HFP route with no RX in the last 8 s and no TX in the
    //  last 5 s (Android's SCO hold windows), i.e. a speaker-mic that has gone
    //  idle and needs to wake up before the tone can be heard.
    //  Frames are 10 ms on Android; here mic buffers are counted in 10 ms units.

    enum TxState: Equatable { case idle, acquiring, priming, coldHold, tpt, transmitting }
    @Published private(set) var txState: TxState = .idle
    private var burstSlot: Int?
    private var burstCold = false
    private var burstHFP = false
    private var primingTimer: DispatchWorkItem?
    private var acquireTimer: DispatchWorkItem?
    private var txWarnTimer: DispatchWorkItem?
    private var txCutoffTimer: DispatchWorkItem?

    // MARK: TX timeout (TAK-XVoice PttDispatcher): a held PTT is cut off after
    // `voice.pttTimeoutSec` (default 30 s, 0 = never). A warning chirp plays
    // 5 s before; at the limit a 1.2 s cutoff tone plays and TX stops. The
    // operator must release and press again — a stuck button can't keep a
    // channel open.

    static let txTimeoutKey = "voice.pttTimeoutSec"
    static let defaultTxTimeout = 30
    static var txTimeoutSeconds: Int {
        UserDefaults.standard.object(forKey: txTimeoutKey) == nil
            ? defaultTxTimeout : UserDefaults.standard.integer(forKey: txTimeoutKey)
    }

    private func armTxTimeout() {
        let limit = Self.txTimeoutSeconds
        guard limit > 0 else { return }
        if limit > 5 {
            let warn = DispatchWorkItem { [weak self] in
                guard let self = self, self.txState != .idle else { return }
                print("[Voice] TX timeout in 5 s")
                self.audio.playTone(VoiceTones.timeoutWarning())
            }
            txWarnTimer = warn
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(limit - 5), execute: warn)
        }
        let cut = DispatchWorkItem { [weak self] in
            guard let self = self, self.txState != .idle else { return }
            print("[Voice] TX timeout (\(limit) s) — cutting off; release and press again to talk")
            self.notice = "Transmit time limit (\(limit) s) reached — release PTT and press again."
            self.held = [1: [], 2: []]          // the current hold no longer counts
            self.stopBurst()
            self.audio.playTone(VoiceTones.timeoutCutoff())
        }
        txCutoffTimer = cut
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(limit), execute: cut)
    }
    private var holdTimer: DispatchWorkItem?
    private var tptWatchdog: DispatchWorkItem?
    private var primingSamples = 0
    private var primingLoudSamples = 0
    private var lastStopAt = Date.distantPast
    private var lastTxStopAt = Date.distantPast
    private var lastRxAt = Date.distantPast

    private static var routeIsHFP: Bool {
        let r = AVAudioSession.sharedInstance().currentRoute
        return (r.inputs + r.outputs).contains { $0.portType == .bluetoothHFP }
    }

    func pttDown(slot: Int, source: PTTSource) {
        guard slot == 1 || slot == 2 else { return }
        held[slot, default: []].insert(source)
        guard txState == .idle, pressedSlot == nil else { return }       // first press wins

        // Cold = the audio engine is in standby (Bluetooth link idle) and the
        // speaker-mic is Bluetooth HFP: it has to wake before the tone is heard.
        let hfp = audio.usesBluetoothHFP || Self.routeIsHFP
        let standby = audio.isStandby
        let now = Date()
        let warm = hfp && !standby
        let refractory = warm ? 0.05 : 0.2
        guard now.timeIntervalSince(lastStopAt) >= refractory else { return }

        // Can we transmit? Nothing without slot 1; PTT 2 uses slot 2 only when
        // it can carry audio, else slot 1; never on a listen-only channel.
        guard slots[0].state == .connected else {
            print("[Voice] PTT refused: voice not connected")
            audio.playTone(VoiceTones.deny())
            return
        }
        let target = (slot == 2 && isSlot2Usable) ? 2 : 1
        if slot == 2 && target == 1 { print("[Voice] PTT 2 → slot 1 (slot 2 not usable)") }
        guard !slots[target - 1].suppressed else {
            notice = "PTT \(target) is listen-only in this channel"
            audio.playTone(VoiceTones.deny())
            return
        }

        pressedSlot = slot
        burstSlot = target
        audio.setBusy(true)
        armTxTimeout()
        burstHFP = hfp
        burstCold = hfp && standby
        if standby {
            // ACQUIRING: wake the audio path (mic + Bluetooth link) first, up
            // to 3 s (Android SCO_WARMUP), then PRIMING.
            txState = .acquiring
            print("[Voice] \(Self.ts()) ACQUIRING audio (waking from standby)")
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self, self.txState == .acquiring else { return }
                print("[Voice] audio wake-up took > 3 s — priming anyway")
                self.startPriming()
            }
            acquireTimer = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            audio.activate("PTT") { [weak self] in
                guard let self = self, self.txState == .acquiring else { return }
                self.acquireTimer?.cancel(); self.acquireTimer = nil
                self.burstHFP = self.audio.usesBluetoothHFP
                self.startPriming()
            }
        } else {
            startPriming()
        }
    }

    func pttUp(slot: Int, source: PTTSource) {
        held[slot, default: []].remove(source)
        guard pressedSlot == slot, held[slot, default: []].isEmpty else { return }
        stopBurst()
    }

    private func startPriming() {
        txState = .priming
        primingSamples = 0
        primingLoudSamples = 0
        let cold = burstCold
        let frameGate = (cold ? 30 : 5) * 480          // in samples (10 ms frames)
        let rmsGate: Float = cold ? 200 : 5
        print("[Voice] \(Self.ts()) PRIMING (\(burstHFP ? (cold ? "Bluetooth, cold" : "Bluetooth, warm") : "built-in/wired"))")
        audio.setMicLevelHandler { [weak self] n, rms in
            DispatchQueue.main.async {
                guard let self = self, self.txState == .priming else { return }
                self.primingSamples += n
                if rms > 0 { self.primingLoudSamples += n }
                let framesOK = cold ? self.primingLoudSamples >= frameGate : self.primingSamples >= frameGate
                if rms >= rmsGate || framesOK { self.micAlive() }
            }
        }
        audio.setMicMode(.listen)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.txState == .priming else { return }
            if self.primingSamples == 0 {
                print("[Voice] PRIMING timed out with no mic audio — bonk")
                self.audio.playTone(VoiceTones.bonk())
                self.stopBurst()
            } else {
                self.micAlive()
            }
        }
        primingTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (cold ? 1.5 : 0.5), execute: timeout)
    }

    private func micAlive() {
        primingTimer?.cancel(); primingTimer = nil
        audio.setMicLevelHandler(nil)
        if burstCold {
            txState = .coldHold                       // mic still discarding
            let hold = DispatchWorkItem { [weak self] in
                guard let self = self, self.txState == .coldHold else { return }
                self.startTpt()
            }
            holdTimer = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: hold)
        } else {
            startTpt()
        }
    }

    static func ts() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
    }

    private func startTpt() {
        txState = .tpt                                 // mic still discarding
        print("[Voice] \(Self.ts()) TPT start")
        let peerTalking = !activeSpeakers.isEmpty
        guard let tone = peerTalking ? VoiceTones.interruptChirp() : VoiceTones.permit() else {
            startTransmitting(notBeforeHost: mach_absolute_time())   // tone "None": straight to TX
            return
        }
        let tail = burstHFP ? 0.35 : 0                 // Bluetooth tail guard
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.txState == .tpt else { return }
            print("[Voice] TPT watchdog fired")
            self.startTransmitting(notBeforeHost: mach_absolute_time())
        }
        tptWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(VoiceTones.durationMs(tone) * 2 + 500) / 1000 + 0.18 + tail,
                                      execute: watchdog)
        audio.playTone(tone, padded: true) { [weak self] playedHost in
            print("[Voice] \(Self.ts()) TPT played back (+\(Int(tail * 1000)) ms guard)")
            // Mic audio captured before (playback end + tail guard) is never
            // sent — enforced by capture timestamp in the audio engine.
            let gate = playedHost + AVAudioTime.hostTime(forSeconds: tail)
            DispatchQueue.main.asyncAfter(deadline: .now() + tail) {
                guard let self = self, self.txState == .tpt else { return }
                self.startTransmitting(notBeforeHost: gate)
            }
        }
    }

    private func startTransmitting(notBeforeHost: UInt64) {
        tptWatchdog?.cancel(); tptWatchdog = nil
        guard let target = burstSlot else { return }
        txState = .transmitting
        transmittingSlot = target
        txSlotForAudio = target
        if !dryRun { clients[target]?.beginTransmission() }
        audio.setMicMode(.transmit, notBeforeHost: notBeforeHost)
        audio.setDucked(slot: target == 1 ? 2 : 1, true)
        print("[Voice] \(Self.ts()) TRANSMITTING on slot \(target)")
    }

    /// PTT-up or anything that ends the burst. Only a burst that reached
    /// TRANSMITTING sends a terminator.
    private func stopBurst() {
        primingTimer?.cancel(); primingTimer = nil
        acquireTimer?.cancel(); acquireTimer = nil
        txWarnTimer?.cancel(); txWarnTimer = nil
        txCutoffTimer?.cancel(); txCutoffTimer = nil
        holdTimer?.cancel(); holdTimer = nil
        tptWatchdog?.cancel(); tptWatchdog = nil
        audio.setMicLevelHandler(nil)
        let wasTransmitting = txState == .transmitting
        if txState != .idle && !wasTransmitting {
            print("[Voice] \(Self.ts()) burst ended during \(txState) — nothing transmitted")
        }
        let slot = burstSlot
        txSlotForAudio = nil                           // in-flight frames are dropped
        audio.setMicMode(.off)
        if wasTransmitting, let s = slot {
            if !dryRun { clients[s]?.endTransmission() }
            lastTxStopAt = Date()
        }
        audio.setDucked(slot: 1, false)
        audio.setDucked(slot: 2, false)
        txState = .idle
        transmittingSlot = nil
        pressedSlot = nil
        burstSlot = nil
        lastStopAt = Date()
        audio.setBusy(false)
    }

    /// Kept for existing callers: end whatever burst is in progress.
    private func endTX() { stopBurst() }

    // MARK: - Debug self-test (launch with -XVoiceSelfTest YES)
    //
    // Drives PTT through the full TX state machine on a real device WITHOUT
    // sending anything to the server (dry run), and probes the first frames of
    // each burst for the permit tone. Scenarios: full burst, release during
    // PRIMING, release during the tone, second full burst.

    /// When true, nothing is sent to Mumble (no voice, no terminator).
    private(set) var dryRun = false
    private var dryRunPackets = 0
    private var selfTestStarted = false

    #if DEBUG
    private func runSelfTestIfRequested() {
        guard !selfTestStarted, UserDefaults.standard.bool(forKey: "XVoiceSelfTest") else { return }
        selfTestStarted = true
        dryRun = true
        let tone = TalkPermitTone.current
        audio.leakProbeHz = [TalkPermitTone.astro25: 910, .dmr: 1569, .nextel: 1800, .nextelAlt: 911, .vertex: 1050][tone]
        print("[SelfTest] start — DRY RUN (nothing sent). tone=\(tone.rawValue) route=\(VoiceAudioEngine.routeDescription())")
        let steps: [(Double, String, () -> Void)] = [
            (3.0, "A: press (full burst)", { self.pttDown(slot: 1, source: .onScreen) }),
            (5.5, "A: release", { self.pttUp(slot: 1, source: .onScreen) }),
            (7.0, "B: press (release during PRIMING)", { self.pttDown(slot: 1, source: .onScreen) }),
            (7.15, "B: release", { self.pttUp(slot: 1, source: .onScreen) }),
            (9.0, "C: press (release during TPT)", { self.pttDown(slot: 1, source: .onScreen) }),
            (9.45, "C: release", { self.pttUp(slot: 1, source: .onScreen) }),
            (11.0, "D: press (second full burst)", { self.pttDown(slot: 1, source: .onScreen) }),
            (13.5, "D: release", { self.pttUp(slot: 1, source: .onScreen) }),
            // E: after the 5 s / 8 s holds the engine is in standby, so this
            // press exercises ACQUIRING (wake) → PRIMING → TPT → TX.
            (26.0, "E: press after standby (wake path)", { print("[SelfTest] engine standby before E: \(self.audio.isStandby)"); self.pttDown(slot: 1, source: .onScreen) }),
            (29.5, "E: release", { self.pttUp(slot: 1, source: .onScreen) }),
            (31.0, "done", { print("[SelfTest] done — packets that would have been sent: \(self.dryRunPackets), state=\(self.txState)") }),
        ]
        let t0 = Date()
        for (at, label, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                print(String(format: "[SelfTest] t=%.2fs %@ (state before: %@)", Date().timeIntervalSince(t0), label, "\(self.txState)"))
                action()
            }
        }
    }
    #endif

    // MARK: - Talking indicator (600 ms after the last frame, like XV)

    private static func speakerKey(slot: Int, session: UInt32) -> UInt32 {
        slot == 2 ? (session | 0x8000_0000) : (session & 0x7FFF_FFFF)
    }

    private func startSpeakerTimer() {
        speakerTimer?.invalidate()
        speakerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refreshSpeakers()
        }
    }

    private func refreshSpeakers() {
        let now = Date()
        speakerLastHeard = speakerLastHeard.filter { now.timeIntervalSince($0.value.at) < 0.6 }
        let names = speakerLastHeard.values
            .sorted { ($0.slot, $0.session) < ($1.slot, $1.session) }
            .map { "\($0.slot): " + (clients[$0.slot]?.userName($0.session) ?? "Session \($0.session)") }
        if names != activeSpeakers { activeSpeakers = names }
    }
}

extension VoiceController: MumbleClientDelegate {
    func mumble(_ client: MumbleClient, stateChanged s: MumbleClient.State) {
        let slot = client.slot
        guard clients[slot] === client else { return }
        switch s {
        case .idle: break
        case .connecting: setSlot(slot, .connecting, "Connecting…")
        case .connected:
            if slot == 1 { slot1WasConnected = true }
            setSlot(slot, .connected, "Connected")
            #if DEBUG
            if slot == 1 { runSelfTestIfRequested() }
            #endif
            if slot == 1 { maybeStartSlot2() }
        case .reconnecting(let secs, _):
            let wasTX = txState == .transmitting && burstSlot == slot
            if burstSlot == slot { endTX() }
            if wasTX { audio.playTone(VoiceTones.timeoutCutoff()) }   // dropped mid-burst
            if slot == 1 && slot1WasConnected { playStatus(.voiceLost) }
            if slot == 1 { slot1WasConnected = false; lastChannelBySlot = [:] }
            setSlot(slot, .reconnecting, "Reconnecting in \(secs)s")
            slots[slot - 1].settled = false
            if slot == 1 { parkSlot2(isSlot2Enabled ? "Waiting for PTT 1" : "Off") }
        case .failed(let why):
            if burstSlot == slot { endTX() }
            if slot == 1 && slot1WasConnected { playStatus(.voiceLost) }
            if slot == 1 { slot1WasConnected = false; lastChannelBySlot = [:] }
            setSlot(slot, why.contains("certificate") ? .noCertificate : .failed, why)
            if slot == 1 { parkSlot2(isSlot2Enabled ? "Waiting for PTT 1" : "Off") }
        }
    }

    func mumble(_ client: MumbleClient, channelsChanged ch: [UInt32: String], current: UInt32?,
                suppressed: Bool, settled: Bool, onTarget: Bool) {
        let slot = client.slot
        guard clients[slot] === client else { return }
        var st = slots[slot - 1]
        st.channels = ch.map { Channel(id: $0.key, name: $0.key == 0 ? "Lobby" : $0.value) }.sorted { $0.id < $1.id }
        st.currentChannelId = current
        st.suppressed = suppressed
        st.settled = settled
        slots[slot - 1] = st
        // Remember where the server actually put slot 1 (admin moves included).
        // Only when it's where we asked to be (or an adopted admin move) — a
        // refused or missing target must not overwrite the operator's choice.
        if slot == 1, settled, onTarget, current != nil {
            saveChannel(1, id: current!, name: st.currentChannelName)
        }
        if settled, let cur = current, lastChannelBySlot[slot] != cur {
            lastChannelBySlot[slot] = cur
            playStatus(.join)
        }
        refreshStatusLine(slot)
        if slot == 1 { maybeStartSlot2() }
        checkSameChannel()
        // If the slot that owns the mic just became listen-only, stop.
        if suppressed, burstSlot == slot { endTX() }
    }

    func mumble(_ client: MumbleClient, voice opus: Data, from session: UInt32, terminator: Bool) {
        let slot = client.slot
        let key = Self.speakerKey(slot: slot, session: session)
        DispatchQueue.main.async {
            guard self.clients[slot] === client else { return }   // stale (parked/stopped) client
            // Slots sharing a channel would play every speaker twice: keep slot 1's copy.
            if slot == 2 && self.slotsShareChannel { return }
            if !opus.isEmpty { self.audio.playOpus(opus, speaker: key, slot: slot) }
            if terminator { self.audio.endOfStream(speaker: key) }
            if terminator { self.speakerLastHeard[key] = nil }
            else { self.speakerLastHeard[key] = (slot, session, Date()) }
            self.lastRxAt = Date()
            self.refreshSpeakers()
        }
    }
}
