//
//  QuickMarkService.swift
//  OmniTAKMobile
//
//  One-tap "Mark My Position" for SAR — iOS port of the Android vc40
//  PinDrop FAB. Closes K9Blue's TROP feedback (5/9/26): "no option for
//  dropping a waypoint/marker on your current position … having to lock
//  onto your own position and create a waypoint takes a lot of time
//  when we need to be watching our dogs." Drops a friendly marker at
//  the operator's current GPS fix, names it with an HHMM timestamp so
//  it reconciles against field notes later, persists it locally via
//  PointDropperService, and fans the CoT out to every connected server
//  via TAKService.shared.sendCoT.
//

import Foundation
import CoreLocation

final class QuickMarkService {
    static let shared = QuickMarkService()

    /// Returns a fresh "MyPos-HHMM" callsign. UTC HHMM mirrors the
    /// Android `MarkerCoT.timestampedCallsign` formatter so a SAR pair
    /// running iOS + Android sees the same label when both drop a pin
    /// in the same minute.
    static func timestampedCallsign(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return "MyPos-\(f.string(from: now))"
    }

    /// Drops a friendly point marker at the supplied GPS fix, persists
    /// it through `PointDropperService`, and broadcasts the CoT to all
    /// connected servers. Returns the created marker so the caller can
    /// toast the user with its name.
    @discardableResult
    func markCurrentPosition(
        at location: CLLocation,
        broadcast: Bool = true,
        now: Date = Date(),
        pointDropper: PointDropperService = .shared,
        takService: TAKService = .shared
    ) -> PointMarker {
        let callsign = Self.timestampedCallsign(now: now)
        let marker = pointDropper.createMarker(
            name: callsign,
            affiliation: .friendly,
            coordinate: location.coordinate,
            altitude: location.altitude,
            createdBy: "QuickMark",
            broadcast: false // we drive the broadcast below so the
            // `broadcast` flag here is honoured even when the dropper
            // service is in a partial-init state.
        )

        if broadcast {
            let xml = MarkerCoTGenerator.generateCoT(for: marker, staleTime: 3600)
            _ = takService.sendCoT(xml: xml)
        }

        return marker
    }
}
