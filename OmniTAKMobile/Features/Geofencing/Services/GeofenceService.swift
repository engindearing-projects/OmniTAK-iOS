//
//  GeofenceService.swift
//  OmniTAKMobile
//
//  Watches the geofences. It is started once at launch and does nothing until at least one
//  geofence is switched on; then it listens to the streams the app already has:
//    - the operator's own position: `LocationManager.shared`, the app's one GPS source
//    - teammates: `CoTEventHandler.positionUpdatePublisher`, the stream every inbound position
//      goes through, whether it came from a TAK server or over a mesh radio
//  and hands each position to the pure `GeofenceMonitor`, which decides what happened.
//
//  It owns no location manager and asks for no permission: the app's GPS source already
//  holds the location authorisation, and notification permission is asked for the first time
//  a geofence is saved (`requestNotificationPermissionIfNeeded`), never at launch.
//
//  Everything here runs on the main thread, and every @Published change is made there.
//  No CoT is sent for a geofence event: `GeofenceCoTGenerator` is not used by this service.
//

import Foundation
import CoreLocation
import Combine
import UserNotifications
import UIKit

final class GeofenceService: ObservableObject {
    static let shared = GeofenceService()

    // MARK: - What the screens read

    /// What happened, newest first, kept across launches.
    @Published private(set) var recentEvents: [GeofenceEvent] = []
    /// Who is inside each zone now.
    @Published private(set) var occupancy: [UUID: GeofenceOccupancy] = [:]
    /// The alert on its way across the top of the map, if any.
    @Published private(set) var banner: GeofenceBanner?

    // MARK: - Configuration

    private let maxRecentEvents = 100
    private let eventsKey = "com.omnitak.geofence.events"
    /// Seconds between passes that give stationary subjects' last positions again (so a dwell
    /// fires without a new report) and forget contacts that have gone.
    private let tickInterval: TimeInterval = 10

    // MARK: - State

    private let manager: GeofenceManager
    private let defaults: UserDefaults
    private var monitor = GeofenceMonitor()
    private var bannerQueue = GeofenceBannerQueue()
    private var zones: [Geofence] = []
    private var started = false

    private var zonesCancellable: AnyCancellable?
    private var locationCancellable: AnyCancellable?
    private var contactCancellable: AnyCancellable?
    private var tickTimer: Timer?
    private var bannerTimeout: DispatchWorkItem?

    /// A subject's last known position, for giving it to the monitor again.
    private struct Subject {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let isOperator: Bool
    }
    private var operatorSubject: Subject?
    private var contactSubjects: [String: Subject] = [:]

    /// The app's one service uses the app's own geofences and defaults; a test passes its own.
    init(manager: GeofenceManager = .shared, defaults: UserDefaults = .standard) {
        self.manager = manager
        self.defaults = defaults
        loadEvents()
    }

    deinit {
        tickTimer?.invalidate()
    }

    /// What the service is doing right now. It listens and ticks only while a geofence needs it,
    /// so a test reads this to check that it lets go of everything when the last one goes.
    struct Activity: Equatable {
        var listensToOperator = false
        var listensToContacts = false
        var ticks = false

        static let idle = Activity()
    }

    var activity: Activity {
        Activity(listensToOperator: locationCancellable != nil,
                 listensToContacts: contactCancellable != nil,
                 ticks: tickTimer != nil)
    }

    // MARK: - Start

    /// Starts watching the geofence list. Cheap when there are none: it subscribes to nothing
    /// else and starts no timer until a geofence is switched on.
    func start() {
        guard !started else { return }
        started = true
        zonesCancellable = manager.$geofences.sink { [weak self] zones in
            self?.onMain { self?.apply(zones: zones) }
        }
    }

    /// The geofence list changed (one was made, switched, deleted): listen to what the
    /// switched-on ones watch, and take a baseline of everyone already known.
    private func apply(zones: [Geofence]) {
        self.zones = zones
        monitor.retain(zones: zones)

        let monitored = zones.filter { $0.isActive && $0.hasUsableShape }
        let wantsOperator = monitored.contains { $0.watchSelf }
        let wantsContacts = monitored.contains { $0.watchContacts }

        setOperatorInput(on: wantsOperator)
        setContactInput(on: wantsContacts)
        setTick(on: wantsOperator || wantsContacts)

        if wantsOperator || wantsContacts { refeed(now: Date()) }
        publishOccupancy()
    }

    // MARK: - Inputs

    private func setOperatorInput(on: Bool) {
        guard on else {
            locationCancellable = nil
            operatorSubject = nil
            return
        }
        guard locationCancellable == nil else { return }
        // Delivers the current position at once, which is the baseline for a new geofence.
        locationCancellable = LocationManager.shared.$location.sink { [weak self] location in
            self?.onMain { self?.handle(location: location) }
        }
    }

    private func setContactInput(on: Bool) {
        guard on else {
            contactCancellable = nil
            contactSubjects.removeAll()
            return
        }
        seedContacts()
        guard contactCancellable == nil else { return }
        contactCancellable = CoTEventHandler.shared.positionUpdatePublisher.sink { [weak self] event in
            self?.onMain { self?.handle(contact: event) }
        }
    }

    private func setTick(on: Bool) {
        guard on else {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.onMain { self?.tickOnce() }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Positions in

    private func handle(location: CLLocation?) {
        // A negative accuracy means the fix is not valid.
        guard let location, location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else { return }
        let subject = Subject(id: PositionBroadcastService.shared.userUID,
                              name: PositionBroadcastService.shared.userCallsign,
                              coordinate: location.coordinate,
                              isOperator: true)
        operatorSubject = subject
        ingest(subject, now: Date())
    }

    private func handle(contact event: CoTEvent) {
        guard let subject = teammate(from: event) else { return }
        contactSubjects[subject.id] = subject
        ingest(subject, now: Date())
    }

    private func teammate(from event: CoTEvent) -> Subject? {
        guard GeofenceSubjectRule.isTeammate(uid: event.uid, type: event.type, how: event.how,
                                             selfUID: PositionBroadcastService.shared.userUID) else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: event.point.lat, longitude: event.point.lon)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let callsign = event.detail.callsign
        return Subject(id: event.uid, name: callsign.isEmpty ? event.uid : callsign,
                       coordinate: coordinate, isOperator: false)
    }

    /// Contacts already on the map when a geofence starts watching them, so they get a baseline
    /// now rather than at their next report.
    private func seedContacts() {
        let hidden = ContactMaxAgeMonitor.shared.hidden
        for event in TAKService.shared.cotEvents where contactSubjects[event.uid] == nil && hidden[event.uid] == nil {
            if let subject = teammate(from: event) { contactSubjects[subject.id] = subject }
        }
    }

    // MARK: - Each pass

    private func tickOnce() {
        let now = Date()
        forgetContactsThatHaveGone()
        refeed(now: now)
        bannerQueue.tick(now: now)
        syncBanner()
    }

    /// A contact removed from the map, or hidden for not having been heard from, raises nothing
    /// and is forgotten.
    private func forgetContactsThatHaveGone() {
        guard !contactSubjects.isEmpty else { return }
        let present = Set(TAKService.shared.cotEvents.map { $0.uid })
        let hidden = ContactMaxAgeMonitor.shared.hidden
        for id in Array(contactSubjects.keys) where !present.contains(id) || hidden[id] != nil {
            contactSubjects[id] = nil
            monitor.forget(subject: id)
        }
    }

    /// Everyone's last known position, again, at `now`: a subject that is standing still sends
    /// nothing new, and dwell needs the time to move on.
    private func refeed(now: Date) {
        if let subject = operatorSubject { ingest(subject, now: now) }
        for subject in contactSubjects.values { ingest(subject, now: now) }
    }

    private func ingest(_ subject: Subject, now: Date) {
        let transitions = monitor.update(subject: subject.id, name: subject.name,
                                         coordinate: subject.coordinate, now: now,
                                         zones: zones, isOperator: subject.isOperator)
        if !transitions.isEmpty { deliver(transitions) }
        publishOccupancy()
    }

    private func publishOccupancy() {
        var fresh: [UUID: GeofenceOccupancy] = [:]
        for zone in zones where zone.isActive && zone.hasUsableShape {
            fresh[zone.id] = monitor.occupancy(of: zone.id)
        }
        if fresh != occupancy { occupancy = fresh }
    }

    // MARK: - Alerts out

    private func deliver(_ transitions: [GeofenceTransition]) {
        for transition in transitions {
            let sentence = GeofenceAlertText.sentence(for: transition)
            addEvent(GeofenceEvent(geofenceId: transition.geofenceID,
                                   geofenceName: transition.geofenceName,
                                   eventType: transition.type,
                                   coordinate: transition.coordinate,
                                   userId: transition.subjectID,
                                   dwellDuration: transition.stay,
                                   userName: transition.subjectName,
                                   byOperator: transition.isOperator,
                                   timestamp: transition.time))
            bannerQueue.add(GeofenceBanner(sentence: sentence, type: transition.type,
                                           geofenceID: transition.geofenceID), now: Date())
            provideHapticFeedback(for: transition.type)
            sendLocalNotificationIfInBackground(sentence)
        }
        syncBanner()
    }

    // MARK: - The banner

    /// The banner on screen was tapped, or closed: show the next one.
    func dismissBanner() {
        bannerQueue.dismissCurrent(now: Date())
        syncBanner()
    }

    /// Puts the queue's front on the published banner and sets the moment it is due to go.
    private func syncBanner() {
        if banner != bannerQueue.current { banner = bannerQueue.current }
        bannerTimeout?.cancel()
        bannerTimeout = nil
        guard let until = bannerQueue.showUntil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bannerQueue.tick(now: Date())
            self.syncBanner()
        }
        bannerTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow), execute: work)
    }

    // MARK: - History

    private func addEvent(_ event: GeofenceEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > maxRecentEvents {
            recentEvents = Array(recentEvents.prefix(maxRecentEvents))
        }
        saveEvents()
    }

    func clearEvents() {
        recentEvents.removeAll()
        saveEvents()
    }

    private func saveEvents() {
        if let data = try? JSONEncoder().encode(recentEvents) {
            defaults.set(data, forKey: eventsKey)
        }
    }

    private func loadEvents() {
        if let data = defaults.data(forKey: eventsKey),
           let events = try? JSONDecoder().decode([GeofenceEvent].self, from: data) {
            recentEvents = events
        }
    }

    // MARK: - Notifications

    /// Asks for permission to show notifications, once, if nobody has decided yet. Called when
    /// a geofence is saved: only someone who has made one has a use for the answer.
    func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// With the app in the background the banner is not seen, so the same sentence goes out as
    /// a local notification (it is shown only if notifications are allowed).
    private func sendLocalNotificationIfInBackground(_ sentence: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = L("geofence.notification.title")
        content.body = sentence
        content.sound = .default
        content.categoryIdentifier = "GEOFENCE_ALERT"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
            withCompletionHandler: nil)
    }

    // MARK: - Haptic feedback

    private func provideHapticFeedback(for type: GeofenceEventType) {
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch type {
        case .entry: style = .heavy
        case .exit: style = .medium
        case .dwell: style = .rigid
        }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}
