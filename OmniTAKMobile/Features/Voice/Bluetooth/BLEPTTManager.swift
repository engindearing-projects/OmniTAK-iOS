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
enum PTTButtonEvent { case pttDown(slot: Int), pttUp(slot: Int), emergency }

final class BLEPTTManager: NSObject, ObservableObject {
    enum Kind: String { case ainaV2 = "AINA APTT V2", pryme = "Pryme BT-PTT-Z", bt02 = "Inrico BT02" }

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
        isScanning = true
        status = "Scanning…"
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.stopScan() }
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
        if n.hasPrefix("aptt") { return .ainaV2 }
        if n.hasPrefix("b02ptt") { return .bt02 }
        if n.contains("pryme") || n.contains("bt-ptt") || n.contains("ptt-z") || services.contains(UUIDs.prymeService) { return .pryme }
        return nil
    }

    // MARK: - Decoding

    private func handleValue(_ data: Data, from char: CBCharacteristic) {
        guard let b = data.first, let k = kind else { return }
        switch k {
        case .ainaV2:
            guard char.uuid == UUIDs.ainaButton else { return }
            let mask = b & 0x3F
            let changed = mask ^ lastAinaMask
            lastAinaMask = mask
            if changed & 0x01 != 0 { emit(mask & 0x01 != 0 ? .pttDown(slot: 1) : .pttUp(slot: 1)) }   // PTT
            if changed & 0x04 != 0 { emit(mask & 0x04 != 0 ? .pttDown(slot: 2) : .pttUp(slot: 2)) }   // PTTS → VS2
            if changed & 0x02 != 0, mask & 0x02 != 0 { emit(.emergency) }
        case .pryme:
            emit(b != 0 ? .pttDown(slot: 1) : .pttUp(slot: 1))
        case .bt02:
            guard char.uuid == UUIDs.bt02Button else { return }
            switch b {
            case 0x00: emit(.pttUp(slot: 1))
            case 0x01: emit(.pttDown(slot: 1))
            case 0x08: emit(.emergency)
            default: break
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
        switch c.state {
        case .poweredOn: status = savedPeripheralId == nil ? "No button paired" : "Reconnecting…"; reconnectSaved()
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
        guard let k = Self.classify(name: name, services: services) else { return }
        let d = Discovered(id: p.identifier, name: name ?? k.rawValue, kind: k, rssi: rssi.intValue)
        if let i = discovered.firstIndex(where: { $0.id == d.id }) { discovered[i].rssi = d.rssi }
        else { discovered.append(d) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connectedName = p.name ?? kind?.rawValue
        status = "Connected: \(connectedName ?? "button")"
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "Couldn't connect: \(error?.localizedDescription ?? "unknown")"
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
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
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
