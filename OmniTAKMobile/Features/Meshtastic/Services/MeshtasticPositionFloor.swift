//
//  MeshtasticPositionFloor.swift
//  OmniTAK Mobile
//
//  The firmware's floor under the position interval, and what the app needs to
//  see it coming (OmniTAK-iOS #153). Android has the same rule in
//  PositionFloor.kt (OmniTAK-Android #257, PR #258).
//
//  Firmware 2.7.26 (tag v2.7.26.54e0d8d) does this when it loads its config at
//  start, in `NodeDB::NodeDB()` (src/mesh/NodeDB.cpp lines 349 to 365, "Enforce
//  position broadcast minimums if we would send positions over a default
//  channel"):
//
//   - the position channel is the first channel, in index order, whose module
//     settings have a `position_precision` other than 0 (a channel's role is not
//     looked at);
//   - when that channel is the default channel (`Channels::isDefaultChannel`,
//     src/mesh/Channels.cpp lines 376 to 388: a key of exactly one byte with the
//     value 1, and a name equal to the display name of the modem preset, an
//     empty name standing for that name, `Channels::getName` lines 358 to 374),
//     `position_broadcast_secs` is raised to at least one hour, or twelve hours
//     for the roles ROUTER and ROUTER_LATE (`min_default_broadcast_interval_secs`
//     and `IF_ROUTER`, src/mesh/Default.h lines 21 and 47 to 51). A value of 0 is
//     left alone (`Default::getConfiguredOrMinimumValue`, src/mesh/Default.cpp
//     lines 63 to 70).
//
//  That runs at start and the raised value is saved, so a write of a shorter
//  interval is held by the radio until it restarts, and the radio reports the
//  floor after it. The read right after the write still shows the value that was
//  sent, which is why the report of a config write is checked again when the
//  radio is back (MeshtasticConfigReport). The preset display names are those of
//  `DisplayFormatters::getModemPresetDisplayName` (src/DisplayFormatters.cpp,
//  long names). The source at that tag was read, and a simulated radio running
//  that firmware was measured. Nothing here has been checked against another
//  firmware version.
//
//  Two uses, both on the Mesh Settings screen:
//   - `intervalHint`: before a push, as a caption under the interval control;
//   - `intervalReason`: after the radio is back, as the last sentence of the
//     report of the write when the radio reports the floor for the interval
//     that was sent.
//
//  What the rule is decided from is what the radio reported and nothing else:
//  its channels, its LoRa config and its device role, read from the raw
//  messages MeshtasticRadioSettings keeps. A part that is not loaded is nil, and
//  nothing is decided from a part that is missing. The app's own list of saved
//  channels is never looked at: it is not what the radio holds.
//
//  The Mesh Settings screen pushes the interval on its own (Apply Interval
//  writes the interval and nothing else), and has no control for the primary
//  channel's name or the LoRa preset next to it. The radio therefore keeps the
//  role, the channels and the preset it reports when the interval is pushed, and
//  the rule has no pending edits to take into account. (Android pushes the role,
//  a rename of the primary channel and a preset together with the interval and
//  has to.)
//

import Foundation

// MARK: - The floor

enum MeshtasticPositionFloor {

    /// The smallest position interval the firmware leaves on a default channel:
    /// one hour.
    static let defaultFloorSeconds: UInt32 = 60 * 60

    /// The same for a router (ROUTER, ROUTER_LATE): twelve hours.
    static let routerFloorSeconds: UInt32 = 12 * 60 * 60

    /// Device roles (config.proto `Role`) the firmware treats as routers for the
    /// floor: ROUTER and ROUTER_LATE. Kept as numbers: the app has no name for
    /// ROUTER_LATE, and a radio can be set to it by another app.
    private static let routerRoles: Set<UInt64> = [2, 11]

    /// The floor for a radio holding the device role `role` (its number in
    /// config.proto).
    static func floorSeconds(role: UInt64) -> UInt32 {
        routerRoles.contains(role) ? routerFloorSeconds : defaultFloorSeconds
    }

    /// Why a short interval does not hold on a default channel. The same words go
    /// under the interval control before a push and in the report of the write
    /// after the radio has restarted. They are statements about firmware 2.7.26,
    /// the one this was read from and measured on.
    static func reason(floorSeconds: UInt32) -> String {
        let floor = floorSeconds >= routerFloorSeconds ? "twelve hours" : "one hour"
        return "This radio sends positions on its public default channel. "
            + "Meshtastic firmware 2.7.26 raises a position interval under \(floor) to \(floor) when the radio restarts. "
            + "A private channel is needed for faster position updates."
    }

    /// `DisplayFormatters::getModemPresetDisplayName(preset, false, usePreset)`:
    /// the name a default channel carries. "Custom" without `use_preset`.
    /// VERY_LONG_SLOW (2) and the presets newer than LONG_TURBO have no case
    /// there, so they are "Invalid".
    static func presetDisplayName(modemPreset: UInt64, usePreset: Bool) -> String {
        guard usePreset else { return "Custom" }
        switch modemPreset {
        case 8: return "ShortTurbo"
        case 5: return "ShortSlow"
        case 6: return "ShortFast"
        case 3: return "MediumSlow"
        case 4: return "MediumFast"
        case 1: return "LongSlow"
        case 0: return "LongFast"
        case 9: return "LongTurbo"
        case 7: return "LongMod"
        default: return "Invalid"
        }
    }
}

// MARK: - What the radio reported

/// What a radio reported about the settings that decide the position floor: its
/// channels, its LoRa config and its role. A part that is not loaded is nil.
struct MeshtasticPositionFacts: Equatable {

    /// The parts of one channel the firmware's rule looks at.
    struct ChannelFacts: Equatable {
        /// The key is exactly one byte with the value 1.
        let defaultKey: Bool
        let name: String
        /// `module_settings.position_precision`, 0 when it is not there.
        let positionPrecision: UInt64
    }

    /// The parts of the LoRa config the rule looks at. An absent field is the
    /// proto3 default: no `use_preset`, and the preset LONG_FAST.
    struct LoraFacts: Equatable {
        let usePreset: Bool
        let modemPreset: UInt64
    }

    /// Slots 0 to 7. Nil where the radio has not reported the slot, or reported
    /// it in a form that cannot be read.
    let channels: [ChannelFacts?]
    let lora: LoraFacts?
    /// The device role as its number in config.proto (an absent field is CLIENT,
    /// 0). Nil until the device config is known.
    let role: UInt64?

    // MARK: Whether positions go out on the default channel

    /// Whether the radio's position channel is its default channel, the way the
    /// firmware decides it. Nil when the answer would need something the radio
    /// has not reported (the LoRa config, or a channel the search has to look
    /// at). False when no channel sends positions at all.
    func onDefaultChannel() -> Bool? {
        guard let lora else { return nil }
        let presetName = MeshtasticPositionFloor.presetDisplayName(
            modemPreset: lora.modemPreset, usePreset: lora.usePreset)
        for index in MeshtasticRadioSettings.channelSlots {
            guard index < channels.count, let channel = channels[index] else { return nil }
            if channel.positionPrecision == 0 { continue }
            // An empty name stands for the preset's name.
            return channel.defaultKey && (channel.name.isEmpty || channel.name == presetName)
        }
        return false
    }

    // MARK: Before a push

    /// The line shown under the interval control, or nil for none: the radio's
    /// position channel is its default channel, and the interval the screen shows
    /// (the radio's own, or the one the operator chose) is above 0 and under the
    /// floor for the radio's role. 0 is how the radio says "use my default", and
    /// the firmware leaves it alone.
    ///
    /// Nothing is said while the interval, the role, the LoRa config or the
    /// channels the rule has to look at are not loaded.
    func intervalHint(shownSeconds: UInt32?) -> String? {
        guard let shown = shownSeconds, let role, onDefaultChannel() == true else { return nil }
        let floor = MeshtasticPositionFloor.floorSeconds(role: role)
        guard shown > 0, shown < floor else { return nil }
        return MeshtasticPositionFloor.reason(floorSeconds: floor)
    }

    // MARK: After the radio is back

    /// Whether the firmware's floor explains an interval that came back
    /// different: the radio's position channel is its default channel, the
    /// interval that was sent was above 0 and under the floor for the radio's
    /// role, and the radio now reports that floor. Nil while the role, the LoRa
    /// config or the channels the rule has to look at are not loaded: the answer
    /// is not known yet, and a later part of the config download can give it.
    func floorExplains(sent: UInt64, reported: UInt64) -> Bool? {
        guard let role, let onDefault = onDefaultChannel() else { return nil }
        let floor = UInt64(MeshtasticPositionFloor.floorSeconds(role: role))
        return onDefault && sent > 0 && sent < floor && reported == floor
    }

    /// The sentence for the report of a write that came back changed, or nil when
    /// the floor does not explain it (or the facts to say so are not all in).
    func intervalReason(sent: UInt64, reported: UInt64) -> String? {
        guard floorExplains(sent: sent, reported: reported) == true, let role else { return nil }
        return MeshtasticPositionFloor.reason(floorSeconds: MeshtasticPositionFloor.floorSeconds(role: role))
    }
}

// MARK: - Reading the raw messages

extension MeshtasticPositionFacts {

    /// The facts in what the radio has reported so far.
    init(_ settings: MeshtasticRadioSettings) {
        self.init(
            channels: MeshtasticRadioSettings.channelSlots.map { index in
                settings.channel(index: index).flatMap { Self.channelFacts(in: $0) }
            },
            lora: settings.config(variant: MeshtasticAdminCodec.ConfigVariant.lora).flatMap { Self.loraFacts(in: $0) },
            role: settings.deviceRole)
    }

    // Field numbers from config.proto, channel.proto and module_config.proto's
    // ModuleSettings, for the ones the admin codec does not have. The codec's own
    // (Channel.settings, ChannelSettings.psk and .name) are used from there.
    private enum Field {
        /// LoRaConfig.use_preset and LoRaConfig.modem_preset.
        static let loraUsePreset = 1
        static let loraModemPreset = 2
        /// ChannelSettings.module_settings.
        static let channelModuleSettings = 7
        /// ModuleSettings.position_precision.
        static let positionPrecision = 1
    }

    /// Channel { 2 settings { 2 psk, 3 name, 7 module_settings { 1 position_precision } } }.
    /// Nil when the message, or the settings or module settings in it, cannot be
    /// read, as `MeshtasticAdminCodec.channelSummary` does.
    static func channelFacts(in channel: Data) -> ChannelFacts? {
        guard let fields = ProtoFields.parse(channel),
              let settings = submessage(MeshtasticAdminCodec.ChannelField.settings, in: fields),
              let module = submessage(Field.channelModuleSettings, in: settings) else { return nil }
        let key = lastBytes(MeshtasticAdminCodec.ChannelSettingsField.psk, in: settings)
        return ChannelFacts(
            defaultKey: key.map { $0.count == 1 && $0.first == 1 } ?? false,
            name: lastBytes(MeshtasticAdminCodec.ChannelSettingsField.name, in: settings)
                .map { String(decoding: $0, as: UTF8.self) } ?? "",
            positionPrecision: lastVarint(Field.positionPrecision, in: module) ?? 0)
    }

    /// LoRaConfig { 1 use_preset, 2 modem_preset }. Nil when the message cannot be
    /// read.
    static func loraFacts(in lora: Data) -> LoraFacts? {
        guard let fields = ProtoFields.parse(lora) else { return nil }
        return LoraFacts(
            usePreset: (lastVarint(Field.loraUsePreset, in: fields) ?? 0) != 0,
            modemPreset: lastVarint(Field.loraModemPreset, in: fields) ?? 0)
    }

    /// The fields of the message in field `number`: none when it is not there,
    /// nil when it is there and cannot be read (not length-delimited, or not well
    /// formed).
    private static func submessage(_ number: Int, in fields: [ProtoFields.Field]) -> [ProtoFields.Field]? {
        guard let field = fields.last(where: { $0.number == number }) else { return [] }
        guard field.wireType == 2 else { return nil }
        return ProtoFields.parse(field.value)
    }

    /// The value of the last varint field with this number, which is the one a
    /// protobuf reader keeps when a field is written twice.
    private static func lastVarint(_ number: Int, in fields: [ProtoFields.Field]) -> UInt64? {
        fields.last(where: { $0.number == number && $0.wireType == 0 })?.varintValue
    }

    /// The bytes of the last length-delimited field with this number.
    private static func lastBytes(_ number: Int, in fields: [ProtoFields.Field]) -> Data? {
        fields.last(where: { $0.number == number && $0.wireType == 2 })?.value
    }
}
