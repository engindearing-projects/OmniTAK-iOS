//
//  MeshOwnerSync.swift
//  OmniTAKMobile
//
//  iOS pair of Android's `OmniTAKApp.startMeshOwnerSync()`. When the
//  operator's TAK callsign changes (UserDefaults key `userCallsign`,
//  backing the @AppStorage in SettingsView) AND a Meshtastic radio is
//  connected, push a `set_owner` AdminMessage so the mesh node wears
//  the same callsign as the TAK client. Pairs with the TAK_TRACKER
//  self-dedup in MeshtasticCOTBridge.
//
//  Gated by UserDefaults key `autoSyncCallsignToMesh`, default true.
//  Pull-on-change + pull-on-mesh-connect, no polling.
//

import Foundation
import Combine
import os

@MainActor
final class MeshOwnerSync {
    static let shared = MeshOwnerSync()

    private let log = Logger(subsystem: "com.omnitak.mobile", category: "mesh.owner.sync")
    private var cancellables = Set<AnyCancellable>()
    private var lastPushed: String? = nil

    func start() {
        // Initial sync on app launch — in case the radio was connected
        // out of band (e.g. auto-reconnect on TCP transport).
        Task { await self.syncIfReady() }

        // Whenever any UserDefault changes, re-evaluate. Cheap because
        // we early-bail on no-callsign-change / not-connected.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.syncIfReady() }
            }
            .store(in: &cancellables)

        // Whenever Meshtastic connects (or reconnects), force a sync so
        // a freshly-plugged radio adopts our callsign. `isConnected` is
        // a computed property, so we observe the underlying
        // `connectedDevice` publisher and react when it transitions to
        // a non-nil, connected device.
        MeshtasticManager.shared.$connectedDevice
            .map { $0?.isConnected ?? false }
            .removeDuplicates()
            .filter { (connected: Bool) in connected }
            .sink { [weak self] _ in
                self?.lastPushed = nil
                Task { await self?.syncIfReady() }
            }
            .store(in: &cancellables)
    }

    private func syncIfReady() async {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "autoSyncCallsignToMesh") as? Bool ?? true
        guard enabled else { return }

        let callsign = (defaults.string(forKey: "userCallsign") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callsign.isEmpty else { return }
        if callsign == lastPushed { return }

        guard MeshtasticManager.shared.isConnected else {
            log.debug("Mesh not connected; deferring callsign sync (\(callsign)).")
            return
        }

        guard let derived = MeshOwnerNames.derive(callsign) else { return }
        let ok = await MeshtasticManager.shared.pushOwnerName(
            longName: derived.long,
            shortName: derived.short,
        )
        if ok {
            lastPushed = callsign
            log.info("Pushed mesh owner: \(derived.long, privacy: .public) / \(derived.short, privacy: .public)")
        } else {
            log.warning("pushOwnerName failed for \(callsign, privacy: .public)")
        }
    }
}
