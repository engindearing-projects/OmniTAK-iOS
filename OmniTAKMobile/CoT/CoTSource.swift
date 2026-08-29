//
//  CoTSource.swift
//  OmniTAKMobile
//
//  #180 — How an ingested CoT event arrived. Tagged at the ingest point so the
//  marker / contact detail sheet can show the operator which transport carried a
//  point, for debugging comms ("is this guy coming over the server or the mesh?").
//
//  `transport` is the broad bucket; `detail` is the specific endpoint within it
//  (a server name for TAK, the mesh framework name for mesh). Kept as a small
//  value so it can ride along on a `CoTEvent` for display/debug only — it never
//  rides the wire. Ported one-to-one from the Android CoTSource data class so the
//  labels match.
//

import Foundation

struct CoTSource: Equatable {
    enum Transport: Equatable {
        case takServer
        case mesh
        case local
        case other
    }

    let transport: Transport
    /// Specific endpoint: the TAK server name, or the mesh framework name.
    /// Nil when only the broad transport is known.
    let detail: String?

    init(transport: Transport, detail: String? = nil) {
        self.transport = transport
        // Treat blank as absent so "TAK: " never renders an empty endpoint.
        if let d = detail, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.detail = d
        } else {
            self.detail = nil
        }
    }

    /// A point that arrived over a TAK server (TCP/TLS over ethernet/Wi-Fi).
    static func takServer(_ serverName: String?) -> CoTSource {
        CoTSource(transport: .takServer, detail: serverName)
    }

    /// A point that arrived over a mesh radio (Meshtastic / MeshCore).
    static func mesh(_ framework: String?) -> CoTSource {
        CoTSource(transport: .mesh, detail: framework)
    }

    /// The tag every Meshtastic radio ingest point stamps. #113 depends on it:
    /// an untagged event resolves to `.takServer` at ingest, so with gateway mode
    /// on, radio traffic that forgot to tag would be relayed straight back onto
    /// the channel it just came off.
    static let meshtasticRadio = CoTSource.mesh("Meshtastic")

    /// An operator-dropped / device-local point that never traversed a link.
    static let local = CoTSource(transport: .local)

    /// Human label for the detail sheet, e.g. "TAK: HQ-Server", "Mesh: Meshtastic",
    /// "Mesh: MeshCore", "Local". Pure — unit-tested in CoTSourceTests.
    var label: String {
        switch transport {
        case .takServer: return detail != nil ? "TAK: \(detail!)" : "TAK server"
        case .mesh: return detail != nil ? "Mesh: \(detail!)" : "Mesh"
        case .local: return "Local"
        case .other: return detail ?? "Other"
        }
    }
}
