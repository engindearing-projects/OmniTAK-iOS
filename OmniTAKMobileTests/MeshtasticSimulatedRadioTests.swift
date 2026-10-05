//
//  MeshtasticSimulatedRadioTests.swift
//  OmniTAKMobileTests
//
//  #148 against a simulated radio: meshtasticd, the Linux build of the Meshtastic
//  firmware, listening on a TCP port. The other tests in this bundle check the
//  bytes the app builds; this one checks what the firmware does with them, which
//  is where the bug was (the firmware replaces a whole sub-config with the one
//  it receives).
//
//  Skipped unless MESHSIM_HOST is set. MESHSIM_PORT is the port, 4403 if unset.
//
//      TEST_RUNNER_MESHSIM_HOST=127.0.0.1 TEST_RUNNER_MESHSIM_PORT=4404 \
//        xcodebuild test -project OmniTAK.xcodeproj -scheme OmniTAKMobile \
//          -destination 'platform=iOS Simulator,name=iPhone 17e' \
//          -only-testing:OmniTAKTests/MeshtasticSimulatedRadioTests
//
//  The tests write settings to that radio and put them back. Before the first
//  write the test checks that the peer is a simulator, by reading the hardware
//  model in the radio's metadata (PORTDUINO, which is what meshtasticd reports)
//  over a connection of its own, not through the code under test. A peer that
//  cannot be checked is skipped and a peer that is something else fails, and
//  nothing is written to either. Point the test at a simulated radio and not at
//  one anyone is using.
//
//  The simulated radio should hold some non-default settings, because a write
//  that resets a field to its default proves nothing on a radio that already had
//  the default: the device config with a time zone or the LED heartbeat off, the
//  position config with the GPS on, and a primary channel with a key and a
//  location precision. A test that finds nothing to preserve fails.
//
//  What was changed is put back by tearDown, which runs when an assertion fails
//  or a step throws, and puts back only what is still different, so it does
//  nothing when the test already did.
//
//  The app's own path runs end to end: MeshtasticTCPClient reads the config
//  download, MeshtasticProtoDecoder decodes it, MeshtasticManager keeps it and
//  builds the write from it. A config write makes the radio save and restart
//  about 7 seconds later, so those tests wait, reconnect, download again and
//  compare what the radio now holds with what it held. A channel write does not
//  restart it; the app reads the channel back and reports it applied only when
//  the radio's answer matches. Key bytes are never printed or put in an
//  assertion message; they are compared and only the result is reported.
//

import XCTest
import Network
@testable import OmniTAK

// MARK: - Asking a peer what it is

/// Connects to the radio on a connection of its own, asks for its config, and
/// reads the hardware model out of the metadata frame. It shares nothing with
/// the app's client or decoder.
private final class HardwareProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.hardware.probe")
    private var connection: NWConnection?
    private var buffer = Data()
    private var finished = false
    private var continuation: CheckedContinuation<UInt64?, Never>?

    /// The `hw_model` of the radio's DeviceMetadata, or nil when it did not say
    /// in time.
    func hardwareModel(host: String, port: UInt16, timeout: TimeInterval = 10) async -> UInt64? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                guard let endpoint = NWEndpoint.Port(rawValue: port) else { return self.finish(nil) }
                let connection = NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: .tcp)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        let request = LoopbackRadio.frame(ProtoFixture().varint(3, 424_242).data)
                        connection.send(content: request, completion: .contentProcessed { _ in })
                        self?.receive()
                    case .failed, .cancelled:
                        self?.finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(nil) }
            }
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.finished else { return }
            if let data = data { self.buffer.append(data) }
            if let model = self.modelInBuffer() { return self.finish(model) }
            if error != nil || isComplete { return self.finish(nil) }
            self.receive()
        }
    }

    private func modelInBuffer() -> UInt64? {
        while buffer.count >= 4 {
            let bytes = [UInt8](buffer.prefix(4))
            guard bytes[0] == 0x94, bytes[1] == 0xC3 else { buffer.removeFirst(); continue }
            let length = Int(bytes[2]) << 8 | Int(bytes[3])
            guard buffer.count >= 4 + length else { return nil }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            // FromRadio.metadata is field 13, and DeviceMetadata.hw_model is field 9.
            if let metadata = FixtureReader.bytes(13, in: payload),
               let model = FixtureReader.varint(9, in: metadata) {
                return model
            }
        }
        return nil
    }

    private func finish(_ model: UInt64?) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        connection = nil
        continuation?.resume(returning: model)
        continuation = nil
    }
}

// MARK: - The tests

@MainActor
final class MeshtasticSimulatedRadioTests: XCTestCase {

    // MARK: - Setup

    private var host = ""
    private var port: UInt16 = 4403

    /// HardwareModel.PORTDUINO in mesh.proto: what meshtasticd reports.
    private static let portduino: UInt64 = 37
    private static var verifiedSimulator = false

    private let savedHostsKey = "meshtastic_saved_hosts"
    private let appChannelsKey = "meshtastic_app_channels"
    private var savedDefaults: [String: Any?] = [:]

    /// Put-backs for what a test changes, newest first. They run in tearDown.
    private var restores: [() async -> Void] = []

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MESHSIM_HOST"] != nil,
                          "Set MESHSIM_HOST (and MESHSIM_PORT) to run against a simulated radio.")
        host = environment["MESHSIM_HOST"] ?? ""
        port = environment["MESHSIM_PORT"].flatMap { UInt16($0) } ?? 4403

        // Connecting remembers the host, and applying a channel remembers the
        // channel, in the app's defaults. Put both back afterwards.
        for key in [savedHostsKey, appChannelsKey] {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    override func tearDown() async throws {
        // Whatever happened in the test, put the radio back.
        for restore in restores.reversed() { await restore() }
        restores.removeAll()
        for (key, value) in savedDefaults {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    // MARK: - The radio

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Poll until `condition` holds or `seconds` pass. True if it held.
    private func wait(upTo seconds: Double, until condition: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try await pause(0.2)
        }
        return condition()
    }

    /// Check, once, that the peer is a simulator, before anything is written to
    /// it. Skips when that cannot be told and fails when it is something else.
    private func requireSimulator() async throws {
        if Self.verifiedSimulator { return }
        guard let model = await HardwareProbe().hardwareModel(host: host, port: port) else {
            throw XCTSkip("Could not read the hardware model of \(host):\(port), so it is not known to be a simulator. Nothing was written.")
        }
        guard model == Self.portduino else {
            XCTFail("\(host):\(port) reports hardware model \(model), not PORTDUINO (\(Self.portduino)). It is not a simulated radio. Nothing was written.")
            throw SimulatedRadioError.notASimulator
        }
        Self.verifiedSimulator = true
        // The radio takes one client at a time: let it notice this one is gone.
        try await pause(1)
    }

    private enum SimulatedRadioError: Error { case notASimulator, didNotReturn }

    /// Connect with a manager of its own and wait for the config download. A
    /// radio that is restarting refuses the connection, so this keeps trying.
    ///
    /// `firstContact` is the connection a test opens with. If the radio does not
    /// answer then, the test is skipped: there is no simulated radio. Any later
    /// connection follows a write, and a radio that does not come back from that
    /// is a failure.
    private func connect(firstContact: Bool = false, within seconds: Double = 90) async throws -> MeshtasticManager {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let manager = MeshtasticManager()
            manager.connectTCP(host: host, port: port)
            let loaded = try await wait(upTo: 12) {
                manager.isConnected
                    && manager.radioSettings.nodeNum != nil
                    && manager.radioSettings.hasDeviceConfig
                    && manager.radioSettings.hasPositionConfig
                    && manager.radioSettings.channel(index: 0) != nil
            }
            if loaded { return manager }
            manager.disconnect()
            try await pause(1)
        }
        let problem = "The simulated radio at \(host):\(port) did not finish a config download in \(Int(seconds)) s."
        if firstContact { throw XCTSkip(problem) }
        XCTFail(problem)
        throw SimulatedRadioError.didNotReturn
    }

    /// After a config write: give the radio time to take it, note whether it
    /// closed the link the way a restarting radio does, then leave and wait for
    /// the restart to be over.
    private func letTheRadioRestart(_ manager: MeshtasticManager) async throws {
        let wrote = Date()
        try await pause(3)
        // A radio that restarts closes the link. The app must then have
        // dropped what the radio had reported.
        let dropped = try await wait(upTo: 20) { !manager.isConnected }
        if dropped {
            XCTAssertTrue(manager.radioSettings.isEmpty, "the settings of a radio whose link dropped are forgotten")
            print("simulated radio: link closed \(Int(Date().timeIntervalSince(wrote))) s after the write, settings forgotten")
        } else {
            print("simulated radio: link still open 23 s after the write")
        }
        manager.disconnect()
        try await pause(dropped ? 8 : 12)
    }

    // MARK: - Comparing what the radio holds

    /// The numbers of the top-level fields that differ between two messages:
    /// present in one and not the other, or written differently. Only numbers,
    /// so that a failure never prints the bytes of a key.
    private func differingFields(_ a: Data, _ b: Data) -> [Int] {
        guard let left = FixtureReader.fields(a), let right = FixtureReader.fields(b) else { return [-1] }
        var numbers = Set<Int>()
        for field in left where !right.contains(where: { $0.raw == field.raw }) { numbers.insert(field.number) }
        for field in right where !left.contains(where: { $0.raw == field.raw }) { numbers.insert(field.number) }
        return numbers.sorted()
    }

    /// The numbers of the fields a message holds besides `number`. A radio at
    /// its defaults sends none of them.
    private func fieldNumbers(in message: Data, besides number: Int) -> [Int] {
        (FixtureReader.fields(message) ?? []).map(\.number).filter { $0 != number }
    }

    private func config(_ variant: Int, of manager: MeshtasticManager) throws -> Data {
        try XCTUnwrap(manager.radioSettings.config(variant: variant), "the radio did not send config \(variant)")
    }

    private func report(_ manager: MeshtasticManager, slot: Int) async throws -> MeshtasticChannelReport.State? {
        _ = try await wait(upTo: 10) {
            manager.channelReports.first(where: { $0.slot == slot }).map { $0.state != .sent } ?? false
        }
        return manager.channelReports.first(where: { $0.slot == slot })?.state
    }

    // MARK: - Putting it back

    /// Put the position interval back to `seconds`, if it is not there. Connects
    /// to see.
    private func restorePositionInterval(_ seconds: UInt32) async {
        guard let manager = try? await connect() else { return }
        defer { manager.disconnect() }
        switch manager.applyPositionBroadcastInterval(seconds: seconds) {
        case .unchanged:
            return
        case .sent:
            try? await letTheRadioRestart(manager)
            if let again = try? await connect() {
                if again.radioSettings.positionBroadcastSeconds != seconds {
                    XCTFail("could not put the position interval back to \(seconds)")
                }
                again.disconnect()
            }
        case .refused(let reason):
            XCTFail("could not put the position interval back: \(reason)")
        }
    }

    /// Put the rebroadcast mode back to `mode`, if it is not there.
    private func restoreRebroadcast(_ mode: MeshtasticAdminCodec.RebroadcastMode) async {
        guard let manager = try? await connect() else { return }
        defer { manager.disconnect() }
        switch manager.applyDeviceConfig(role: manager.radioSettings.namedDeviceRole, rebroadcastMode: mode) {
        case .unchanged:
            return
        case .sent:
            try? await letTheRadioRestart(manager)
            if let again = try? await connect() {
                if again.radioSettings.namedRebroadcastMode != mode {
                    XCTFail("could not put the rebroadcast mode back to \(mode)")
                }
                again.disconnect()
            }
        case .refused(let reason):
            XCTFail("could not put the rebroadcast mode back: \(reason)")
        }
    }

    /// Put channel 0 back to this name, with the key it has. The key stays in
    /// memory and is never printed.
    private func restorePrimaryName(_ name: String) async {
        guard let manager = try? await connect() else { return }
        defer { manager.disconnect() }
        let outcome = manager.createChannel(name: name, keyText: "", noEncryption: false, replacePrimary: true)
        switch outcome.result {
        case .unchanged:
            return
        case .sent:
            let state = try? await report(manager, slot: 0)
            if state != .applied { XCTFail("could not put the name of channel 0 back") }
        case .refused(let reason):
            XCTFail("could not put the name of channel 0 back: \(reason)")
        }
    }

    // MARK: - 1. Position broadcast interval

    func testChangingThePositionIntervalChangesOnlyTheInterval() async throws {
        try await requireSimulator()
        let first = try await connect(firstContact: true)
        let before = try config(RadioProto.Config.position, of: first)
        let oldSeconds = FixtureReader.varint(RadioProto.Position.broadcastSecs, in: before) ?? 0
        XCTAssertFalse(fieldNumbers(in: before, besides: RadioProto.Position.broadcastSecs).isEmpty,
                       "the radio must hold non-default position settings besides the interval, or this proves nothing")
        let newSeconds: UInt32 = oldSeconds == 900 ? 1200 : 900

        // Registered before the write, so that it runs if anything below fails.
        restores.append { [self] in await restorePositionInterval(UInt32(oldSeconds)) }

        // Applying the interval the radio already has sends nothing, so the
        // radio does not restart for it.
        XCTAssertEqual(first.applyPositionBroadcastInterval(seconds: UInt32(oldSeconds)), .unchanged)

        XCTAssertEqual(first.applyPositionBroadcastInterval(seconds: newSeconds), .sent)
        // The app does not claim to know what the radio holds now.
        XCTAssertNil(first.radioSettings.positionBroadcastSeconds)
        try await letTheRadioRestart(first)

        let second = try await connect()
        let after = try config(RadioProto.Config.position, of: second)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Position.broadcastSecs, in: after), UInt64(newSeconds))
        XCTAssertEqual(differingFields(before, after), [RadioProto.Position.broadcastSecs],
                       "only position_broadcast_secs may differ")
        for field in [RadioProto.Position.gpsMode, RadioProto.Position.flags, RadioProto.Position.smartEnabled,
                      RadioProto.Position.gpsUpdateInterval, RadioProto.Position.smartMinimumDistance,
                      RadioProto.Position.smartMinimumIntervalSecs] {
            XCTAssertEqual(FixtureReader.varint(field, in: after), FixtureReader.varint(field, in: before),
                           "position field \(field) is what it was")
        }
        print("simulated radio: position_broadcast_secs \(oldSeconds) -> \(newSeconds) -> restore")

        // Put it back.
        XCTAssertEqual(second.applyPositionBroadcastInterval(seconds: UInt32(oldSeconds)), .sent)
        try await letTheRadioRestart(second)
        let third = try await connect()
        XCTAssertEqual(differingFields(before, try config(RadioProto.Config.position, of: third)), [], "restored")
        third.disconnect()
    }

    // MARK: - 2. Device config

    func testChangingTheRebroadcastModeKeepsTheTimeZoneAndTheRestOfTheDeviceConfig() async throws {
        try await requireSimulator()
        let first = try await connect(firstContact: true)
        let before = try config(RadioProto.Config.device, of: first)
        let rebroadcast = RadioProto.Device.rebroadcastMode
        let oldMode = FixtureReader.varint(rebroadcast, in: before) ?? 0
        XCTAssertFalse(fieldNumbers(in: before, besides: rebroadcast).isEmpty,
                       "the radio must hold non-default device settings besides the rebroadcast mode")
        let oldRestore = MeshtasticAdminCodec.RebroadcastMode(rawValue: oldMode) ?? .all
        restores.append { [self] in await restoreRebroadcast(oldRestore) }

        // The role is CLIENT, a default the radio leaves out of its message. The
        // screen starts its role control at the radio's role, so a radio like
        // this one reads as CLIENT and not as "unknown", and nothing else is
        // written for it.
        let controls = MeshtasticSettingsControls(radio: first.radioSettings)
        XCTAssertEqual(controls.role, .client, "this test starts from role CLIENT")
        XCTAssertEqual(controls.rebroadcast.map { $0.rawValue }, oldMode)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: before) ?? 0, RadioProto.DeviceRole.client,
                       "the radio's role is CLIENT")

        // Applying the controls as they stand sends nothing.
        let untouched = controls.deviceEdits(against: first.radioSettings)
        XCTAssertEqual(first.applyDeviceConfig(role: untouched.role, rebroadcastMode: untouched.rebroadcast), .unchanged)

        // The rebroadcast mode only. A role change makes the firmware install
        // that role's defaults, so the role is left as the radio has it: the
        // role control still stands at CLIENT when the operator moves the other.
        let newMode: MeshtasticAdminCodec.RebroadcastMode = oldMode == 2 ? .knownOnly : .localOnly
        XCTAssertEqual(first.applyDeviceConfig(role: controls.role, rebroadcastMode: newMode), .sent)
        try await letTheRadioRestart(first)

        let second = try await connect()
        let after = try config(RadioProto.Config.device, of: second)
        XCTAssertEqual(FixtureReader.varint(rebroadcast, in: after), newMode.rawValue)
        XCTAssertEqual(differingFields(before, after), [rebroadcast], "only rebroadcast_mode may differ")
        XCTAssertEqual(FixtureReader.bytes(RadioProto.Device.tzdef, in: after),
                       FixtureReader.bytes(RadioProto.Device.tzdef, in: before), "the time zone is what it was")
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.ledHeartbeatDisabled, in: after),
                       FixtureReader.varint(RadioProto.Device.ledHeartbeatDisabled, in: before))
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: after),
                       FixtureReader.varint(RadioProto.Device.role, in: before), "the role is what it was")
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: after) ?? 0, RadioProto.DeviceRole.client,
                       "the role is still CLIENT")
        XCTAssertEqual(second.radioSettings.namedDeviceRole, .client)
        print("simulated radio: rebroadcast_mode \(oldMode) -> \(newMode.rawValue) -> restore, role still CLIENT")

        // Put it back.
        XCTAssertEqual(second.applyDeviceConfig(role: second.radioSettings.namedDeviceRole, rebroadcastMode: oldRestore), .sent)
        try await letTheRadioRestart(second)
        let third = try await connect()
        XCTAssertEqual(differingFields(before, try config(RadioProto.Config.device, of: third)), [], "restored")
        third.disconnect()
    }

    // MARK: - 3. Channel, and the read-back

    func testRenamingChannelZeroKeepsTheKeyAndTheLocationPrecisionAndIsReadBack() async throws {
        try await requireSimulator()
        let first = try await connect(firstContact: true)
        let before = try XCTUnwrap(first.radioSettings.channel(index: 0))
        let beforeSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: before))
        let key = try XCTUnwrap(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: beforeSettings))
        let oldName = String(data: FixtureReader.bytes(RadioProto.ChannelSettings.name, in: beforeSettings) ?? Data(),
                             encoding: .utf8) ?? ""
        let module = try XCTUnwrap(FixtureReader.bytes(RadioProto.ChannelSettings.moduleSettings, in: beforeSettings),
                                   "the radio's channel 0 must carry module settings (a location precision)")
        let oldPrecision = FixtureReader.varint(RadioProto.ModuleSettings.positionPrecision, in: module) ?? 0
        XCTAssertGreaterThan(oldPrecision, 0, "the radio's channel 0 must have a location precision to preserve")
        XCTAssertGreaterThan(key.count, 1, "the radio's channel 0 must have a key to preserve")
        restores.append { [self] in await restorePrimaryName(oldName) }

        // A new name and nothing in the key field: the radio's key is kept. The
        // operator chose to replace the primary.
        let newName = oldName == "simtest2" ? "simtest3" : "simtest2"
        let outcome = first.createChannel(name: newName, keyText: "", noEncryption: false, replacePrimary: true)
        XCTAssertEqual(outcome.result, .sent)
        XCTAssertEqual(outcome.slot, 0)

        // "Sent" is all that is known until the radio answers. Then it is applied
        // only if the radio's own answer has the new name, the same key and the
        // same role.
        XCTAssertNil(first.radioSettings.channel(index: 0), "what was sent is not taken for what the radio holds")
        let state = try await report(first, slot: 0)
        XCTAssertEqual(state, .applied, "the radio's answer to the read-back matched")

        // The answer is now what the app holds, and it is what the radio holds.
        let answered = try XCTUnwrap(first.radioSettings.channel(index: 0))
        let answeredSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: answered))
        XCTAssertEqual(differingFields(before, answered), [RadioProto.Channel.settings], "only the settings may differ")
        XCTAssertEqual(differingFields(beforeSettings, answeredSettings), [RadioProto.ChannelSettings.name],
                       "only the name may differ inside the settings")
        XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: answeredSettings) == key, "the key is unchanged")
        let answeredModule = FixtureReader.bytes(RadioProto.ChannelSettings.moduleSettings, in: answeredSettings)
        XCTAssertEqual(answeredModule.flatMap { FixtureReader.varint(RadioProto.ModuleSettings.positionPrecision, in: $0) },
                       oldPrecision, "the location precision is what it was")
        print("simulated radio: channel 0 renamed \(oldName.count) -> \(newName.count) characters, key length \(key.count), precision \(oldPrecision), read back and reported applied")

        // A second apply of the same thing is not sent again.
        XCTAssertEqual(first.createChannel(name: newName, keyText: "", noEncryption: false, replacePrimary: true).result, .unchanged)

        // And it is what a fresh download says too, whether or not the link
        // restarted, so compare after reconnecting.
        first.disconnect()
        try await pause(2)
        let second = try await connect()
        let after = try XCTUnwrap(second.radioSettings.channel(index: 0))
        XCTAssertEqual(differingFields(before, after), [RadioProto.Channel.settings])
        let afterSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: after))
        XCTAssertEqual(differingFields(beforeSettings, afterSettings), [RadioProto.ChannelSettings.name])

        // Put the name back, and see it read back as applied.
        let restore = second.createChannel(name: oldName, keyText: "", noEncryption: false, replacePrimary: true)
        XCTAssertEqual(restore.result, .sent)
        let restored = try await report(second, slot: 0)
        XCTAssertEqual(restored, .applied)
        XCTAssertTrue(second.radioSettings.channel(index: 0) == before, "restored, byte for byte")
        second.disconnect()
    }
}
