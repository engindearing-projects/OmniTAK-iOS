//
//  BLEPTTManager.swift
//  OmniTAKMobile
//
//  Bluetooth LE push-to-talk buttons for the voice plugin, ported from
//  TAK-XVoice's aina/ readers (Android). Supported on iOS:
//
//  - AINA APTT V2 (name "APTT*"): service 127FACE1-…, button char 127FBEEF-…
//    notify, byte[0] bitmask 0x01 PTT, 0x02 emergency, 0x04 secondary PTT,
//    0x20 MFB; 0x80 heartbeat (mask 0x3F). Init: set CONFIG (127FDEAF-…)
//    bit 0x20 (A2DP controls disable) via read-modify-write. NO other bits.
//  - Pryme BT-PTT-Z (name contains pryme / bt-ptt / ptt-z, or service FFE0):
//    subscribe every notify characteristic in FFE0 (or the 00420000-… fallback);
//    byte[0] != 0 → down, 0 → up.
//  - Inrico BT02 (name prefix "B02PTT"): char 894C8042-… anywhere, byte[0] code
//    0x00 release, 0x01 PTT held, 0x08 emergency pulse.
//
//  NOT supported on iOS: AINA APTT V1 (SPP/RFCOMM — needs Apple MFi) and
//  Samsung Active Key (Android-only). A speaker-mic's AUDIO still works through
//  the regular Bluetooth HFP route (see VoiceAudioEngine); this file only
//  handles the buttons.
//

import Foundation
import CoreBluetooth

/// PTT events from a hardware button. `slot` 1 = primary PTT (VS1), 2 = secondary (VS2).
enum PTTButtonEvent: Equatable { case pttDown(slot: Int), pttUp(slot: Int), emergency(down: Bool) }

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
        print("[BLEPTT] looking for the PTT button of '\(name)'")
        autoConnectName = name
        // Bluetooth may still be powering up right after launch: the scan then
        // starts from centralManagerDidUpdateState(.poweredOn).
        if !isScanning, central?.state == .poweredOn { startScan() }
    }

    func stopScan() {
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
        if connectedName == nil { status = discovered.isEmpty ? "No PTT buttons found" : "Pick a button" }
    }

    func connect(_ d: Discovered) {
        guard let c = central, let p = c.retrievePeripherals(withIdentifiers: [d.id]).first else { return }
        stopScan()
        if let old = peripheral, old.identifier != p.identifier { c.cancelPeripheralConnection(old) }
        savedPeripheralId = d.id
        UserDefaults.standard.set(d.kind.rawValue, forKey: Self.savedKey + ".kind")
        attach(p, kind: d.kind)
    }

    func forget() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil; kind = nil; connectedName = nil
        savedPeripheralId = nil
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
        if n.contains("pryme") || n.contains("bt-ptt") || n.contains("ptt-z") || services.contains(UUIDs.prymeService) { return .pryme }
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
            if connectedName != nil || lastAinaMask != 0 { emit(.pttUp(slot: 1)); emit(.pttUp(slot: 2)) }
            connectedName = nil
            lastAinaMask = 0
            isScanning = false
        }
        switch c.state {
        case .poweredOn:
            status = savedPeripheralId == nil ? "No button paired" : "Reconnecting…"
            reconnectSaved()
            if autoConnectName != nil, connectedName == nil, !isScanning { startScan() }
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
        if !seenThisScan.contains(p.identifier) {
            seenThisScan.insert(p.identifier)
            let mfr = (ad[CBAdvertisementDataManufacturerDataKey] as? Data).map { $0.prefix(8).map { String(format: "%02x", $0) }.joined() } ?? "-"
            print("[BLEPTT] scan: '\(name ?? "(no name)")' rssi \(rssi) services [\(services.map { $0.uuidString }.joined(separator: ","))] mfr \(mfr)")
        }
        guard let k = Self.classify(name: name, services: services) else { return }
        let d = Discovered(id: p.identifier, name: name ?? k.rawValue, kind: k, rssi: rssi.intValue)
        if let i = discovered.firstIndex(where: { $0.id == d.id }) { discovered[i].rssi = d.rssi }
        else { discovered.append(d) }
        if let want = autoConnectName, d.name == want, connectedName == nil {
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
        connectedName = nil
        emit(.pttUp(slot: 1)); emit(.pttUp(slot: 2))   // never leave TX latched on
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
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, let v = ch.value else { return }
        if kind == .ainaV2, ch.uuid == UUIDs.ainaConfig {
            // Only ever OR in the A2DP-controls-disable bit; other bits can brick the device.
            guard let cur = v.first, cur & Self.ainaA2dpControlsDisable == 0 else { return }
            var out = v
            out[out.startIndex] = cur | Self.ainaA2dpControlsDisable
            p.writeValue(out, for: ch, type: .withResponse)
            return
        }
        handleValue(v, from: ch)
    }
}
