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
    static let channelUUID = UUID(uuidString: "6A1C4E2B-9D3F-4B8A-A5E7-0C2D7F1B3E91")!

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
        mgr.requestBeginTransmitting(channelUUID: Self.channelUUID)
    }

    func stopTransmitting() {
        guard let mgr = manager, isJoined, isTransmitting else { return }
        mgr.stopTransmitting(channelUUID: Self.channelUUID)
    }

    /// Incoming audio: name the talker (the system UI shows it and activates
    /// the audio session). nil when nobody is talking any more.
    func setActiveRemoteParticipant(_ name: String?) {
        guard let mgr = manager, isJoined, name != participantName else { return }
        participantName = name
        let p = name.map { PTParticipant(name: $0, image: nil) }
        mgr.setActiveRemoteParticipant(p, channelUUID: Self.channelUUID) { err in
            if let err = err { print("[NativePTT] set participant \(name ?? "nil") failed: \(err)") }
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
            self.participantName = nil
            print("[NativePTT] left channel (reason \(reason.rawValue))")
            self.onLeftChannel?(reason)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        DispatchQueue.main.async {
            self.isTransmitting = true
            print("[NativePTT] transmit began (source \(source.rawValue))")
            self.onTransmitBegan?(source)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        DispatchQueue.main.async {
            self.isTransmitting = false
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
        DispatchQueue.main.async {
            print("[NativePTT] audio session ACTIVATED by the system")
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
