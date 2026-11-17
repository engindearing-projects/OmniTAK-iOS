//
//  FirstFixCamera.swift
//  OmniTAKMobile
//
//  The first position of a first launch. A new install has no camera of its own: the 3D globe
//  opened over New York and the 2D map over Washington, although the phone knows where it is a
//  second later. These are the rules for when the first fix moves the camera to the operator, what
//  the globe opens on, and what two engines hand each other. Pure, so they can be tested without
//  a map; the engines apply them.
//

import CoreLocation
import MapKit

enum FirstFixCamera {

    /// How high above the ground the globe's camera is put, in metres.
    static let globeHeight: Double = 3_000
    /// The angle the globe's camera looks down at, in degrees below the horizon (the app's usual one).
    static let globePitch: Double = -60
    /// The 2D map's zoom for the first fix (a street or two across).
    static let mapZoom: Double = 14
    /// A fix older than this is where the phone was, not where it is.
    static let maxFixAge: TimeInterval = 60

    /// Whether the first usable fix should move the camera to the operator.
    ///  - `hasSavedCamera`: this engine opens on a camera kept from an earlier session.
    ///  - `userMovedMap`: the operator has moved the map by hand in this run.
    ///  - `alreadyMoved`: this has happened once, or the operator has been sent to themselves.
    ///  - `fixIsUsable`: see `isUsable`.
    static func shouldMove(hasSavedCamera: Bool, userMovedMap: Bool, alreadyMoved: Bool, fixIsUsable: Bool) -> Bool {
        fixIsUsable && !hasSavedCamera && !userMovedMap && !alreadyMoved
    }

    /// Whether a fix is the operator's position now: a real coordinate, a known accuracy, and not
    /// older than `maxFixAge`. A cached fix from minutes ago would send the camera to where the
    /// phone used to be.
    static func isUsable(latitude: Double, longitude: Double, horizontalAccuracy: Double, age: TimeInterval) -> Bool {
        CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            && !(latitude == 0 && longitude == 0)
            && horizontalAccuracy >= 0
            && age <= maxFixAge
    }

    static func isUsable(_ location: CLLocation, now: Date) -> Bool {
        isUsable(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                 horizontalAccuracy: location.horizontalAccuracy, age: now.timeIntervalSince(location.timestamp))
    }

    /// The 2D map's view for the first fix: the operator in the middle at `mapZoom`.
    static func mapRegion(centre: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: centre, span: TacticalMapView.span(forZoom: mapZoom, latitude: centre.latitude))
    }
}

/// What the globe opens on when its page is ready.
enum GlobeStart {
    enum Plan: Equatable {
        /// The other engine's view (the operator has just switched engines).
        case seed
        /// The camera the globe was left on in an earlier session.
        case savedPose
        /// Nothing to send: the page opens on the whole world and the first fix brings it in.
        case startPose
    }

    /// The seed wins, then the saved pose, then the start pose. Nothing else decides where the
    /// globe opens: not the aircraft feed's search centre, which was always set (to a fix, or to
    /// New York) and so hid the saved pose behind it.
    static func plan(hasSeed: Bool, hasSavedPose: Bool) -> Plan {
        if hasSeed { return .seed }
        return hasSavedPose ? .savedPose : .startPose
    }
}

/// The globe camera kept from the last session (UserDefaults, written on every camera change).
struct SavedGlobePose: Equatable {
    var latitude: Double
    var longitude: Double
    var height: Double
    var heading: Double
    var pitch: Double

    /// The saved pose, or nil when there is none worth opening on: nothing saved, or the pose
    /// every launch starts at (a camera nobody chose, so a new install is still a new install).
    static func load(from defaults: UserDefaults = .standard) -> SavedGlobePose? {
        guard defaults.object(forKey: "cesium.lastLat") != nil,
              defaults.object(forKey: "cesium.lastLon") != nil,
              defaults.object(forKey: "cesium.lastHeight") != nil else { return nil }
        let pose = SavedGlobePose(
            latitude: defaults.double(forKey: "cesium.lastLat"),
            longitude: defaults.double(forKey: "cesium.lastLon"),
            height: defaults.double(forKey: "cesium.lastHeight"),
            heading: defaults.double(forKey: "cesium.lastHeading"),
            pitch: (defaults.object(forKey: "cesium.lastPitch") as? Double) ?? -60)
        return pose.isStartPose ? nil : pose
    }

    /// One of the two poses the globe starts at: New York at 50 km (every earlier version, and so
    /// what an earlier version saved for anyone who never moved the globe), or the whole world
    /// (this one). A camera nobody chose.
    var isStartPose: Bool {
        let newYork = abs(latitude - 40.6413) < 0.001 && abs(longitude + 73.7781) < 0.001
            && abs(height - 50_000) < 1_000
        let wholeWorld = abs(latitude) < 0.5 && abs(longitude) < 0.5 && height >= 19_000_000
        return newYork || wholeWorld
    }
}

/// What has happened to the camera in this run, shared by both engines. Main thread only.
final class FirstFixState {
    static let shared = FirstFixState()

    /// The globe's camera from an earlier session, read once when the app starts. The page's own
    /// start camera events rewrite the saved one within seconds, so it is read here, first.
    let launchGlobePose: SavedGlobePose?
    /// The globe had a camera from an earlier session when the app started.
    var hasSavedGlobeCamera: Bool { launchGlobePose != nil }
    private(set) var userMovedMap = false
    private(set) var alreadyMoved = false
    private var observers: [NSObjectProtocol] = []

    init(savedGlobePose: SavedGlobePose? = SavedGlobePose.load()) {
        launchGlobePose = savedGlobePose
        // Sending the map somewhere on purpose (Show on map, Go to coordinate, an opened overlay)
        // is moving it by hand, whichever engine is showing.
        for name in [Notification.Name.cesiumCenterOn, .kmlZoomToOverlay] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.operatorMovedMap()
            })
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// The operator moved the map by hand, or asked for a move of their own.
    func operatorMovedMap() {
        userMovedMap = true
    }

    /// True when a fix arriving now should move the camera. The move then counts as done.
    func claimMove(engineIsGlobe: Bool, fixIsUsable: Bool) -> Bool {
        guard FirstFixCamera.shouldMove(
            hasSavedCamera: engineIsGlobe && hasSavedGlobeCamera,
            userMovedMap: userMovedMap, alreadyMoved: alreadyMoved, fixIsUsable: fixIsUsable
        ) else { return false }
        alreadyMoved = true
        return true
    }
}
