//
//  MeshFrameworkDevicePickerView.swift
//  OmniTAK Mobile
//
//  Top-level mesh-framework selector + per-framework connect flow. Lets the
//  operator choose Meshtastic or MeshCore (persisted via
//  @AppStorage("selectedMeshFramework")) and routes to the matching device
//  picker: the existing MeshtasticDevicePickerView, or the MeshCore BLE scan
//  below (Nordic UART companion radios only).
//

import SwiftUI
import CoreBluetooth

struct MeshFrameworkDevicePickerView: View {
    @ObservedObject var meshtasticManager: MeshtasticManager
    @AppStorage(MeshFramework.storageKey) private var selectedFrameworkRaw: String = MeshFramework.meshtastic.rawValue
    @Environment(\.dismiss) private var dismiss

    private var selectedFramework: MeshFramework {
        MeshFramework(rawValue: selectedFrameworkRaw) ?? .meshtastic
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Mesh framework selector (Meshtastic | MeshCore)
                Picker("Mesh Framework", selection: $selectedFrameworkRaw) {
                    ForEach(MeshFramework.allCases) { fw in
                        Label(fw.displayName, systemImage: fw.iconName).tag(fw.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                switch selectedFramework {
                case .meshtastic:
                    // Reuse the existing Meshtastic picker body (BLE + TCP tabs).
                    MeshtasticDevicePickerBody(manager: meshtasticManager)
                case .meshcore:
                    if #available(iOS 13.0, *) {
                        MeshCoreBLEConnectView(manager: MeshCoreManager.shared)
                    } else {
                        Text("MeshCore requires iOS 13 or later.")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Connect Mesh Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Meshtastic picker body (selector-embedded variant)

/// The Meshtastic BLE/TCP picker rendered *inside* the framework selector. It
/// delegates to the existing `MeshtasticDevicePickerView` (which has its own
/// NavigationView/toolbar) so Meshtastic behavior is untouched.
private struct MeshtasticDevicePickerBody: View {
    @ObservedObject var manager: MeshtasticManager
    var body: some View {
        MeshtasticDevicePickerView(manager: manager)
    }
}

// MARK: - MeshCore BLE connect view

@available(iOS 13.0, *)
private struct MeshCoreBLEConnectView: View {
    @ObservedObject var manager: MeshCoreManager
    @ObservedObject private var transport: MeshCoreBLETransport

    init(manager: MeshCoreManager) {
        self.manager = manager
        self.transport = manager.bleTransport
    }

    var body: some View {
        VStack(spacing: 0) {
            bluetoothStatusBanner

            if transport.needsBluetoothRepair {
                pairingRepairBanner
            }

            if manager.isConnected {
                connectedDeviceCard.padding()
            }

            List {
                if !transport.knownDevices.isEmpty {
                    Section {
                        ForEach(transport.knownDevices) { device in
                            Button {
                                manager.stopBLEScanning()
                                manager.connectBLE(device: device)
                            } label: {
                                MeshCoreDeviceRow(name: device.name,
                                                  subtitle: "Paired — tap to reconnect",
                                                  systemImage: "dot.radiowaves.left.and.right")
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    manager.forgetBLEDevice(id: device.id)
                                } label: { Label("Forget", systemImage: "trash") }
                            }
                        }
                    } header: {
                        Text("Paired Devices")
                    } footer: {
                        Text("Tap to reconnect instantly — no scan or re-pairing needed.")
                    }
                }

                Section {
                    if transport.isScanning {
                        HStack {
                            ProgressView().padding(.trailing, 8)
                            Text("Scanning for MeshCore radios…").foregroundColor(.secondary)
                        }
                    } else if transport.discoveredDevices.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 36)).foregroundColor(.secondary)
                            Text("No MeshCore Radios Found")
                                .font(.headline).foregroundColor(.secondary)
                            Text("Make sure your MeshCore companion radio is powered on and in range. Only radios running MeshCore companion firmware (Nordic UART) appear here — not Meshtastic.")
                                .font(.subheadline).foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Button(action: { manager.startBLEScanning() }) {
                                Label("Start Scanning", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent).padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 32)
                        .listRowBackground(Color.clear)
                    }

                    ForEach(transport.discoveredDevices) { device in
                        Button {
                            manager.stopBLEScanning()
                            manager.connectBLE(device: device)
                        } label: {
                            MeshCoreDeviceRow(name: device.name,
                                              subtitle: "RSSI: \(device.rssi) dBm",
                                              systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Nearby MeshCore Radios")
                        Spacer()
                        if transport.isScanning {
                            Button("Stop") { manager.stopBLEScanning() }.font(.caption)
                        } else {
                            Button("Scan") { manager.startBLEScanning() }.font(.caption)
                        }
                    }
                } footer: {
                    Text("When pairing, enter the 6-digit code shown on the node's screen, or \(MeshCoreBLEUUID.defaultPairingPin) if it has no screen.")
                }
            }
            .listStyle(.insetGrouped)
        }
        .onAppear {
            guard transport.bluetoothState == .poweredOn else { return }
            manager.refreshKnownBLEDevices()
            if !manager.isConnected {
                manager.reconnectLastBLEDevice()
                manager.startBLEScanning()
            }
        }
        .onDisappear { manager.stopBLEScanning() }
    }

    private var connectedDeviceCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle().fill(Color.green).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transport.connectedPeripheral?.name ?? "MeshCore Radio").font(.headline)
                    if !manager.selfPubKeyHex.isEmpty {
                        Text(String(manager.selfPubKeyHex.prefix(8)).uppercased())
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    if manager.batteryPercent >= 0 {
                        Label("\(manager.batteryPercent)%", systemImage: "battery.100")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if !manager.meshNodes.isEmpty {
                        Text("\(manager.meshNodes.count) nodes")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Button(action: { manager.disconnect() }) {
                Text("Disconnect")
                    .font(.subheadline).fontWeight(.medium).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.red).cornerRadius(8)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var bluetoothStatusBanner: some View {
        Group {
            switch transport.bluetoothState {
            case .poweredOff:
                banner("Bluetooth is turned off", icon: "bluetooth.slash", color: .orange)
            case .unauthorized:
                banner("Bluetooth permission required", icon: "lock.fill", color: .red)
            case .unsupported:
                banner("Bluetooth not supported", icon: "xmark.circle.fill", color: .red)
            default:
                EmptyView()
            }
        }
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text)
            Spacer()
        }
        .padding()
        .background(color.opacity(0.15))
        .foregroundColor(color)
    }

    private var pairingRepairBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing out of sync").font(.subheadline).fontWeight(.semibold)
                Text("Open iOS Settings → Bluetooth, tap your MeshCore device, choose “Forget This Device,” then reconnect here.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gear").font(.caption.weight(.semibold))
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.15))
        .foregroundColor(.orange)
    }
}

// MARK: - MeshCore device row

@available(iOS 13.0, *)
private struct MeshCoreDeviceRow: View {
    let name: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20)).foregroundColor(.blue).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }
}
