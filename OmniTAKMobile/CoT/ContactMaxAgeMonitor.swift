//
//  ContactMaxAgeMonitor.swift
//  OmniTAKMobile
//
//  #137: Runs the contact max age rule (ContactMaxAge) on a timer and on every
//  position report, and publishes the result so the map and the contact list read
//  the SAME decision: `hidden` is the single answer to "which contacts are off the
//  map right now", and the contact list's "not heard from" section is built from
//  it too.
//
//  The timer is what makes a contact that went quiet disappear without anything
//  arriving. A new report does not wait for the timer: `reportReceived` takes the
//  contact out of `hidden` at once.
//
//  Everything is injected (clock, setting, stores, interval) so the tests drive it
//  with in-memory stores and a short interval, without TAKService or ChatManager.
//  All calls are on the main thread, like the stores' writers.
//

import Foundation
import Combine
import UIKit

final class ContactMaxAgeMonitor: ObservableObject {

    /// The app's one monitor, wired to the real stores.
    static let shared = ContactMaxAgeMonitor()

    /// What the monitor reads and what it removes from.
    struct Stores {
        /// The map's event store (`TAKService.cotEvents`).
        var events: () -> [CoTEvent]
        /// The contact list (`ChatManager.participants`).
        var participants: () -> [ChatParticipant]
        /// This operator's own uid, which the rule never touches.
        var selfUID: () -> String?
        /// Removes these contacts from both stores. It must not touch any chat
        /// conversation.
        var remove: (Set<String>) -> Void

        /// The real stores. The closures look the singletons up when they run, not
        /// when the monitor is made, so creating the monitor touches nothing.
        static let live = Stores(
            events: { TAKService.shared.cotEvents },
            participants: { ChatManager.shared.participants },
            selfUID: { PositionBroadcastService.shared.userUID },
            remove: { uids in
                let service = TAKService.shared
                // Only write the published array when something is in it to
                // remove, so a removal that is only a saved contact does not
                // redraw the map.
                if service.cotEvents.contains(where: { uids.contains($0.uid) }) {
                    service.cotEvents.removeAll { uids.contains($0.uid) }
                }
                ChatManager.shared.removeParticipants(ids: uids)
            }
        )
    }

    /// The contacts hidden right now, each with when this device last received a
    /// report from it. A contact is in here from its max age up to twice it, then
    /// it is removed and gone from here.
    @Published private(set) var hidden: [String: Date] = [:]

    private let stores: Stores
    private let interval: TimeInterval
    private let now: () -> Date
    private let maxAgeMinutes: () -> Int
    private var timer: Timer?
    private var foregroundObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - interval: seconds between passes. 30 in the app.
    ///   - now: the clock.
    ///   - maxAgeMinutes: the setting, read at every pass.
    init(interval: TimeInterval = 30,
         now: @escaping () -> Date = { Date() },
         maxAgeMinutes: @escaping () -> Int = { ContactMaxAge.currentMinutes() },
         stores: Stores = .live) {
        self.interval = interval
        self.now = now
        self.maxAgeMinutes = maxAgeMinutes
        self.stores = stores
    }

    deinit {
        stop()
    }

    // MARK: - Running

    /// Starts the timer, and a pass whenever the app comes back to the foreground
    /// (a backgrounded app has no timer running). Safe to call twice. It does not
    /// read the stores before it returns, so it can be called while a singleton is
    /// still being made.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        // .common so the pass still runs while the operator is panning the map.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluate()
        }
        DispatchQueue.main.async { [weak self] in
            self?.evaluate()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    // MARK: - Passes

    /// One pass of the rule over both stores: removes what is due, and publishes
    /// who is hidden. Publishes only when the answer changed.
    func evaluate() {
        let outcome = ContactMaxAge.evaluate(
            now: now(),
            maxAgeMinutes: maxAgeMinutes(),
            selfUID: stores.selfUID(),
            events: stores.events(),
            participants: stores.participants()
        )
        if !outcome.removed.isEmpty {
            #if DEBUG
            print("ContactMaxAge: removing \(outcome.removed.sorted().joined(separator: ", ")) from the contact store")
            #endif
            stores.remove(outcome.removed)
        }
        if hidden != outcome.hidden {
            #if DEBUG
            let newlyHidden = Set(outcome.hidden.keys).subtracting(hidden.keys).sorted()
            let newlyShown = Set(hidden.keys).subtracting(outcome.hidden.keys).sorted()
            print("ContactMaxAge: now hidden \(newlyHidden), no longer hidden \(newlyShown); \(outcome.hidden.count) hidden in all")
            #endif
            hidden = outcome.hidden
        }
    }

    /// A position report just arrived from `uid` and was stored with the receive
    /// time of now, so the contact is fresh: back on the map and out of the "not
    /// heard from" section at once.
    func reportReceived(uid: String) {
        guard hidden[uid] != nil else { return }
        #if DEBUG
        print("ContactMaxAge: report from \(uid), back on the map")
        #endif
        hidden[uid] = nil
    }

    /// The operator changed the setting: apply it now instead of at the next pass.
    func settingChanged() {
        evaluate()
    }
}
