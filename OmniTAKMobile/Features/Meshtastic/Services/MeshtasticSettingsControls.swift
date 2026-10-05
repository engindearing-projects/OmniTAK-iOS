//
//  MeshtasticSettingsControls.swift
//  OmniTAK Mobile
//
//  What the Device and Position controls of the Mesh Settings screen hold, and
//  what Apply writes from them (#148). It is a plain value so that the rules can
//  be tested without a view:
//
//   - The controls start at what the radio reports. A field the radio leaves out
//     of its message is at its default (no role is CLIENT, no rebroadcast mode is
//     ALL), so a radio at factory settings starts at CLIENT and ALL. Before the
//     radio's config has arrived they hold nothing. They never start at a value
//     of the app's own choosing: a fixed default is a value Apply would write to
//     a radio the operator never looked at.
//   - A role or rebroadcast mode the app has no name for stays empty in the
//     control (the screen shows its number) and is not written unless the
//     operator picks another.
//   - Apply writes only what the operator changed from the radio's value.
//   - Showing the screen again does not undo the operator's choices. SwiftUI
//     shows a form again when a pushed picker pops back, and the controls are
//     only started over when the radio's own values have changed, which they do
//     with a new download.
//

import Foundation

struct MeshtasticSettingsControls: Equatable {

    var role: MeshtasticAdminCodec.DeviceRole?
    var rebroadcast: MeshtasticAdminCodec.RebroadcastMode?
    var intervalSeconds: Double = 900

    /// The radio values the device controls were last started from.
    private var seededDevice: DeviceValues?
    /// The radio value the interval control was last started from.
    private var seededInterval: UInt32?

    private struct DeviceValues: Equatable {
        let role: UInt64
        let rebroadcast: UInt64
    }

    init() {}

    init(radio: MeshtasticRadioSettings) {
        seed(from: radio)
    }

    // MARK: - Starting at the radio's values

    /// Start the controls at the radio's values, for the controls whose radio
    /// value is not the one they were last started from. Calling it again for
    /// the same values changes nothing, so the operator's choices survive the
    /// form being shown again.
    mutating func seed(from radio: MeshtasticRadioSettings) {
        var device: DeviceValues?
        if let role = radio.deviceRole, let rebroadcast = radio.rebroadcastMode {
            device = DeviceValues(role: role, rebroadcast: rebroadcast)
        }
        if device != seededDevice {
            self.role = radio.namedDeviceRole
            self.rebroadcast = radio.namedRebroadcastMode
            seededDevice = device
        }

        let interval = radio.positionBroadcastSeconds
        if interval != seededInterval {
            if let seconds = interval { intervalSeconds = Double(seconds) }
            seededInterval = interval
        }
    }

    // MARK: - What Apply writes

    /// The role and rebroadcast mode Apply Device Config writes: a control that
    /// differs from the radio's value, and nothing for one that does not or is
    /// empty. An empty control (a value the app has no name for, or not loaded)
    /// leaves that setting as the radio has it.
    func deviceEdits(against radio: MeshtasticRadioSettings) -> (
        role: MeshtasticAdminCodec.DeviceRole?,
        rebroadcast: MeshtasticAdminCodec.RebroadcastMode?
    ) {
        (
            role.flatMap { $0 != radio.namedDeviceRole ? $0 : nil },
            rebroadcast.flatMap { $0 != radio.namedRebroadcastMode ? $0 : nil }
        )
    }

    // MARK: - Labels

    /// The interval as the screen shows it. "Not loaded" until the position
    /// config is known; 0 is how the radio says "use my default".
    func intervalLabel(radio: MeshtasticRadioSettings) -> String {
        guard radio.hasPositionConfig else { return "Not loaded" }
        return intervalSeconds == 0 ? "radio default" : "\(Int(intervalSeconds))s"
    }

    /// The seconds Apply Interval writes. The slider holds a whole number of
    /// seconds from the radio or from its own steps, never negative.
    var intervalToWrite: UInt32 {
        guard intervalSeconds.isFinite, intervalSeconds > 0 else { return 0 }
        return UInt32(min(intervalSeconds, Double(UInt32.max)))
    }
}
