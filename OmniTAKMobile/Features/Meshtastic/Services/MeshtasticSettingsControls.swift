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
//   - The interval is the radio's own value until the operator moves the slider.
//     The slider covers a range (30 s to an hour) that a radio's value can lie
//     outside of (a TAK radio has a day), and a value is only the operator's
//     choice if they moved it: what the slider shows for a value it cannot
//     reach, or after snapping a value to its steps, is never written.
//

import Foundation

struct MeshtasticSettingsControls: Equatable {

    var role: MeshtasticAdminCodec.DeviceRole?
    var rebroadcast: MeshtasticAdminCodec.RebroadcastMode?

    /// The interval the operator chose with the slider. Nil until they move it.
    private(set) var intervalChoice: Double?

    /// The range and step of the slider.
    static let sliderRange: ClosedRange<Double> = 30...3600
    static let sliderStep: Double = 30
    /// Where the slider rests before the radio has said what its interval is.
    static let sliderRestingValue: Double = 900

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
            intervalChoice = nil
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

    // MARK: - The interval

    /// The value the slider shows: the operator's choice, or else the radio's
    /// interval held within the slider's range.
    func sliderValue(radio: MeshtasticRadioSettings) -> Double {
        if let intervalChoice { return intervalChoice }
        guard let seconds = radio.positionBroadcastSeconds else { return Self.sliderRestingValue }
        return min(max(Double(seconds), Self.sliderRange.lowerBound), Self.sliderRange.upperBound)
    }

    /// The step of the slider. Its usual one, unless the value it shows is not
    /// on it: a slider that has to snap a value to its steps reports the snapped
    /// one as if it had been moved.
    func sliderStep(radio: MeshtasticRadioSettings) -> Double {
        let value = sliderValue(radio: radio)
        return value.truncatingRemainder(dividingBy: Self.sliderStep) == 0 ? Self.sliderStep : 1
    }

    /// The slider reports a value. Only one that differs from what it shows is
    /// the operator moving it.
    mutating func sliderMoved(to value: Double, radio: MeshtasticRadioSettings) {
        guard value.isFinite, value != sliderValue(radio: radio) else { return }
        intervalChoice = min(max(value, Self.sliderRange.lowerBound), Self.sliderRange.upperBound)
    }

    /// The seconds Apply Interval writes, or nil when the operator has not moved
    /// the slider: nothing is written then, whatever the slider shows.
    func intervalToWrite() -> UInt32? {
        guard let intervalChoice, intervalChoice.isFinite, intervalChoice > 0 else { return nil }
        return UInt32(min(intervalChoice, Double(UInt32.max)))
    }

    // MARK: - Labels

    /// The interval as the screen shows it: the operator's choice, or the radio's
    /// own value. "Not loaded" until the position config is known; 0 is how the
    /// radio says "use my default".
    func intervalLabel(radio: MeshtasticRadioSettings) -> String {
        guard radio.hasPositionConfig, let seconds = radio.positionBroadcastSeconds else { return "Not loaded" }
        if let choice = intervalChoice { return "\(Int(choice))s" }
        if seconds == 0 { return "radio default" }
        return "\(seconds)s"
    }

    /// Set when the radio's interval is outside what the slider can show, so
    /// the screen can say that it stays as it is unless the slider is moved.
    func intervalOutsideSlider(radio: MeshtasticRadioSettings) -> Bool {
        guard intervalChoice == nil, let seconds = radio.positionBroadcastSeconds, seconds != 0 else { return false }
        return !Self.sliderRange.contains(Double(seconds))
    }
}
