//
//  NativePTTManager.swift
//  OmniTAKMobile
//
//  X Voice on Apple's PushToTalk framework. The system owns:
//   - the PTT channel shown in the lock screen / Dynamic Island / Control
//     Center, with its own Talk button,
//   - the audio session: it ACTIVATES it when a transmission starts or a
//     remote participant is set, and deactivates it afterwards. The app never
//     calls AVAudioSession.setActive itself — it starts its audio engine in
//     channelManager(_:didActivate:) and stops it in didDeactivate,
//   - background transmit: a transmission can start in the background from a
//     Bluetooth accessory event (CoreBluetooth, `bluetooth-central`) or a
//     hands-free button; reception is signalled with
//     setActiveRemoteParticipant.
//
//  One system channel represents X Voice (both slots); its descriptor shows
//  the slot channel names. The Mumble connection, slot rules, TX state
//  machine and BLE buttons are unchanged — this class only bridges them to
//  the system.
//
//  Requires the com.apple.developer.push-to-talk entitlement and the
//  `push-to-talk` UIBackgroundModes entry. The channel manager must be created
//  at app launch (the plugin activates at launch); a channel can only be
//  joined while the app is in the foreground.
//

import Foundation
import PushToTalk
import AVFoundation
import UIKit

final class NativePTTManager: NSObject {
    /// Stable channel id so the system can restore the channel after a relaunch.
    /// 6A1C4E2B-9D3F-4B8A-A5E7-0C2D7F1B3E91, built from its bytes (can't fail).
    static let channelUUID = UUID(uuid: (0x6A, 0x1C, 0x4E, 0x2B, 0x9D, 0x3F, 0x4B, 0x8A,
                                         0xA5, 0xE7, 0x0C, 0x2D, 0x7F, 0x1B, 0x3E, 0x91))

    // Callbacks to the voice controller (always on main).
    var onTransmitBegan: ((PTChannelTransmitRequestSource) -> Void)?
    var onTransmitEnded: ((PTChannelTransmitRequestSource) -> Void)?
    var onTransmitFailed: ((Error) -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    var onLeftChannel: ((PTChannelLeaveReason) -> Void)?
    var onJoinedChannel: (() -> Void)?

    private var manager: PTChannelManager?
    private(set) var isJoined = false
    private(set) var isTransmitting = false
    /// Our requestBeginTransmitting is out and the system hasn't answered yet
    /// (didBegin / failedToBegin). It answers 10-200 ms later.
    private var beginRequestedAt: Date?
    /// Released while the begin request was still in flight: stop the
    /// transmission the moment the system reports it began. Without this a
    /// quick tap left the system transmitting with nobody behind it, and the
    /// next press failed until the 4 s acquire timeout.
    private var stopWhenBegun = false
    /// A begin request older than this is treated as lost (never answered).
    private static let beginRequestTimeout: TimeInterval = 3
    private var currentDescriptorName = "X Voice"
    private var participantName: String?
    private var pendingJoin = false
    private var foregroundObserver: NSObjectProtocol?

    // MARK: - Setup

    /// Create the channel manager. Call at launch (plugin activation).
    func setUp() {
        PTChannelManager.channelManager(delegate: self, restorationDelegate: self) { [weak self] mgr, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    print("[NativePTT] channel manager unavailable: \(error)")
                    return
                }
                self.manager = mgr
                print("[NativePTT] channel manager ready (active channel: \(mgr?.activeChannelUUID?.uuidString ?? "none"))")
                if mgr?.activeChannelUUID == Self.channelUUID { self.isJoined = true; self.configureChannel() }
                if self.pendingJoin { self.join(name: self.currentDescriptorName) }
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.pendingJoin else { return }
            self.join(name: self.currentDescriptorName)
        }
    }

    deinit {
        if let o = foregroundObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Channel

    /// Join (or keep) the X Voice system channel. Only possible in the
    /// foreground; otherwise it is retried when the app becomes active.
    func join(name: String) {
        currentDescriptorName = name
        guard let mgr = manager else { pendingJoin = true; return }
        if isJoined { updateDescriptor(name: name); return }
        guard UIApplication.shared.applicationState == .active else {
            pendingJoin = true
            print("[NativePTT] join deferred until the app is in the foreground")
            return
        }
        pendingJoin = false
        print("[NativePTT] joining channel '\(name)'")
        mgr.requestJoinChannel(channelUUID: Self.channelUUID, descriptor: descriptor(name))
    }

    func leave() {
        pendingJoin = false
        guard let mgr = manager, isJoined else { return }
        mgr.leaveChannel(channelUUID: Self.channelUUID)
    }

    func updateDescriptor(name: String) {
        currentDescriptorName = name
        guard let mgr = manager, isJoined else { return }
        mgr.setChannelDescriptor(descriptor(name), channelUUID: Self.channelUUID) { err in
            if let err = err { print("[NativePTT] descriptor update failed: \(err)") }
        }
    }

    private func descriptor(_ name: String) -> PTChannelDescriptor {
        PTChannelDescriptor(name: name, image: UIImage(named: "XVoiceSpeakerMic"))
    }

    private func configureChannel() {
        guard let mgr = manager else { return }
        // Full duplex: incoming audio keeps playing while transmitting, and an
        // active remote participant does not block the Talk button.
        mgr.setTransmissionMode(.fullDuplex, channelUUID: Self.channelUUID) { err in
            if let err = err { print("[NativePTT] full-duplex mode failed: \(err)") }
        }
    }

    /// Mirror the Mumble connection in the system UI.
    func setServiceStatus(_ status: PTServiceStatus) {
        guard let mgr = manager, isJoined else { return }
        mgr.setServiceStatus(status, channelUUID: Self.channelUUID) { _ in }
    }

    // MARK: - Transmit / receive

    func beginTransmitting() {
        guard let mgr = manager, isJoined else {
            onTransmitFailed?(NSError(domain: "NativePTT", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "X Voice channel not joined"]))
            return
        }
        guard !isTransmitting else { return }
        if let at = beginRequestedAt, Date().timeIntervalSince(at) < Self.beginRequestTimeout {
            // Pressed again before the system answered the previous request:
            // that request carries this press — just cancel the pending stop.
            stopWhenBegun = false
            return
        }
        beginRequestedAt = Date()
        stopWhenBegun = false
        mgr.requestBeginTransmitting(channelUUID: Self.channelUUID)
    }

    func stopTransmitting() {
        guard let mgr = manager, isJoined else { return }
        if isTransmitting {
            mgr.stopTransmitting(channelUUID: Self.channelUUID)
        } else if beginRequestedAt != nil {
            stopWhenBegun = true
            print("[NativePTT] released before the system began transmitting — will stop it when it does")
        }
    }

    /// Incoming audio: name the talker (the system UI shows it and activates
    /// the audio session). nil when nobody is talking any more.
    func setActiveRemoteParticipant(_ name: String?, isRetry: Bool = false) {
        guard let mgr = manager, isJoined, name != participantName else { return }
        // Recorded now so rapid repeats don't re-send, but rolled back if the
        // system refuses — otherwise a failed set blocked every retry with the
        // same name, and a failed clear left the system holding the session
        // while we believed nobody was talking.
        let previous = participantName
        participantName = name
        let p = name.map { PTParticipant(name: $0, image: nil) }
        mgr.setActiveRemoteParticipant(p, channelUUID: Self.channelUUID) { [weak self] err in
            guard let err = err else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                print("[NativePTT] set participant \(name ?? "nil") failed: \(err)")
                // Only undo our own change, not a newer one made meanwhile.
                guard self.participantName == name else { return }
                self.participantName = previous
                if name == nil, !isRetry {
                    // A clear must not be lost: try once more shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self = self, self.participantName == previous else { return }
                        self.setActiveRemoteParticipant(nil, isRetry: true)
                    }
                }
            }
        }
    }

    var hasRemoteParticipant: Bool { participantName != nil }
}

// MARK: - PTChannelManagerDelegate

extension NativePTTManager: PTChannelManagerDelegate {
    func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason) {
        DispatchQueue.main.async {
            self.isJoined = true
            print("[NativePTT] joined channel (reason \(reason.rawValue))")
            self.configureChannel()
            self.onJoinedChannel?()
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason) {
        DispatchQueue.main.async {
            self.isJoined = false
            self.isTransmitting = false
            self.beginRequestedAt = nil
            self.stopWhenBegun = false
            self.participantName = nil
            print("[NativePTT] left channel (reason \(reason.rawValue))")
            self.onLeftChannel?(reason)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        let t = VoiceAudioEngine.ts()
        DispatchQueue.main.async {
            self.isTransmitting = true
            print("[NativePTT] \(t) transmit began (source \(source.rawValue))")
            if source == .developerRequest, self.beginRequestedAt != nil {
                self.beginRequestedAt = nil
                if self.stopWhenBegun {
                    // The operator already let go: end it now, don't start a burst.
                    self.stopWhenBegun = false
                    print("[NativePTT] \(t) stopping a transmission released before it began")
                    self.manager?.stopTransmitting(channelUUID: Self.channelUUID)
                    return
                }
            }
            self.onTransmitBegan?(source)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        DispatchQueue.main.async {
            self.isTransmitting = false
            self.beginRequestedAt = nil
            self.stopWhenBegun = false
            print("[NativePTT] transmit ended (source \(source.rawValue))")
            self.onTransmitEnded?(source)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        // X Voice receives over its live Mumble connection, not APNs PTT
        // pushes; the token is not sent anywhere.
        print("[NativePTT] received ephemeral push token (unused, \(pushToken.count) bytes)")
    }

    func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]) -> PTPushResult {
        // Not expected (no PTT push server). Show a generic participant rather
        // than leaving the channel.
        let name = (pushPayload["activeSpeaker"] as? String) ?? "X Voice"
        return .activeRemoteParticipant(PTParticipant(name: name, image: nil))
    }

    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        let t = VoiceAudioEngine.ts()
        DispatchQueue.main.async {
            print("[NativePTT] \(t) audio session ACTIVATED by the system")
            self.onAudioActivated?()
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        DispatchQueue.main.async {
            print("[NativePTT] audio session deactivated by the system")
            self.onAudioDeactivated?()
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: Error) {
        DispatchQueue.main.async {
            print("[NativePTT] failed to join channel: \(error)")
            self.pendingJoin = true   // retry on next foreground
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToBeginTransmittingInChannel channelUUID: UUID, error: Error) {
        DispatchQueue.main.async {
            self.isTransmitting = false
            self.beginRequestedAt = nil
            self.stopWhenBegun = false
            print("[NativePTT] failed to begin transmitting: \(error)")
            self.onTransmitFailed?(error)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToStopTransmittingInChannel channelUUID: UUID, error: Error) {
        print("[NativePTT] failed to stop transmitting: \(error)")
    }
}

// MARK: - PTChannelRestorationDelegate

extension NativePTTManager: PTChannelRestorationDelegate {
    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        descriptor(currentDescriptorName)
    }
}
