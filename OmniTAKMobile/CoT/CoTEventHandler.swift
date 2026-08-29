//
//  CoTEventHandler.swift
//  OmniTAKMobile
//
//  Route parsed CoT events to appropriate handlers and publish updates via Combine
//

import Foundation
import Combine
import CoreLocation
import UserNotifications

// MARK: - CoT Event Handler

class CoTEventHandler: ObservableObject {
    static let shared = CoTEventHandler()

    // MARK: - Published Properties

    @Published var latestPositionUpdate: CoTEvent?
    @Published var latestChatMessage: ChatMessage?
    @Published var activeEmergencies: [EmergencyAlert] = []
    @Published var receivedEventCount: Int = 0
    @Published var lastEventTime: Date?

    // MARK: - Event Publishers

    let positionUpdatePublisher = PassthroughSubject<CoTEvent, Never>()
    let chatMessagePublisher = PassthroughSubject<ChatMessage, Never>()
    let emergencyAlertPublisher = PassthroughSubject<EmergencyAlert, Never>()
    let waypointPublisher = PassthroughSubject<CoTEvent, Never>()
    let unknownEventPublisher = PassthroughSubject<String, Never>()

    // MARK: - Notification Names

    static let positionUpdateNotification = Notification.Name("CoTPositionUpdate")
    static let chatMessageNotification = Notification.Name("CoTChatMessage")
    static let emergencyAlertNotification = Notification.Name("CoTEmergencyAlert")
    static let waypointNotification = Notification.Name("CoTWaypoint")

    // MARK: - Dependencies

    private weak var takService: TAKService?
    private weak var chatManager: ChatManager?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Configuration

    var enableNotifications: Bool = true
    var enableEmergencyAlerts: Bool = true

    /// How long to keep events before considering them stale (default: 1 hour)
    var staleEventThreshold: TimeInterval = 3600

    private var staleCleanupTimer: Timer?

    private init() {
        requestNotificationPermissions()
        startStaleEventCleanup()
    }

    /// Start periodic cleanup of stale events
    private func startStaleEventCleanup() {
        // Run cleanup every 5 minutes
        staleCleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.cleanupStaleEvents()
        }
    }

    /// Remove events older than staleEventThreshold
    private func cleanupStaleEvents() {
        guard let service = takService else { return }

        let cutoffDate = Date().addingTimeInterval(-staleEventThreshold)
        let originalCount = service.cotEvents.count

        service.cotEvents.removeAll { event in
            // Exempt locally-dropped / shared tactical point markers
            // (uid "marker-…") from the stale sweep. A marker a teammate shared
            // (or one we dropped) is a deliberate, persistent annotation — it
            // must not ghost-expire just because no fresh position update for it
            // arrives within the stale window the way a live EUD's PPLI does.
            // Markers are removed explicitly via removeEvent(uid:) instead.
            guard !event.uid.isDroppedPointMarkerUID else { return false }
            return event.time < cutoffDate
        }

        let removedCount = originalCount - service.cotEvents.count
        if removedCount > 0 {
            #if DEBUG
            print("🧹 CoTEventHandler: Cleaned up \(removedCount) stale events (older than \(Int(staleEventThreshold/60)) minutes)")
            #endif
        }
    }

    /// Remove a single tracked contact by UID (e.g. a stale Remote ID / gyb
    /// drone) so the map drops its marker immediately rather than waiting for
    /// the staleEventThreshold backstop.
    func removeEvent(uid: String) {
        guard let service = takService else { return }
        service.cotEvents.removeAll { $0.uid == uid }
    }

    // MARK: - Setup

    func configure(takService: TAKService, chatManager: ChatManager) {
        self.takService = takService
        self.chatManager = chatManager

        print("CoTEventHandler: Configured with TAKService and ChatManager")
    }

    // MARK: - Event Routing

    /// Handle a parsed CoT event and route to appropriate handlers.
    ///
    /// `source` (#180) tags the transport the event arrived on so the detail
    /// sheet can show "TAK: <server>" / "Mesh: Meshtastic" etc. When nil and the
    /// event came off a TAK server (serverId set), the server path resolves it to
    /// `.takServer(<name>)`; mesh ingest points pass `.mesh(...)` explicitly.
    func handle(event: CoTEventType, serverId: UUID? = nil, source: CoTSource? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.receivedEventCount += 1
            self.lastEventTime = Date()

            switch event {
            case .positionUpdate(let cotEvent):
                self.handlePositionUpdate(cotEvent, serverId: serverId, source: source)
                self.offerToRelay(cotEvent, serverId: serverId, source: source)

            case .chatMessage(let message):
                self.handleChatMessage(message, serverId: serverId)

            case .emergencyAlert(let alert):
                self.handleEmergencyAlert(alert)

            case .waypoint(let cotEvent):
                self.handleWaypoint(cotEvent)
                self.offerToRelay(cotEvent, serverId: serverId, source: source)

            case .unknown(let typeStr):
                self.handleUnknownEvent(typeStr)
            }
        }
    }

    /// #180/#113 — which transport carried this event. An explicit `source` from
    /// the ingest point wins (it knows the link it read the bytes off), then any
    /// tag already on the event, and only then the fallback: it came off a TAK
    /// server connection.
    ///
    /// That fallback is why mesh ingest points MUST tag. Pure so #113's loop
    /// guard can be tested against the exact rule the ingest path applies.
    static func resolveSource(explicit: CoTSource?, existing: CoTSource?,
                              serverName: String?) -> CoTSource {
        explicit ?? existing ?? .takServer(serverName)
    }

    /// #113 — offer the event to the mesh↔server gateway. Reading the two link
    /// booleans has to happen on the main actor (the mesh managers live there);
    /// everything the relay then does — the routing decision, the throttle, the
    /// XML rebuild, the send — runs on the relay's own queue.
    private func offerToRelay(_ event: CoTEvent, serverId: UUID?, source: CoTSource?) {
        // Gateway mode is off for almost every install, and this runs per inbound
        // CoT on a busy server — so establish that before paying for an actor hop.
        guard MeshServerRelay.isEnabled() else { return }

        let resolved = Self.resolveSource(explicit: source, existing: event.source,
                                          serverName: takService?.serverName(for: serverId))
        let serverConnected = takService?.isConnected ?? false
        Task { @MainActor in
            MeshServerRelay.shared.onInbound(
                event,
                source: resolved,
                serverConnected: serverConnected,
                meshConnected: MeshServerRelay.isAnyMeshConnected
            )
        }
    }

    // MARK: - Position Update Handler

    private func handlePositionUpdate(_ rawEvent: CoTEvent, serverId: UUID? = nil, source: CoTSource? = nil) {
        // #178 / #180 — stamp the wall-clock receive time and the transport the
        // point arrived on, so the detail sheet + staleness overlay have a
        // truthful "when did I last hear this, and over what link" signal. The
        // server path resolves the source from serverId → server name when the
        // caller didn't pass one; an explicit `source` (mesh ingest) wins.
        var event = rawEvent
        event.receivedAt = Date()
        event.source = Self.resolveSource(explicit: source, existing: event.source,
                                          serverName: takService?.serverName(for: serverId))

        print("CoTEventHandler: Position update from \(event.detail.callsign) at (\(event.point.lat), \(event.point.lon))")

        latestPositionUpdate = event

        // CRITICAL: Check if takService reference is valid
        #if DEBUG
        if takService == nil {
            print("❌ CoTEventHandler: takService is NIL! Events cannot be added to cotEvents array!")
            print("   This means teammates will NOT appear on the map!")
        } else {
            print("✅ CoTEventHandler: takService is valid, adding event to cotEvents")
        }
        #endif

        // Update or add to cotEvents array (deduplicate by UID).
        // cotEvents is the single marker store — the map renders it directly.
        if let service = takService {
            if let existingIndex = service.cotEvents.firstIndex(where: { $0.uid == event.uid }) {
                // Update existing event with new position/data
                service.cotEvents[existingIndex] = event
                #if DEBUG
                print("   🔄 Updated existing event for UID: \(event.uid)")
                #endif
            } else {
                // Add new event
                service.cotEvents.append(event)
                #if DEBUG
                print("   ➕ Added new event for UID: \(event.uid)")
                #endif
            }

            #if DEBUG
            print("   📊 cotEvents now contains \(service.cotEvents.count) unique events")
            #endif
        }

        // Feed ChatManager.participants from incoming PPLI/CoT so the
        // "KNOWN CONTACTS" section and New-Chat sheet are populated as soon as
        // other EUDs appear on the map.  Skip the user's own echoed PPLI so
        // they don't appear as a contact they can message themselves.
        let selfUID = PositionBroadcastService.shared.userUID
        guard event.uid != selfUID else {
            #if DEBUG
            print("   ℹ️ Skipping self-PPLI for participant feed (uid: \(event.uid))")
            #endif
            // Still publish / callback for map rendering — just skip participant write.
            positionUpdatePublisher.send(event)
            NotificationCenter.default.post(
                name: CoTEventHandler.positionUpdateNotification,
                object: self,
                userInfo: ["event": event]
            )
            // Plugin SDK — fire registered CoT handlers AFTER the core store
            // ingested the event (runs on main, same as the rest of handle()).
            _ = AppPluginHost.shared.dispatchCoT(event)
            takService?.onCoTReceived?(event)
            return
        }

        // Update participant info for chat, tagged with the source server so
        // the contact list + DM routing are server-aware (multi-server).
        //
        // Skip detected drones (RID-{uasId}) and locally-dropped point markers
        // (marker-{uuid}) from the participant/chat-contact feed.
        //
        // • RID- UIDs: drone detections from RemoteIdAppBridge / gyb sensor.
        //   They appear on the map and federate to servers but cannot receive DMs.
        //
        // • marker- UIDs: user-dropped tactical point markers (PointMarker.uid).
        //   They share the same CoT position-update pipeline when broadcast, but
        //   are static map annotations, not chat-capable EUDs.  Feeding them into
        //   ChatManager.participants causes them to appear in the Chat contact list
        //   and the New-Chat sheet — field report: Patrick Coyle 2026-06-12
        //   (Android #118 parity).
        if !event.uid.hasPrefix("RID-") && !event.uid.isDroppedPointMarkerUID {
            // Map the parsed event straight onto a ChatParticipant — the
            // previous implementation serialized the event back to XML just
            // to re-parse it with ChatXMLParser (the two parsers shared no
            // model). The presence XML never carried an endpoint, so a
            // direct mapping is equivalent.
            let participant = ChatParticipant(
                id: event.uid,
                callsign: event.detail.callsign,
                lastSeen: event.time,
                isOnline: true,
                serverId: serverId
            )
            chatManager?.updateParticipant(participant)
            chatManager?.updateParticipantLastSeen(id: participant.id)
        }

        // Publish to Combine subscribers
        positionUpdatePublisher.send(event)

        // Post notification for map updates
        NotificationCenter.default.post(
            name: CoTEventHandler.positionUpdateNotification,
            object: self,
            userInfo: ["event": event]
        )

        // Plugin SDK — fire registered CoT handlers AFTER the core store
        // ingested the event (and after the core publishers). Handlers run on
        // main; a handler returning true marks the event consumed.
        _ = AppPluginHost.shared.dispatchCoT(event)

        // Trigger callback
        takService?.onCoTReceived?(event)
    }

    // MARK: - Chat Message Handler

    private func handleChatMessage(_ message: ChatMessage, serverId: UUID? = nil) {
        print("CoTEventHandler: Chat message from \(message.senderCallsign): \(message.messageText)")

        latestChatMessage = message

        // Forward to ChatManager with the source server for multi-server attribution
        chatManager?.receiveMessage(message, serverId: serverId)

        // Update sender's last seen
        chatManager?.updateParticipantLastSeen(id: message.senderId)

        // Publish to Combine subscribers
        chatMessagePublisher.send(message)

        // Post notification
        NotificationCenter.default.post(
            name: CoTEventHandler.chatMessageNotification,
            object: self,
            userInfo: ["message": message]
        )

        // Trigger callback
        takService?.onChatMessageReceived?(message)

        // Show local notification if app is in background
        if enableNotifications {
            showChatNotification(message)
        }
    }

    // MARK: - Emergency Alert Handler

    private func handleEmergencyAlert(_ alert: EmergencyAlert) {
        print("CoTEventHandler: Emergency alert from \(alert.callsign) - \(alert.alertType.rawValue)")

        if alert.cancel {
            // Remove cancelled alert
            activeEmergencies.removeAll { $0.uid == alert.uid }
            print("CoTEventHandler: Emergency cancelled for \(alert.callsign)")
        } else {
            // Add or update active emergency
            if let index = activeEmergencies.firstIndex(where: { $0.uid == alert.uid }) {
                activeEmergencies[index] = alert
            } else {
                activeEmergencies.append(alert)
            }
        }

        // Publish to Combine subscribers
        emergencyAlertPublisher.send(alert)

        // Post notification
        NotificationCenter.default.post(
            name: CoTEventHandler.emergencyAlertNotification,
            object: self,
            userInfo: ["alert": alert]
        )

        // Show critical notification for emergencies
        if enableEmergencyAlerts && !alert.cancel {
            showEmergencyNotification(alert)
        }
    }

    // MARK: - Waypoint Handler

    private func handleWaypoint(_ event: CoTEvent) {
        print("CoTEventHandler: Waypoint received - \(event.detail.callsign)")

        // Import waypoint into WaypointManager
        _ = WaypointManager.shared.importFromCoT(
            uid: event.uid,
            type: event.type,
            coordinate: CLLocationCoordinate2D(latitude: event.point.lat, longitude: event.point.lon),
            callsign: event.detail.callsign,
            altitude: event.point.hae,
            remarks: event.detail.remarks
        )

        // Publish to Combine subscribers
        waypointPublisher.send(event)

        // Post notification
        NotificationCenter.default.post(
            name: CoTEventHandler.waypointNotification,
            object: self,
            userInfo: ["event": event]
        )
    }

    // MARK: - Unknown Event Handler

    private func handleUnknownEvent(_ typeStr: String) {
        print("CoTEventHandler: Unknown event type: \(typeStr)")
        unknownEventPublisher.send(typeStr)
    }

    // MARK: - Notifications

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("CoTEventHandler: Notification permissions granted")
            } else if let error = error {
                print("CoTEventHandler: Notification permission error: \(error)")
            }
        }
    }

    private func showChatNotification(_ message: ChatMessage) {
        let content = UNMutableNotificationContent()
        content.title = "Message from \(message.senderCallsign)"
        content.body = message.messageText
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: message.id,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("CoTEventHandler: Failed to show chat notification: \(error)")
            }
        }
    }

    private func showEmergencyNotification(_ alert: EmergencyAlert) {
        let content = UNMutableNotificationContent()
        content.title = "EMERGENCY ALERT"
        content.body = "\(alert.callsign): \(alert.alertType.rawValue)"
        if let message = alert.message {
            content.body += " - \(message)"
        }
        content.sound = .defaultCritical
        content.interruptionLevel = .critical

        let request = UNNotificationRequest(
            identifier: alert.id,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("CoTEventHandler: Failed to show emergency notification: \(error)")
            }
        }
    }

    // MARK: - Statistics

    func getStatistics() -> CoTEventStatistics {
        return CoTEventStatistics(
            totalEventsReceived: receivedEventCount,
            activeEmergencyCount: activeEmergencies.count,
            lastEventTime: lastEventTime
        )
    }

    // MARK: - Cleanup

    func clearEmergencies() {
        activeEmergencies.removeAll()
    }

    func resetStatistics() {
        receivedEventCount = 0
        lastEventTime = nil
    }
}

// MARK: - Statistics Model

struct CoTEventStatistics {
    let totalEventsReceived: Int
    let activeEmergencyCount: Int
    let lastEventTime: Date?
}
