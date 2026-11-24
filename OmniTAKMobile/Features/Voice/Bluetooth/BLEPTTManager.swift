//
//  BLEPTTManager.swift
//  OmniTAKMobile
//
//  Bluetooth LE push-to-talk buttons for the voice plugin, ported from
//  TAK-XVoice's aina/ readers (Android). Supported on iOS:
//
//  - AINA APTT V2 (name "APTT*"): service 127FACE1-…, button char 127FBEEF-…
//    notify, byte[0] bitmask 0x01 PTT, 0x02 emergency, 0x04 secondary PTT,
//    0x20 MFB; 0x80 heartbeat (mask 0x3F). Init: OR the two production CONFIG
//    (127FDEAF-…) bits 0x20 (A2DP controls disable) and 0x10 (phone controls
//    disable) via read-modify-write. NO other bits. The V1 exposes the same
//    BLE button service and is handled identically.
//  - Pryme BT-PTT-Z (name contains pryme / bt-ptt / ptt-z — the name is
//    required: FFE0 alone is a generic UART service many gadgets advertise):
//    subscribe every notify characteristic in FFE0 (or the 00420000-… fallback);
//    byte[0] != 0 → down, 0 → up.
//  - Inrico BT02 (name prefix "B02PTT"): char 894C8042-… anywhere, byte[0] code
//    0x00 release, 0x01 PTT held, 0x08 emergency pulse.
//
//  NOT supported on iOS: the AINA V1's SPP/RFCOMM channel (needs Apple MFi)
//  and Samsung Active Key (Android-only).
//
//  Connection policy (a wrong device here could key the microphone): a button
//  connects automatically only if the operator picked it before (saved), or it
//  is the BLE side of the speaker-mic iOS is using for audio (same name).
//  Anything else needs one tap in the scan list. "Forget" sticks until then. A speaker-mic's AUDIO still works through
//  the regular Bluetooth HFP route (see VoiceAudioEngine); this file only
//  handles the buttons.
//

import Foundation
import CoreBluetooth

/// PTT events from a hardware button. `slot` 1 = primary PTT (VS1), 2 = secondary (VS2).
/// `function`: a speaker-mic's extra button (Inrico BT02: 0x03 top button,
/// 0x02 / 0x04 side buttons), one pulse per press.
/// `linkLost`: the button disconnected or Bluetooth turned off — any press in
/// progress is void (PTT releases are emitted separately).
enum PTTButtonEvent: Equatable { case pttDown(slot: Int), pttUp(slot: Int), emergency(down: Bool), function(code: UInt8), linkLost }

final class BLEPTTManager: NSObject, ObservableObject {
    /// rawValue is persisted (saved button kind) — don't change it.
    enum Kind: String {
        case ainaV2 = "AINA APTT V2", pryme = "Pryme BT-PTT-Z", bt02 = "Inrico BT02"
        /// AINA V1 (APTT1) exposes the same BLE button service as V2 and was
        /// verified on device, so one code path serves both.
        var displayName: String { self == .ainaV2 ? "AINA APTT (V1/V2)" : rawValue }
    }

    struct Discovered: Identifiable, Equatable {
        let id: UUID
        let name: String
        let kind: Kind
        var rssi: Int
    }

    private enum UUIDs {
        static let ainaService = CBUUID(string: "127FACE1-CB21-11E5-93D0-0002A5D5C51B")
        static let ainaButton  = CBUUID(string: "127FBEEF-CB21-11E5-93D0-0002A5D5C51B")
        static let ainaConfig  = CBUUID(string: "127FDEAF-CB21-11E5-93D0-0002A5D5C51B")
        static let prymeService = CBUUID(string: "FFE0")
        static let prymeFallback = CBUUID(string: "00420000-8F59-4420-870D-84F3B617E493")
        static let bt02Button  = CBUUID(string: "894C8042-E841-461C-A5C9-5A73D25DB08E")
    }
    private static let savedKey = "voice.blePtt.peripheral"
    private static let ainaA2dpControlsDisable: UInt8 = 0x20
    private static let ainaPhoneControlsDisable: UInt8 = 0x10

    @Published private(set) var discovered: [Discovered] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var status = "Off"
    @Published private(set) var isScanning = false

    var onEvent: ((PTTButtonEvent) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var kind: Kind?
    private var lastAinaMask: UInt8 = 0
    private var wantRunning = false
    /// When set, the first discovered button with this exact name is
    /// connected automatically (the BLE side of a paired speaker-mic).
    private var autoConnectName: String?
    /// Auto scans are spaced out: route changes and foregrounding fire often.
    private var lastAutoScanAt = Date.distantPast
    private static let autoScanMinInterval: TimeInterval = 30
    private static let forgottenKey = "voice.blePtt.forgotten"
    /// The button the operator chose to forget: never auto-connected again
    /// until they pick it from the scan list.
    private var forgottenPeripheralId: UUID? {
        get { UserDefaults.standard.string(forKey: Self.forgottenKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.forgottenKey) }
    }
    private var scanToken = 0
    private var seenThisScan = Set<UUID>()

    var savedPeripheralId: UUID? {
        get { UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.savedKey) }
    }

    // MARK: - Control

    /// Start Bluetooth and reconnect to the saved button, if any. Creating the
    /// central is what triggers the iOS Bluetooth permission prompt.
    func start() {
        wantRunning = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { reconnectSaved() }
    }

    func stop() {
        wantRunning = false
        autoConnectName = nil
        stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil; kind = nil; connectedName = nil
        status = "Off"
    }

    func startScan() {
        guard let c = central, c.state == .poweredOn else { status = "Bluetooth is off"; return }
        discovered.removeAll()
        seenThisScan.removeAll()
        isScanning = true
        status = "Scanning…"
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanToken += 1
        let token = scanToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.scanToken == token else { return }   // a newer scan owns the timer
            self.stopScan()
        }
    }

    /// Find and connect the PTT button that belongs to a speaker-mic already
    /// used for audio (same advertised name, e.g. "B02PTT-B480"). No-op if a
    /// button is already connected or the operator saved a different one.
    func autoConnect(matching name: String) {
        // Only for supported speaker-mics (Inrico, AINA). A button-only device
        // (Pryme) paired with an ordinary headset is left alone.
        guard Self.classify(name: name, services: []) != nil else { return }
        if connectedName == name || peripheral?.name == name { return }   // already following it
        // The button follows the speaker-mic in use: drop a different one.
        if let old = peripheral {
            print("[BLEPTT] switching from '\(old.name ?? "?")' to the button of '\(name)'")
            wantRunning = true
            central?.cancelPeripheralConnection(old)
            peripheral = nil; kind = nil; connectedName = nil; lastAinaMask = 0
        }
        guard wantRunning else { return }
        autoConnectName = name
        // Bluetooth may still be powering up right after launch: the scan then
        // starts from centralManagerDidUpdateState(.poweredOn).
        guard !isScanning, central?.state == .poweredOn,
              Date().timeIntervalSince(lastAutoScanAt) >= Self.autoScanMinInterval else { return }
        print("[BLEPTT] looking for the PTT button of '\(name)'")
        lastAutoScanAt = Date()
        startScan()
    }

    /// Operator tapped a device in the scan list.
    func connectChosen(_ d: Discovered) {
        forgottenPeripheralId = nil
        connect(d)
    }

    func stopScan() {
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
        if connectedName == nil { status = discovered.isEmpty ? "No PTT buttons found" : "Pick a button" }
    }

    private func connect(_ d: Discovered) {
        guard let c = central, let p = c.retrievePeripherals(withIdentifiers: [d.id]).first else { return }
        stopScan()
        if let old = peripheral, old.identifier != p.identifier { c.cancelPeripheralConnection(old) }
        savedPeripheralId = d.id
        UserDefaults.standard.set(d.kind.rawValue, forKey: Self.savedKey + ".kind")
        attach(p, kind: d.kind)
    }

    func forget() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        forgottenPeripheralId = peripheral?.identifier ?? savedPeripheralId
        peripheral = nil; kind = nil; connectedName = nil
        savedPeripheralId = nil
        autoConnectName = nil
        status = "No button paired"
    }

    private func reconnectSaved() {
        guard wantRunning, let c = central, c.state == .poweredOn,
              let id = savedPeripheralId,
              let raw = UserDefaults.standard.string(forKey: Self.savedKey + ".kind"),
              let k = Kind(rawValue: raw),
              let p = c.retrievePeripherals(withIdentifiers: [id]).first else {
            if central?.state == .poweredOn, savedPeripheralId == nil { status = "No button paired" }
            return
        }
        attach(p, kind: k)
    }

    private func attach(_ p: CBPeripheral, kind k: Kind) {
        peripheral = p; kind = k; lastAinaMask = 0
        p.delegate = self
        status = "Connecting to \(p.name ?? k.rawValue)…"
        central?.connect(p, options: nil)
    }

    static func classify(name: String?, services: [CBUUID]) -> Kind? {
        let n = (name ?? "").lowercased()
        // AINA: by name ("APTT…", V2 and — if it exposes the same BLE button
        // service — V1), or by advertising the AINA GATT service.
        if n.hasPrefix("aptt") || services.contains(UUIDs.ainaService) { return .ainaV2 }
        if n.hasPrefix("b02ptt") { return .bt02 }
        // Name required: FFE0 alone is the generic HM-10 UART service.
        if n.contains("pryme") || n.contains("bt-ptt") || n.contains("ptt-z") { return .pryme }
        return nil
    }

    // MARK: - Decoding

    private func handleValue(_ data: Data, from char: CBCharacteristic) {
        guard let b = data.first, let k = kind else { return }
        switch k {
        case .ainaV2: guard char.uuid == UUIDs.ainaButton else { return }
        case .bt02: guard char.uuid == UUIDs.bt02Button else { return }
        case .pryme: break
        }
        let (events, mask) = Self.decodeButtons(kind: k, byte: b, previousAinaMask: lastAinaMask)
        lastAinaMask = mask
        events.forEach(emit)
    }

    /// Pure decoder for one button notification (byte[0]), per device type.
    /// - AINA V2: bitmask, edges vs the previous mask (0x01 PTT → slot 1,
    ///   0x04 PTTS → slot 2, 0x02 PTTE emergency); 0x80 heartbeat and other
    ///   bits ignored (mask 0x3F, MFB/B1/B2 unmapped).
    /// - Pryme: non-zero = PTT down, 0 = up.
    /// - Inrico BT02: enumerated 0x00 release, 0x01 PTT, 0x08 emergency pulse
    ///   (no release follows, so it is reported as down+up), others ignored.
    static func decodeButtons(kind: Kind, byte b: UInt8, previousAinaMask: UInt8) -> ([PTTButtonEvent], UInt8) {
        switch kind {
        case .ainaV2:
            let mask = b & 0x3F
            let changed = mask ^ previousAinaMask
            var ev: [PTTButtonEvent] = []
            if changed & 0x01 != 0 { ev.append(mask & 0x01 != 0 ? .pttDown(slot: 1) : .pttUp(slot: 1)) }
            if changed & 0x04 != 0 { ev.append(mask & 0x04 != 0 ? .pttDown(slot: 2) : .pttUp(slot: 2)) }
            if changed & 0x02 != 0 { ev.append(.emergency(down: mask & 0x02 != 0)) }
            return (ev, mask)
        case .pryme:
            return ([b != 0 ? .pttDown(slot: 1) : .pttUp(slot: 1)], previousAinaMask)
        case .bt02:
            switch b {
            case 0x00: return ([.pttUp(slot: 1)], previousAinaMask)
            case 0x01: return ([.pttDown(slot: 1)], previousAinaMask)
            case 0x08: return ([.emergency(down: true), .emergency(down: false)], previousAinaMask)
            // Probed on device: top button 0x03, side buttons 0x02 / 0x04 —
            // single pulses, no release.
            case 0x02, 0x03, 0x04: return ([.function(code: b)], previousAinaMask)
            default: return ([], previousAinaMask)
            }
        }
    }

    private func emit(_ e: PTTButtonEvent) {
        print("[BLEPTT] \(e)")
        onEvent?(e)
    }
}

extension BLEPTTManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state != .poweredOn {
            // Power-off/reset doesn't call didDisconnect: never leave TX keyed.
            if connectedName != nil || lastAinaMask != 0 { emit(.pttUp(slot: 1)); emit(.pttUp(slot: 2)); emit(.linkLost) }
            connectedName = nil
            lastAinaMask = 0
            isScanning = false
        }
        switch c.state {
        case .poweredOn:
            status = savedPeripheralId == nil ? "No button paired" : "Reconnecting…"
            guard wantRunning else { break }
            reconnectSaved()
            if autoConnectName != nil, connectedName == nil, !isScanning {
                lastAutoScanAt = Date()
                startScan()
            }
        case .unauthorized: status = "Bluetooth permission denied"
        case .poweredOff: status = "Bluetooth is off"
        case .unsupported: status = "Bluetooth LE unsupported"
        default: status = "Bluetooth unavailable"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // Log every advertiser once per scan (diagnostics: e.g. does an AINA
        // V1 advertise over BLE at all, and under what name/services?).
        #if DEBUG
        if !seenThisScan.contains(p.identifier) {
            seenThisScan.insert(p.identifier)
            let mfr = (ad[CBAdvertisementDataManufacturerDataKey] as? Data).map { $0.prefix(8).map { String(format: "%02x", $0) }.joined() } ?? "-"
            print("[BLEPTT] scan: '\(name ?? "(no name)")' rssi \(rssi) services [\(services.map { $0.uuidString }.joined(separator: ","))] mfr \(mfr)")
        }
        #endif
        guard let k = Self.classify(name: name, services: services) else { return }
        let d = Discovered(id: p.identifier, name: name ?? k.rawValue, kind: k, rssi: rssi.intValue)
        if let i = discovered.firstIndex(where: { $0.id == d.id }) { discovered[i].rssi = d.rssi }
        else { discovered.append(d) }
        if let want = autoConnectName, d.name == want, connectedName == nil, d.id != forgottenPeripheralId {
            print("[BLEPTT] auto-connecting \(d.name) (\(d.kind.displayName))")
            autoConnectName = nil
            connect(d)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connectedName = p.name ?? kind?.rawValue
        print("[BLEPTT] connected \(connectedName ?? "?")")
        status = "Connected: \(connectedName ?? "button")"
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "Couldn't connect: \(error?.localizedDescription ?? "unknown") — retrying"
        guard wantRunning, peripheral?.identifier == p.identifier else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.wantRunning, self.peripheral?.identifier == p.identifier,
                  self.central?.state == .poweredOn else { return }
            self.central?.connect(p, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        // A late disconnect of a button we already replaced (or forgot) must
        // not release PTT or clear the name of the current one.
        if let current = peripheral, current.identifier != p.identifier { return }
        connectedName = nil
        emit(.pttUp(slot: 1)); emit(.pttUp(slot: 2))   // never leave TX latched on
        emit(.linkLost)
        lastAinaMask = 0
        guard wantRunning, peripheral?.identifier == p.identifier else { return }
        status = "Disconnected — reconnecting…"
        c.connect(p, options: nil)    // iOS keeps this pending until the button is back in range
    }
}

extension BLEPTTManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let found = p.services ?? []
        print("[BLEPTT] \(p.name ?? "?") services: \(found.map { $0.uuid.uuidString }.joined(separator: ", "))")
        if kind == .ainaV2, !found.contains(where: { $0.uuid == UUIDs.ainaService }) {
            // e.g. an AINA V1 that only does Classic SPP — iOS can't read that.
            print("[BLEPTT] AINA button service 127FACE1 NOT present on \(p.name ?? "?") — its PTT can't be read over BLE")
            status = "This AINA doesn't expose the BLE button service (SPP-only V1?)"
        }
        for s in found { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let k = kind else { return }
        for ch in s.characteristics ?? [] {
            switch k {
            case .ainaV2:
                if ch.uuid == UUIDs.ainaButton { p.setNotifyValue(true, for: ch) }
                if ch.uuid == UUIDs.ainaConfig { p.readValue(for: ch) }   // read-modify-write below
            case .pryme:
                let inService = s.uuid == UUIDs.prymeService || s.uuid == UUIDs.prymeFallback
                if inService, ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
            case .bt02:
                if ch.uuid == UUIDs.bt02Button { p.setNotifyValue(true, for: ch) }
                #if DEBUG
                if ch.uuid != UUIDs.bt02Button,
                   ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                // PROBE (Inrico): subscribe to every notifying/indicating
                // characteristic and log raw bytes, to find out what a long
                // hold / double press of the emergency key, or the other
                // buttons, actually send (e.g. something usable to cancel a
                // 911 alert). Decoding still only uses the button char.
                    print("[BLEPTT] probe: subscribing \(s.uuid.uuidString) / \(ch.uuid.uuidString) (props 0x\(String(ch.properties.rawValue, radix: 16)))")
                    p.setNotifyValue(true, for: ch)
                }
                #endif
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == UUIDs.ainaConfig else { return }
        print("[BLEPTT] AINA CONFIG write \(error.map { "FAILED: \($0.localizedDescription)" } ?? "OK")")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, let v = ch.value else { return }
        #if DEBUG
        if kind == .bt02 {
            let hex = v.map { String(format: "%02x", $0) }.joined(separator: " ")
            let t = { () -> String in let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }()
            print("[BLEPTT] probe \(t) \(ch.uuid.uuidString.prefix(8)): [\(hex)]")
        }
        #endif
        if kind == .ainaV2, ch.uuid == UUIDs.ainaConfig {
            // Only ever OR in the two production bits (AINA spec v18 §4.3):
            // A2DP-controls-disable and phone-controls-disable. The dev-only
            // bits can brick the device. Phone controls off stops the main PTT
            // doubling as an HFP call button (mic mute) while the PushToTalk
            // session holds the HFP link open.
            guard let cur = v.first else { return }
            let want = cur | Self.ainaA2dpControlsDisable | Self.ainaPhoneControlsDisable
            print(String(format: "[BLEPTT] AINA CONFIG read 0x%02x%@", cur, want == cur ? " (already set)" : String(format: " — writing 0x%02x", want)))
            guard want != cur else { return }
            var out = v
            out[out.startIndex] = want
            p.writeValue(out, for: ch, type: .withResponse)
            return
        }
        handleValue(v, from: ch)
    }
}
