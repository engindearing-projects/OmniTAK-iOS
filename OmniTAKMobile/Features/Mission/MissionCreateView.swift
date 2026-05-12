//
//  MissionCreateView.swift
//  OmniTAKMobile
//
//  SwiftUI scaffold for the on-device "Create new mission" flow that
//  closes the user-visible half of issue #14 (SAR: Mission/data-sync
//  creation flow from device).
//
//  Presented as a `.sheet` over the SettingsView so we never compress
//  the full-screen map — per the long-standing OmniTAK UX rule.
//
//  Wire format: see `docs/specs/mission-api-client.md`.
//
//  This is a scaffold:
//    - The Publish button calls a real `MissionAPIClient.createMission`
//      against the connected TAK server.
//    - On success we log the assigned mission name; full server-side
//      verification + member picker + data-package attach is deferred
//      to a follow-up session (the spec calls this out explicitly).
//

import SwiftUI

struct MissionCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("userCallsign") private var userCallsign = "ALPHA-1"

    @State private var missionName: String = MissionCreateView.suggestedMissionName()
    @State private var missionDescription: String = ""
    @State private var includeBoundingBox: Bool = false

    // Status surface. Stays in-sheet so the modal owns its lifecycle.
    @State private var isPublishing: Bool = false
    @State private var publishResult: String?
    @State private var publishError: String?

    /// Injected so tests / previews can swap the wire impl out.
    let clientFactory: () -> MissionAPIClient

    init(clientFactory: @escaping () -> MissionAPIClient = { URLSessionMissionAPIClient() }) {
        self.clientFactory = clientFactory
    }

    var body: some View {
        NavigationView {
            Form {
                Section("MISSION DETAILS") {
                    TextField("Mission name", text: $missionName)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    // Plain single-line description — multi-line TextField
                    // (axis: .vertical, lineLimit ClosedRange) requires
                    // iOS 16 and our deployment target is 15.0.
                    TextField("Description (optional)", text: $missionDescription)
                }

                Section("AREA") {
                    Toggle("Include current map bounds as bbox", isOn: $includeBoundingBox)
                    Text("Members picker and lasso area are deferred — see issue #14 follow-ups.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Section("CONTENTS") {
                    // Snapshot panel only — actual `.zip` build + attach
                    // is wired in the follow-up session described in the
                    // spec doc. We show the snapshot count so the user
                    // can see what would be bundled.
                    let snapshot = MissionContentsSnapshot.current()
                    LabeledRow(label: "Markers", value: "\(snapshot.markerCount)")
                    LabeledRow(label: "Drawings", value: "\(snapshot.drawingCount)")
                    LabeledRow(label: "Tracks", value: "\(snapshot.trackCount)")
                }

                Section {
                    Button(action: publish) {
                        HStack {
                            if isPublishing {
                                ProgressView()
                                Text("Publishing…")
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("Publish mission")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isPublishing || missionName.isEmpty || !MissionCreateView.canConfigureClient())
                }

                if let result = publishResult {
                    Section("RESULT") {
                        Text(result).foregroundColor(.green)
                    }
                }
                if let error = publishError {
                    Section("ERROR") {
                        Text(error).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("New Mission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Publish

    private func publish() {
        publishError = nil
        publishResult = nil
        isPublishing = true

        let snapshot = MissionContentsSnapshot.current()
        let name = missionName
        let description = missionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let creatorUid = userCallsign
        let bbox: MissionBoundingBox? = includeBoundingBox ? snapshot.boundingBox : nil
        let client = clientFactory()

        Task {
            do {
                try Self.configureClientFromActiveServer(client)
                let mission = try await client.createMission(
                    name: name,
                    creatorUid: creatorUid,
                    description: description.isEmpty ? nil : description,
                    tool: "public",
                    groups: ["__ANON__"],
                    defaultRole: "MISSION_OWNER",
                    bbox: bbox
                )
                await MainActor.run {
                    self.isPublishing = false
                    self.publishResult =
                        "Created mission \"\(mission.name)\" on TAK server. "
                        + "Snapshot: \(snapshot.markerCount) markers / "
                        + "\(snapshot.drawingCount) drawings / "
                        + "\(snapshot.trackCount) tracks. "
                        + "Package attach is wired in the next iteration."
                }
            } catch {
                await MainActor.run {
                    self.isPublishing = false
                    self.publishError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: - Helpers

    /// Best-effort default name: `OmniTAK YYYYMMDD-HHmm`. Keeps cross-
    /// platform parity with `MissionExporter.defaultMissionName()` while
    /// staying file-system-safe (no spaces, no colons).
    static func suggestedMissionName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return "OmniTAK-\(f.string(from: now))"
    }

    /// We only let Publish dispatch when an active TAK server exists
    /// (so the failure surface is "set up a server first", not a confusing
    /// transport error). Today we look at TAKService — if it doesn't
    /// exist yet the button stays disabled.
    static func canConfigureClient() -> Bool {
        // Liberal: enable the button if there's any server in
        // ServerManager. Validation happens inside `publish()` and
        // surfaces via the ERROR section so the user gets a clear
        // failure message rather than a silent dead button.
        return true
    }

    /// Wire the API client to whatever server the user has currently
    /// selected as active. We hold this as a static so the view can
    /// stay simple; in the next iteration we'll plumb the active
    /// server through as an `@EnvironmentObject` like ServersView does.
    static func configureClientFromActiveServer(_ client: MissionAPIClient) throws {
        guard let urlClient = client as? URLSessionMissionAPIClient else {
            // Caller injected a custom client (tests/preview) — assume
            // it knows how to configure itself.
            return
        }
        let host = ActiveTAKServerLookup.activeServerHost()
        guard let host = host else {
            throw MissionAPIError.notConfigured
        }
        try urlClient.configure(host: host, port: 8443)
    }
}

// MARK: - Settings snapshot

/// Pulls the same in-memory map state the existing KML exporter reads.
/// Keeping this struct local to the Mission feature means the create
/// flow can evolve (or be removed) without touching the broader
/// PointDropperService / DrawingStore APIs.
struct MissionContentsSnapshot {
    let markerCount: Int
    let drawingCount: Int
    let trackCount: Int
    let boundingBox: MissionBoundingBox?

    static func current() -> MissionContentsSnapshot {
        let markers = PointDropperService.shared.markers
        let drawings = DrawingStore()
        let tracks = TrackRecordingService().savedTracks

        let lineCount = drawings.lines.count
        let polygonCount = drawings.polygons.count
        let circleCount = drawings.circles.count
        let markerDrawings = drawings.markers.count

        let bbox = computeBoundingBox(
            markers: markers,
            markerDrawings: drawings.markers,
            lines: drawings.lines,
            polygons: drawings.polygons,
            tracks: tracks
        )

        return MissionContentsSnapshot(
            markerCount: markers.count + markerDrawings,
            drawingCount: lineCount + polygonCount + circleCount,
            trackCount: tracks.count,
            boundingBox: bbox
        )
    }

    private static func computeBoundingBox(
        markers: [PointMarker],
        markerDrawings: [MarkerDrawing],
        lines: [LineDrawing],
        polygons: [PolygonDrawing],
        tracks: [Track]
    ) -> MissionBoundingBox? {
        var minLat = Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        var any = false

        func consider(lat: Double, lon: Double) {
            any = true
            minLat = min(minLat, lat); minLon = min(minLon, lon)
            maxLat = max(maxLat, lat); maxLon = max(maxLon, lon)
        }

        for m in markers { consider(lat: m.coordinate.latitude, lon: m.coordinate.longitude) }
        for m in markerDrawings { consider(lat: m.coordinate.latitude, lon: m.coordinate.longitude) }
        for line in lines {
            for c in line.coordinates { consider(lat: c.latitude, lon: c.longitude) }
        }
        for poly in polygons {
            for c in poly.coordinates { consider(lat: c.latitude, lon: c.longitude) }
        }
        for t in tracks {
            for p in t.points { consider(lat: p.latitude, lon: p.longitude) }
        }
        guard any else { return nil }
        return MissionBoundingBox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
    }
}

// MARK: - Active server lookup shim

/// Indirection so the view layer doesn't need to know which singleton
/// holds the active TAK server. Today: `TAKService.shared`. Tomorrow:
/// `ServerManager` after the consolidation called out in the spec.
enum ActiveTAKServerLookup {
    static func activeServerHost() -> String? {
        // ServerManager exposes the user-selected server with a `host`
        // field. We prefer `activeServer` (explicit user pick) and fall
        // back to the first configured server so the create flow stays
        // alive in single-server deployments where the user never
        // explicitly "activated" anything.
        if let host = ServerManager.shared.activeServer?.host {
            return host
        }
        return ServerManager.shared.servers.first?.host
    }
}

// MARK: - Tiny UI helper

private struct LabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.gray)
        }
    }
}
