//
//  LocationManager.swift
//  OmniTAKMobile
//
//  Operator GPS source shared app-wide (LocationManager.shared).
//  Extracted from MapViewController.swift — mechanical move, no behavior change.
//

import SwiftUI
import CoreLocation

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var accuracy: Double = 0
    @Published var heading: CLHeading?
    @Published var course: Double = 0
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// True once the system has reported the permission status (even "not determined"). Until then
    /// `authorizationStatus` is only the starting value, and the system may be slow to answer.
    @Published private(set) var hasReportedAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest

        // Enable background location updates for navigation and position tracking
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true

        // Nothing is asked and nothing is read from the location service here. This runs while
        // the app is still starting, and `manager.authorizationStatus` is a call that waits for
        // the system on the main thread: when the system is slow to answer the app showed a blank
        // white screen. The status arrives in `locationManagerDidChangeAuthorization`, which the
        // system calls right after the manager is created. Updates start by themselves once the
        // user has said yes.
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    /// Puts the location question to the user if `LocationPrompt` says this is the moment. Asked
    /// through one long-lived manager: a question put by a manager that goes away is withdrawn.
    func ask(at moment: LocationPrompt.Moment) {
        let done = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if LocationPrompt.shouldAskWhenInUse(at: moment, status: authorizationStatus, onboardingCompleted: done) {
            manager.requestWhenInUseAuthorization()
        }
    }

    func startUpdating() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Read inside the system's own callback, where the answer is already here.
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            self.authorizationStatus = status
            self.hasReportedAuthorization = true
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
        accuracy = locations.last?.horizontalAccuracy ?? 0
        course = locations.last?.course ?? 0
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] Location error: \(error.localizedDescription)")
    }
}
