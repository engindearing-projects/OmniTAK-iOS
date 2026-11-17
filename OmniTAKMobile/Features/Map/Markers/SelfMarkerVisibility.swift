//
//  SelfMarkerVisibility.swift
//  OmniTAKMobile
//
//  Issue #134: hide my own marker on the map. UI only.
//
//  The operator can switch off the marker that shows their own position
//  (Settings > Map Overlays > "Show my marker"). It is a drawing choice and
//  nothing else. Position reporting (PositionBroadcastService), follow-me,
//  centre-on-me and heading all keep running off the same GPS fix, and the
//  chosen marker style (milstd / bullseye / arrow) is kept for when the marker
//  is switched back on. Android has the same switch (OmniTAK-Android #210).
//
//  Both map engines draw the marker, so the rules sit here as plain functions
//  that unit tests can reach without a map view:
//    - 2D (TacticalMapView): the Mapbox location puck.
//    - 3D (CesiumMainMap): the `__self__` entity, left out of the entity list.
//

import Foundation

enum SelfMarkerVisibility {

    /// UserDefaults / `@AppStorage` key. A Bool; a key nobody has written
    /// means "visible", which is why every `@AppStorage` that reads it passes
    /// `defaultVisible` (`UserDefaults.bool(forKey:)` would read a missing key
    /// as `false` and hide the marker on a fresh install).
    static let defaultsKey = "selfMarkerVisible"

    /// The marker is shown unless the operator switches it off.
    static let defaultVisible = true

    /// 2D engine: the Mapbox puck is installed only when location display is
    /// on AND the operator has not hidden their marker. Also decides whether a
    /// tap on the spot where the puck would be opens the reposition sheet:
    /// nothing is drawn there when it is hidden, so nothing should react.
    static func showsPuck(showsUserLocation: Bool, selfMarkerVisible: Bool) -> Bool {
        showsUserLocation && selfMarkerVisible
    }
}
