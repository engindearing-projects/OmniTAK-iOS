//
//  RemoteIdAppBridge.swift
//  OmniTAKMobile
//
//  Adapter that connects `RemoteIdScanner`'s track stream to the
//  iOS marker pipeline. Owned by `OmniTAKMobileApp` and configured
//  once at launch; the @AppStorage("remoteIdScanEnabled") toggle
//  in Settings flips the underlying scanner on and off.
//
//  Companion to the Android `OmniTAKApp` lifecycle wiring — both
//  platforms maintain the same on/off semantics and the same
//  per-drone `RID-{uasId}` UID convention so server-side
//  deduplication works regardless of which client saw the drone
//  first.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class RemoteIdAppBridge: ObservableObject {

    static let shared = RemoteIdAppBridge()

    /// Underlying scanner. Exposed read-only so callers can peek at
    /// `scanner.tracks` (e.g. for a diagnostics screen) without
    /// being able to start/stop it directly — toggling is done via
    /// `setEnabled` so the @AppStorage flag stays in sync.
    let scanner: RemoteIdScanner

    private var enabled: Bool = false
    private let markerStore: PointDropperService

    private init() {
        self.scanner = RemoteIdScanner()
        self.markerStore = PointDropperService.shared
        // The scanner contract says it calls onTrackUpdate on main, and
        // the BLE delegate sites honor that (queue: .main). The stale-
        // purge Timer adds to whichever run loop start() was called from
        // and, under heavy 3D-globe interaction, can fire when main
        // isn't in its default mode — observed in syslog as SwiftUICore
        // `Publishing changes from background threads is not allowed`.
        // Hop to main explicitly so any future contract drift can't
        // crash the app the way the prior PPLI off-main publish did
        // (commit 7e41060). Pattern matches that fix verbatim.
        self.scanner.onTrackUpdate = { [weak self] update in
            DispatchQueue.main.async { [weak self] in
                self?.applyUpdate(update)
            }
        }
    }

    /// Mirror the @AppStorage value into the scanner. Idempotent.
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value {
            scanner.start()
        } else {
            scanner.stop()
        }
    }

    // MARK: - Marker synchronization

    private func applyUpdate(_ update: RemoteIdTrackUpdate) {
        // Belt-and-suspenders: applyUpdate mutates `markerStore.markers`
        // which is @Published. SwiftUI observers crash if mutations
        // arrive off-main. Any future call site that forgets to hop
        // will trip this assertion in debug instead of corrupting
        // observers in release.
        dispatchPrecondition(condition: .onQueue(.main))
        for uasId in update.changedUasIds {
            if let track = scanner.tracks.first(where: { $0.uasId == uasId }) {
                upsertMarker(for: track)
            } else {
                removeMarker(uasId: uasId)
            }
        }
    }

    private func upsertMarker(for track: RemoteIdTrack) {
        guard let marker = RemoteIdToPointMarkerConverter.toPointMarker(track) else { return }

        if let existingIndex = markerStore.markers.firstIndex(where: { $0.uid == marker.uid }) {
            // Preserve the original id (UUID) so SwiftUI lists and
            // any subscribers tracking by id don't see a churn.
            var updated = marker
            updated = PointMarker(
                id: markerStore.markers[existingIndex].id,
                name: marker.name,
                affiliation: marker.affiliation,
                coordinate: marker.coordinate,
                altitude: marker.altitude,
                remarks: marker.remarks,
                createdBy: marker.createdBy,
                isBroadcast: marker.isBroadcast
            )
            updated.uid = marker.uid
            updated.cotType = marker.cotType
            markerStore.markers[existingIndex] = updated
        } else {
            markerStore.markers.append(marker)
        }
    }

    private func removeMarker(uasId: String) {
        let uid = "RID-" + uasId
        markerStore.markers.removeAll { $0.uid == uid }
    }
}
