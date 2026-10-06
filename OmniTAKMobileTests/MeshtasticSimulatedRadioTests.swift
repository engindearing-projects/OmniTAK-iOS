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
//  download, MeshtasticProtoDecoder decodes it, MeshtasticManager asks the radio
//  for the sub-config again, builds the write from the answer, sends it and reads
//  it back. A config write makes the radio save and restart about 7 seconds
//  later, so those tests wait, reconnect, download again and compare what the
//  radio now holds with what it held. A channel write does not restart it. The
//  app reports "applied" only when the radio's own answer to the read-back
//  matches. Key bytes are never printed or put in an assertion message; they
//  are compared and only the result is reported.
//
//  A set of channels is sent as one set_channel after another with no edit
//  transaction. One test imports four channels that way, checks that the radio
//  did not restart for it, restarts the radio on purpose (a reboot message, which
//  is not something the app ever sends), and checks that the four channels are
//  still there byte for byte: what a set_channel saves, it saves.
//
//  One test only reads. It asks the radio for each kind of thing the app asks
//  for and reports what the answers carry: the id of the request echoed in
//  Data.request_id, and the receive metadata a packet from outside would have
//  (signal strength, signal-to-noise ratio, MQTT flag, transport mechanism),
//  together with the arrival time and hop start the radio sets on its own
//  packets.
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

    /// Connect the manager it already has again, as an operator does after the
    /// radio restarted, and wait for the config download. What the manager
    /// remembers of what it sent stays.
    private func reconnect(_ manager: MeshtasticManager, within seconds: Double = 90) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            manager.connectTCP(host: host, port: port)
            let loaded = try await wait(upTo: 12) {
                manager.isConnected
                    && manager.radioSettings.nodeNum != nil
                    && manager.radioSettings.hasDeviceConfig
                    && manager.radioSettings.hasPositionConfig
                    && manager.radioSettings.channel(index: 0) != nil
            }
            if loaded { return }
            manager.disconnect()
            try await pause(1)
        }
        XCTFail("The simulated radio at \(host):\(port) did not finish a config download in \(Int(seconds)) s.")
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

    // MARK: - Putting it back

    /// Put the position interval back to `seconds`, if it is not there. Connects
    /// to see.
    private func restorePositionInterval(_ seconds: UInt32) async {
        guard let manager = try? await connect() else { return }
        defer { manager.disconnect() }
        let result = await manager.applyPositionBroadcastInterval(seconds: seconds)
        switch result {
        case .unchanged:
            return
        case .applied, .notConfirmed:
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
        let result = await manager.applyDeviceConfig(role: manager.radioSettings.namedDeviceRole, rebroadcastMode: mode)
        switch result {
        case .unchanged:
            return
        case .applied, .notConfirmed:
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
        let outcome = await manager.createChannel(name: name, keyText: "", noEncryption: false, replacePrimary: true)
        switch outcome.result {
        case .unchanged, .applied:
            return
        case .notConfirmed(let reason):
            XCTFail("could not put the name of channel 0 back: \(reason)")
        case .refused(let reason):
            XCTFail("could not put the name of channel 0 back: \(reason)")
        }
    }

    /// Put channel slots back to the bytes the radio itself reported for them, if
    /// they differ: a set_channel of those bytes, nothing built from scratch. The
    /// bytes include keys and are only compared, never printed.
    private func restoreChannelSlots(_ before: [Int: Data]) async {
        guard let manager = try? await connect() else { return }
        defer { manager.disconnect() }
        guard case .go(let route) = manager.route() else { return XCTFail("no route to put the channel slots back") }
        for slot in before.keys.sorted() where manager.radioSettings.channel(index: slot) != before[slot] {
            let admin = ProtoFixture().bytes(RadioProto.Admin.setChannel, before[slot]!).data
            _ = await manager.sendFrame(admin, wantResponse: false, packetID: manager.freshPacketID(), route: route)
        }
        let outcome = await manager.rereadFromRadio()
        if outcome.refusal != nil || !outcome.missing.isEmpty {
            XCTFail("could not read the channel slots back after putting them back")
        }
        for slot in before.keys.sorted() where manager.radioSettings.channel(index: slot) != before[slot] {
            XCTFail("channel slot \(slot) could not be put back")
        }
    }

    // MARK: - 0. What a local answer carries (reads only)

    func testALocalAnswerEchoesTheRequestIdAndCarriesNoReceiveMetadata() async throws {
        try await requireSimulator()
        let probe = AnswerProbe()
        let findings = await probe.measure(host: host, port: port)
        XCTAssertFalse(findings.isEmpty, "the radio answered nothing")
        XCTAssertEqual(findings.count, 4, "a device config, a position config and two channels")
        for finding in findings {
            // The seven fields, as measured.
            print("simulated radio answer to \(finding.asked): \(finding.report)")
            XCTAssertTrue(finding.answered, "\(finding.asked): no answer")
            XCTAssertTrue(finding.requestIdEchoed, "\(finding.asked): request_id is the id of the request")
            XCTAssertEqual(finding.from, finding.node, "\(finding.asked): from the radio itself")
            // Zero is the same as absent.
            XCTAssertEqual(finding.rxRssi ?? 0, 0, "\(finding.asked): rx_rssi")
            XCTAssertEqual(finding.rxSnr ?? 0, 0, "\(finding.asked): rx_snr")
            XCTAssertEqual(finding.viaMqtt ?? 0, 0, "\(finding.asked): via_mqtt")
            XCTAssertEqual(finding.transportMechanism ?? 0, 0, "\(finding.asked): transport_mechanism")
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

        // Applying the interval the radio already has sends no write, so the
        // radio does not restart for it.
        let unchanged = await first.applyPositionBroadcastInterval(seconds: UInt32(oldSeconds))
        XCTAssertEqual(unchanged, .unchanged)

        // The radio is asked, the write goes, and the radio is asked again: it
        // says what it holds, and the app reports applied.
        let applied = await first.applyPositionBroadcastInterval(seconds: newSeconds)
        XCTAssertEqual(applied, .applied)
        XCTAssertEqual(first.radioSettings.positionBroadcastSeconds, newSeconds, "the radio's own answer")
        XCTAssertEqual(first.configReports.first?.state, .confirmed, "the answer before the restart is not the last word")
        try await letTheRadioRestart(first)

        // The operator connects again, with the same manager. The radio, back from
        // its restart, reports the interval, and the app says whether it kept it.
        try await reconnect(first)
        let second = first
        XCTAssertEqual(second.configReports.first?.state, .appliedAfterRestart,
                       "the radio reports what was sent after it restarted")
        XCTAssertTrue(second.pendingConfigWrites.isEmpty)
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
        let back = await second.applyPositionBroadcastInterval(seconds: UInt32(oldSeconds))
        XCTAssertEqual(back, .applied)
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

        // Applying the controls as they stand sends no write.
        let untouched = controls.deviceEdits(against: first.radioSettings)
        let nothing = await first.applyDeviceConfig(role: untouched.role, rebroadcastMode: untouched.rebroadcast)
        XCTAssertEqual(nothing, .unchanged)

        // The rebroadcast mode only. A role change makes the firmware install
        // that role's defaults, so the role is left as the radio has it: the
        // role control still stands at CLIENT when the operator moves the other.
        let newMode: MeshtasticAdminCodec.RebroadcastMode = oldMode == 2 ? .knownOnly : .localOnly
        let applied = await first.applyDeviceConfig(role: controls.role, rebroadcastMode: newMode)
        XCTAssertEqual(applied, .applied)
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
        let back = await second.applyDeviceConfig(role: second.radioSettings.namedDeviceRole, rebroadcastMode: oldRestore)
        XCTAssertEqual(back, .applied)
        try await letTheRadioRestart(second)
        let third = try await connect()
        XCTAssertEqual(differingFields(before, try config(RadioProto.Config.device, of: third)), [], "restored")
        third.disconnect()
    }

    // MARK: - 4. A set of channels needs no transaction and survives a restart

    func testAnImportOfFourChannelsWithNoTransactionIsStillOnTheRadioAfterItRestarts() async throws {
        try await requireSimulator()
        let first = try await connect(firstContact: true)

        // Slots 1 to 4 must be free: nothing is overwritten, and what they hold now
        // is what is put back.
        var before: [Int: Data] = [:]
        for slot in 1...4 {
            let held = try XCTUnwrap(first.radioSettings.channel(index: slot), "the radio did not send slot \(slot)")
            before[slot] = held
            let summary = try XCTUnwrap(MeshtasticAdminCodec.channelSummary(in: held))
            if !summary.isDisabled { throw XCTSkip("slot \(slot) of the simulated radio is in use. Nothing was written.") }
        }
        restores.append { [self] in await restoreChannelSlots(before) }

        // Four private keys, made up and never printed.
        let channels = (1...4).map { number in
            MeshChannel(name: "simimp\(number)", psk: Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ number &* 31) }))
        }
        let outcome = await first.importChannels(channels)

        XCTAssertEqual(outcome.confirmed, [1, 2, 3, 4], "the radio's own answers show all four")
        XCTAssertTrue(outcome.unconfirmed.isEmpty)
        XCTAssertNil(outcome.refusal)
        XCTAssertEqual(outcome.notTried, 0)
        var imported: [Int: Data] = [:]
        for slot in 1...4 { imported[slot] = first.radioSettings.channel(index: slot) }

        // The radio does not restart for a set_channel. A commit would have made
        // it close the link within a few seconds, and none was sent.
        try await pause(10)
        XCTAssertTrue(first.isConnected, "the link is still up: nothing the import sent made the radio restart")

        // Restart it on purpose, with a reboot message built here. Field 97 is
        // reboot_seconds; the bytes are checked before they go, because the
        // neighbouring field 96 is exit_simulator.
        let reboot = ProtoFixture().varint(97, 2).data
        XCTAssertEqual(Array(reboot), [0x88, 0x06, 0x02], "reboot_seconds = 2")
        guard case .go(let route) = first.route() else { return XCTFail("no route to the radio") }
        let sent = await first.sendFrame(reboot, wantResponse: false, packetID: first.freshPacketID(), route: route)
        XCTAssertTrue(sent)
        let closed = try await wait(upTo: 30) { !first.isConnected }
        XCTAssertTrue(closed, "the radio restarted and closed the link")
        first.disconnect()
        try await pause(8)

        // Back from the restart, the four channels are there, byte for byte.
        let second = try await connect()
        for slot in 1...4 {
            let held = second.radioSettings.channel(index: slot)
            XCTAssertTrue(held == imported[slot], "slot \(slot) is what the import wrote")
            XCTAssertEqual(held.flatMap { MeshtasticAdminCodec.channelSummary(in: $0) }?.name, "simimp\(slot)")
        }
        print("simulated radio: four channels imported with no transaction, the link stayed up, the radio was restarted, and all four were still there")
        second.disconnect()

        // Put the four slots back, and see that they are.
        await restoreChannelSlots(before)
        let third = try await connect()
        for slot in 1...4 { XCTAssertTrue(third.radioSettings.channel(index: slot) == before[slot], "slot \(slot) restored") }
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
        let outcome = await first.createChannel(name: newName, keyText: "", noEncryption: false, replacePrimary: true)
        XCTAssertEqual(outcome, MeshtasticManager.ChannelOutcome(result: .applied, slot: 0),
                       "applied: the radio's own answer to the read-back matched")
        XCTAssertEqual(first.channelReports.first(where: { $0.slot == 0 })?.state, .applied)

        // The answer is what the app holds, and it is what the radio holds.
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
        let again = await first.createChannel(name: newName, keyText: "", noEncryption: false, replacePrimary: true)
        XCTAssertEqual(again.result, .unchanged)

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
        let restore = await second.createChannel(name: oldName, keyText: "", noEncryption: false, replacePrimary: true)
        XCTAssertEqual(restore.result, .applied)
        XCTAssertTrue(second.radioSettings.channel(index: 0) == before, "restored, byte for byte")
        second.disconnect()
    }
}

// MARK: - Measuring what an answer carries

/// What one answer from the radio carried. A field that was not in the packet
/// is nil.
private struct AnswerFinding {
    let asked: String
    let node: UInt32
    let answered: Bool
    let requestIdEchoed: Bool
    let from: UInt32?
    let rxRssi: UInt64?
    let rxSnr: UInt64?
    let rxTime: UInt64?
    let hopStart: UInt64?
    let viaMqtt: UInt64?
    let transportMechanism: UInt64?
    let requestId: UInt64?

    /// The seven fields, as text.
    var report: String {
        func show(_ value: UInt64?) -> String { value.map { String($0) } ?? "absent" }
        return "request_id \(requestIdEchoed ? "equals the id of the request" : "DOES NOT equal it (\(show(requestId)))"), "
            + "rx_rssi \(show(rxRssi)), rx_snr \(show(rxSnr)), rx_time \(show(rxTime)), "
            + "hop_start \(show(hopStart)), via_mqtt \(show(viaMqtt)), transport_mechanism \(show(transportMechanism))"
    }
}

/// Connects to the radio on a connection of its own, downloads its config, and
/// then asks for a device config, a position config and two channels, one at a
/// time and 100 ms apart, never writing. It reads the packets that answer with a
/// reader of its own, not the code under test.
private final class AnswerProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.answer.probe")
    private var connection: NWConnection?
    private var buffer = Data()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?

    func measure(host: String, port: UInt16) async -> [AnswerFinding] {
        guard await open(host: host, port: port) else { return [] }
        defer { connection?.cancel() }

        // The download, for the radio's node number.
        let configID = UInt64.random(in: 1...UInt64(UInt32.max))
        send(ProtoFixture().varint(3, configID).data)
        var node: UInt32 = 0
        download: while let frame = await next(timeout: 15) {
            if let info = FixtureReader.bytes(RadioProto.FromRadio.myInfo, in: frame),
               let number = FixtureReader.varint(1, in: info) { node = UInt32(truncatingIfNeeded: number) }
            if FixtureReader.varint(RadioProto.FromRadio.configCompleteId, in: frame) == configID { break download }
        }
        guard node != 0 else { return [] }

        let requests: [(String, Data)] = [
            ("get_config_request(device)", ProtoFixture().varint(RadioProto.Admin.getConfigRequest, 0).data),
            ("get_config_request(position)", ProtoFixture().varint(RadioProto.Admin.getConfigRequest, 1).data),
            ("get_channel_request(slot 0)", ProtoFixture().varint(RadioProto.Admin.getChannelRequest, 1).data),
            ("get_channel_request(slot 1)", ProtoFixture().varint(RadioProto.Admin.getChannelRequest, 2).data),
        ]
        var findings: [AnswerFinding] = []
        for (label, admin) in requests {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let id = UInt32.random(in: 1...UInt32.max)
            send(Self.toRadio(admin: admin, node: node, id: id))
            findings.append(await answer(to: id, label: label, node: node))
        }
        return findings
    }

    private static func toRadio(admin: Data, node: UInt32, id: UInt32) -> Data {
        let data = ProtoFixture()
            .varint(RadioProto.DataMessage.portnum, RadioProto.adminPortnum)
            .bytes(RadioProto.DataMessage.payload, admin)
            .varint(RadioProto.DataMessage.wantResponse, 1)
        let packet = ProtoFixture()
            .fixed32(RadioProto.MeshPacket.to, node)
            .message(RadioProto.MeshPacket.decoded, data)
            .fixed32(RadioProto.MeshPacket.id, id)
            .varint(RadioProto.MeshPacket.hopLimit, 3)
            .varint(RadioProto.MeshPacket.wantAck, 1)
        return ProtoFixture().message(RadioProto.ToRadio.packet, packet).data
    }

    private func answer(to id: UInt32, label: String, node: UInt32) async -> AnswerFinding {
        while let frame = await next(timeout: 5) {
            guard let packet = FixtureReader.bytes(RadioProto.FromRadio.packet, in: frame),
                  let fields = FixtureReader.fields(packet),
                  let decoded = FixtureReader.bytes(RadioProto.MeshPacket.decoded, in: packet),
                  FixtureReader.varint(RadioProto.DataMessage.portnum, in: decoded) == RadioProto.adminPortnum,
                  let admin = FixtureReader.bytes(RadioProto.DataMessage.payload, in: decoded),
                  let answerKind = FixtureReader.fields(admin)?.first?.number,
                  [RadioProto.Admin.getConfigResponse, RadioProto.Admin.getChannelResponse].contains(answerKind) else { continue }
            func fixed32(_ number: Int) -> UInt32? {
                guard let field = fields.last(where: { $0.number == number && $0.wire == 5 }) else { return nil }
                return field.value.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            }
            func varint(_ number: Int) -> UInt64? { FixtureReader.varint(number, in: packet) }
            let requestId = FixtureReader.fields(decoded)?.last(where: { $0.number == RadioProto.DataMessage.requestId && $0.wire == 5 })
                .map { $0.value.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
            // A zero is as good as absent for the receive fields, and is reported as a value.
            return AnswerFinding(
                asked: label, node: node, answered: true, requestIdEchoed: requestId == id, from: fixed32(RadioProto.MeshPacket.from),
                rxRssi: varint(RadioProto.MeshPacket.rxRssi), rxSnr: fixed32(RadioProto.MeshPacket.rxSnr).map { UInt64($0) },
                rxTime: fixed32(RadioProto.MeshPacket.rxTime).map { UInt64($0) },
                hopStart: varint(RadioProto.MeshPacket.hopStart), viaMqtt: varint(RadioProto.MeshPacket.viaMqtt),
                transportMechanism: varint(RadioProto.MeshPacket.transportMechanism),
                requestId: requestId.map { UInt64($0) })
        }
        return AnswerFinding(asked: label, node: node, answered: false, requestIdEchoed: false, from: nil, rxRssi: nil,
                             rxSnr: nil, rxTime: nil, hopStart: nil, viaMqtt: nil, transportMechanism: nil, requestId: nil)
    }

    // MARK: Connection

    private func open(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let endpoint = NWEndpoint.Port(rawValue: port) else { return continuation.resume(returning: false) }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: .tcp)
            self.connection = connection
            let once = OnceFlag()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.first() { continuation.resume(returning: true) }
                    self?.receive()
                case .failed, .cancelled:
                    if once.first() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ payload: Data) {
        connection?.send(content: LoopbackRadio.frame(payload), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if error != nil || isComplete { return }
            self.receive()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let bytes = [UInt8](buffer.prefix(4))
            guard bytes[0] == 0x94, bytes[1] == 0xC3 else { buffer.removeFirst(); continue }
            let length = Int(bytes[2]) << 8 | Int(bytes[3])
            guard buffer.count >= 4 + length else { return }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            if let waiting = waiter {
                waiter = nil
                waiting.resume(returning: payload)
            } else {
                inbox.append(payload)
            }
        }
    }

    /// The next frame, or nil when none comes in time.
    private func next(timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                if !self.inbox.isEmpty {
                    return continuation.resume(returning: self.inbox.removeFirst())
                }
                self.waiter = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let waiting = self.waiter {
                        self.waiter = nil
                        waiting.resume(returning: nil)
                    }
                }
            }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
