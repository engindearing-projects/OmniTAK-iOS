//
//  MeshServerRelayTests.swift
//  OmniTAKMobileTests
//
//  Issue #113 — mesh ↔ TAK server CoT relay (gateway mode), off by default.
//
//  A gateway is the most dangerous thing this app can do to a LoRa channel: it
//  wires a chatty IP network into a link with a duty cycle measured in percent.
//  So the whole decision layer is pure and is pinned here, without a socket or a
//  radio, exactly as the Android `MeshServerRelayTest` pins its counterpart:
//
//    1. Loop prevention — the safety-critical property. A CoT that arrived on
//       the mesh must NEVER go back to the mesh, and one from the server must
//       NEVER go back to the server. A relay loop on LoRa is unrecoverable in
//       the field (there is no operator-visible kill switch on a saturated
//       channel), so these are asserted exhaustively over every transport.
//    2. Off by default + both-ends gating — the toggle, and the two connection
//       booleans, each independently veto every relay.
//    3. Type ALLOWLIST — only the handful of types worth LoRa airtime cross to
//       the mesh. An allowlist (not a denylist) means a CoT type nobody has
//       thought about yet — a future enrollment/credential-bearing one included
//       — defaults to "does not cross".
//    4. Per-uid throttle with a BOUNDED map — a busy TAK server has hundreds of
//       contacts; an unbounded uid→timestamp dictionary is a slow memory leak on
//       a device that has to survive a multi-day mission.
//    5. mesh→server XML rebuild, including escaping of the attacker-controlled
//       callsign (anyone with the channel PSK can name themselves anything).
//
//  The live transports (LoRa radio, TCP/TLS server socket) are NOT exercised
//  here — that needs a radio and a server, and is the on-hardware checklist in
//  the PR. Everything below is deterministic pure Swift.
//

import XCTest
@testable import OmniTAK

final class MeshServerRelayTests: XCTestCase {

    // MARK: - Fixtures

    private func event(uid: String = "MESH-1", type: String = "a-f-G-U-C",
                       callsign: String = "ALPHA-1") -> CoTEvent {
        CoTEvent(
            uid: uid,
            type: type,
            time: Date(timeIntervalSince1970: 1_714_000_000),
            point: CoTPoint(lat: 47.6062, lon: -122.3321, hae: 56.0, ce: 5, le: 5),
            detail: CoTDetail(
                callsign: callsign, team: "Cyan", teamRole: "Team Member",
                speed: 3.0, course: 270.0, remarks: "mesh contact",
                battery: 85, device: nil, platform: nil
            )
        )
    }

    private func inputs(
        _ e: CoTEvent? = nil,
        source: CoTSource?,
        server: Bool = true,
        mesh: Bool = true,
        enabled: Bool = true
    ) -> MeshServerRelay.RelayInputs {
        MeshServerRelay.RelayInputs(
            event: e ?? event(),
            source: source,
            serverConnected: server,
            meshConnected: mesh,
            enabled: enabled
        )
    }

    /// Every transport a CoT can be tagged with, plus the untagged case.
    private var allSources: [CoTSource?] {
        [.mesh("Meshtastic"), .mesh("MeshCore"), .takServer("HQ"), .local,
         CoTSource(transport: .other, detail: "Plugin"), nil]
    }

    // MARK: - 1. Loop prevention (safety critical)

    func testMeshOriginRelaysUpToServerOnly() {
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(source: .mesh("Meshtastic"))), .toServer,
            "a CoT heard on the mesh belongs on the server picture, and only there")
    }

    func testServerOriginRelaysDownToMeshOnly() {
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(source: .takServer("HQ"))), .toMesh,
            "a relayable CoT from the server belongs on the mesh, and only there")
    }

    func testMeshOriginIsNeverRelayedBackToMesh() {
        // The loop that matters. Sweep every mesh framework and every allowlisted
        // type: none of them may ever produce .toMesh.
        for framework in ["Meshtastic", "MeshCore", "", "Unknown"] {
            for type in ["a-f-G-U-C", "a-h-G", "b-t-f", "b-m-p-w", "b-m-p-s-p-i", "t-x-c-t"] {
                let target = MeshServerRelay.relayTarget(
                    inputs(event(type: type), source: .mesh(framework)))
                XCTAssertNotEqual(target, .toMesh,
                    "mesh-origin \(type) via \(framework) must never be echoed back onto the mesh")
            }
        }
    }

    func testServerOriginIsNeverRelayedBackToServer() {
        for type in ["a-f-G-U-C", "a-h-G", "b-t-f", "b-m-p-w", "t-x-c-t", "b-f-t-r"] {
            let target = MeshServerRelay.relayTarget(
                inputs(event(type: type), source: .takServer("HQ")))
            XCTAssertNotEqual(target, .toServer,
                "server-origin \(type) must never be echoed back to the server")
        }
    }

    func testNoSourceEverRelaysToItsOwnTransport() {
        // Exhaustive invariant across every source × type the app can produce.
        for source in allSources {
            for type in ["a-f-G-U-C", "b-t-f", "b-m-p-w", "t-x-c-t", "b-i-v", ""] {
                let target = MeshServerRelay.relayTarget(
                    inputs(event(type: type), source: source))
                switch source?.transport {
                case .mesh:
                    XCTAssertNotEqual(target, .toMesh, "mesh → mesh loop for \(type)")
                case .takServer:
                    XCTAssertNotEqual(target, .toServer, "server → server loop for \(type)")
                default:
                    XCTAssertEqual(target, .none,
                        "an event with no reasoned-about origin (\(String(describing: source?.transport))) must not relay")
                }
            }
        }
    }

    func testUntaggedEventNeverRelays() {
        XCTAssertEqual(MeshServerRelay.relayTarget(inputs(source: nil)), .none,
            "an untagged CoT has no origin to reason about — refusing is the loop-safe default")
    }

    func testLocalOriginNeverRelays() {
        XCTAssertEqual(MeshServerRelay.relayTarget(inputs(source: .local)), .none,
            "device-local points already have their own broadcast paths; relaying them double-sends")
    }

    func testOtherOriginNeverRelays() {
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(source: CoTSource(transport: .other, detail: "Plugin"))),
            .none,
            "a plugin/unknown transport is not a gateway end — it must not be bridged blind")
    }

    // MARK: - 2. Off by default, and both ends required

    func testGatewayOffByDefaultInUserDefaults() {
        let defaults = UserDefaults(suiteName: "MeshServerRelayTests.default")!
        defaults.removePersistentDomain(forName: "MeshServerRelayTests.default")
        XCTAssertNil(defaults.object(forKey: MeshServerRelay.enabledDefaultsKey),
            "the gateway key must be genuinely unset on a fresh install")
        XCTAssertFalse(MeshServerRelay.isEnabled(in: defaults),
            "gateway mode must be OFF until an operator makes that call deliberately")
    }

    func testDisabledRelaysNothingRegardlessOfSource() {
        for source in allSources {
            XCTAssertEqual(
                MeshServerRelay.relayTarget(inputs(source: source, enabled: false)), .none,
                "the toggle vetoes every relay, whatever the source")
        }
    }

    func testServerDownRelaysNothing() {
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(source: .mesh("Meshtastic"), server: false)), .none)
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(source: .takServer("HQ"), server: false)), .none)
    }

    func testMeshDownRelaysNothing() {
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(source: .mesh("Meshtastic"), mesh: false)), .none)
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(source: .takServer("HQ"), mesh: false)), .none)
    }

    func testBothEndsDownRelaysNothing() {
        XCTAssertEqual(
            MeshServerRelay.relayTarget(
                inputs(source: .mesh("Meshtastic"), server: false, mesh: false)),
            .none)
    }

    // MARK: - 3. Type allowlist

    func testAllowlistAdmitsTheOperationalPicture() {
        for type in ["a-f-G-U-C", "a-h-G-U-C-I", "a-n-G", "a-u-A-M-F",
                     "b-t-f", "b-m-p-w", "b-m-p-s-p-i", "b-m-p-c"] {
            XCTAssertTrue(MeshServerRelay.isRelayableToMesh(type),
                "\(type) is the picture a mesh-only operator needs")
        }
    }

    func testAllowlistRejectsChatterAndControlTraffic() {
        for type in ["t-x-c-t", "t-x-d-d", "t-x-takp-q", "t-x-takp-v", "t-x-m-c",
                     "b-f-t-r", "b-f-t-a", "b-i-v", "b-a-o-tbl", "c-c-x", "y-c-r"] {
            XCTAssertFalse(MeshServerRelay.isRelayableToMesh(type),
                "\(type) is control/bulk traffic — it must not cost LoRa airtime")
        }
    }

    func testAllowlistRejectsCredentialAndEnrollmentBearingTypes() {
        // Mission-package announcements and TAK protocol negotiation can carry
        // download URLs, tokens and enrollment material. They are excluded by
        // construction (not enumerated in a denylist), and this pins it.
        for type in ["b-f-t-r", "b-f-t-a", "b-f-t-f", "t-x-takp-q", "t-x-takp-v",
                     "t-x-takp-p", "b-t-f-s", "b-t-f-d"] {
            XCTAssertFalse(MeshServerRelay.isRelayableToMesh(type),
                "\(type) can carry credential/enrollment material — it must never cross to the mesh")
        }
    }

    func testAllowlistIsPrefixAnchoredNotSubstring() {
        for type in ["", "a", "x-a-f-G", "zb-t-f", "xb-m-p-w", "unknown"] {
            XCTAssertFalse(MeshServerRelay.isRelayableToMesh(type),
                "\(type) must not sneak past the allowlist on a substring match")
        }
    }

    func testUnknownFutureTypeDefaultsToNotRelaying() {
        XCTAssertFalse(MeshServerRelay.isRelayableToMesh("z-future-sensor-feed"),
            "an allowlist means a type nobody has considered yet defaults to OFF")
        XCTAssertEqual(
            MeshServerRelay.relayTarget(
                inputs(event(type: "z-future-sensor-feed"), source: .takServer("HQ"))),
            .none)
    }

    func testNonAllowlistedServerEventStillNeverGoesToServer() {
        // A dropped server→mesh relay must be a drop, not a fallback to .toServer.
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(event(type: "t-x-c-t"), source: .takServer("HQ"))),
            .none)
    }

    func testMeshOriginIsNotFilteredByTheMeshAllowlist() {
        // The allowlist protects the LoRa channel only. Anything heard on the
        // mesh is already paid for in airtime; IP uplink is cheap, so it goes up
        // whatever its type.
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(event(type: "t-x-c-t"), source: .mesh("Meshtastic"))),
            .toServer)
    }

    // MARK: - 4. Per-uid throttle, and its bound

    func testFirstForwardOfAUidIsAlwaysAdmitted() {
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        XCTAssertTrue(relay.admitForward(uid: "U1", target: .toMesh, now: t0))
        XCTAssertTrue(relay.admitForward(uid: "U2", target: .toServer, now: t0))
    }

    func testServerToMeshThrottleSuppressesRepeatsInsideTheWindow() {
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        XCTAssertTrue(relay.admitForward(uid: "U1", target: .toMesh, now: t0))
        XCTAssertFalse(
            relay.admitForward(uid: "U1", target: .toMesh,
                               now: t0.addingTimeInterval(MeshServerRelay.serverToMeshThrottle - 1)),
            "a chatty server must not push the same uid onto LoRa twice inside the window")
    }

    func testServerToMeshThrottleReleasesAfterTheWindow() {
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        XCTAssertTrue(relay.admitForward(uid: "U1", target: .toMesh, now: t0))
        XCTAssertTrue(
            relay.admitForward(uid: "U1", target: .toMesh,
                               now: t0.addingTimeInterval(MeshServerRelay.serverToMeshThrottle)),
            "at exactly one window the uid is due again (>=)")
    }

    func testMeshToServerUsesTheShorterEchoWindow() {
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        XCTAssertTrue(relay.admitForward(uid: "U1", target: .toServer, now: t0))
        XCTAssertFalse(
            relay.admitForward(uid: "U1", target: .toServer,
                               now: t0.addingTimeInterval(MeshServerRelay.meshToServerDedupWindow - 1)))
        XCTAssertTrue(
            relay.admitForward(uid: "U1", target: .toServer,
                               now: t0.addingTimeInterval(MeshServerRelay.meshToServerDedupWindow)),
            "IP uplink is cheap — mesh→server only needs to swallow the ping-pong echo")
    }

    func testMeshToServerWindowIsShorterThanServerToMesh() {
        XCTAssertLessThan(MeshServerRelay.meshToServerDedupWindow,
                          MeshServerRelay.serverToMeshThrottle,
                          "the constrained side must be throttled harder than the cheap side")
        XCTAssertGreaterThanOrEqual(MeshServerRelay.serverToMeshThrottle, 30,
            "server→mesh must be at least as slow as a local marker drop (LoRa duty cycle)")
    }

    func testThrottleIsKeyedPerTargetNotJustPerUid() {
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        XCTAssertTrue(relay.admitForward(uid: "SAME", target: .toMesh, now: t0))
        XCTAssertTrue(relay.admitForward(uid: "SAME", target: .toServer, now: t0),
            "the two directions are independent budgets — one must not starve the other")
    }

    func testNoneTargetIsNeverAdmitted() {
        let relay = MeshServerRelay()
        XCTAssertFalse(relay.admitForward(uid: "U1", target: .none,
                                          now: Date(timeIntervalSince1970: 1_714_000_000)))
        XCTAssertEqual(relay.throttleEntryCount, 0,
            "a dropped event must not consume a throttle slot")
    }

    func testThrottleMapIsBoundedUnderUidFlood() {
        // The scalability property: a TAK server with thousands of contacts (or
        // a hostile one minting uids) must not grow this map without limit.
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        for i in 0..<(MeshServerRelay.maxThrottleEntries * 4) {
            _ = relay.admitForward(uid: "FLOOD-\(i)", target: .toMesh, now: t0)
        }
        XCTAssertLessThanOrEqual(relay.throttleEntryCount, MeshServerRelay.maxThrottleEntries,
            "throttle map must stay bounded — an unbounded uid dictionary is a memory leak")
        XCTAssertGreaterThan(relay.throttleEntryCount, 0,
            "eviction must not empty the map on every insert (that would defeat throttling)")
    }

    func testEvictionDropsStaleEntriesFirst() {
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        for i in 0..<MeshServerRelay.maxThrottleEntries {
            _ = relay.admitForward(uid: "OLD-\(i)", target: .toMesh, now: t0)
        }
        // One window later every OLD-* entry can no longer suppress anything.
        let later = t0.addingTimeInterval(MeshServerRelay.serverToMeshThrottle + 1)
        XCTAssertTrue(relay.admitForward(uid: "FRESH", target: .toMesh, now: later))
        XCTAssertEqual(relay.throttleEntryCount, 1,
            "entries past their window are dead weight and must be swept before anything live")
    }

    func testEvictionKeepsRecentEntriesThrottled() {
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        // A flood of older uids, then the one we care about at the newest instant.
        for i in 0..<(MeshServerRelay.maxThrottleEntries * 2) {
            _ = relay.admitForward(uid: "FLOOD-\(i)", target: .toMesh, now: t0)
        }
        let t1 = t0.addingTimeInterval(1)
        XCTAssertTrue(relay.admitForward(uid: "LIVE", target: .toMesh, now: t1))
        XCTAssertFalse(relay.admitForward(uid: "LIVE", target: .toMesh, now: t1.addingTimeInterval(1)),
            "LRU eviction must sacrifice the stalest uids, not the one actively transmitting")
    }

    func testResetClearsThrottleState() {
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        XCTAssertTrue(relay.admitForward(uid: "U1", target: .toMesh, now: t0))
        relay.reset()
        XCTAssertEqual(relay.throttleEntryCount, 0)
        XCTAssertTrue(relay.admitForward(uid: "U1", target: .toMesh, now: t0),
            "a transport teardown/reconnect starts the budget clean")
    }

    // MARK: - 5. mesh → server XML rebuild

    func testRelayXMLRoundTripsThroughTheServerParser() {
        let e = event(uid: "mesh-deadbeef", type: "a-n-G-U-C", callsign: "MESH-7")
        let xml = MeshServerRelay.relayXML(for: e)
        guard case .positionUpdate(let parsed)? = CoTMessageParser.parse(xml: xml) else {
            return XCTFail("relayed mesh CoT must parse back as a position update on the server side")
        }
        XCTAssertEqual(parsed.uid, "mesh-deadbeef", "uid must survive so the server dedups correctly")
        XCTAssertEqual(parsed.type, "a-n-G-U-C")
        XCTAssertEqual(parsed.point.lat, 47.6062, accuracy: 1e-6)
        XCTAssertEqual(parsed.point.lon, -122.3321, accuracy: 1e-6)
        XCTAssertEqual(parsed.detail.callsign, "MESH-7",
            "the mesh node's callsign is how it shows up on the server picture")
    }

    func testRelayXMLEscapesAttackerControlledCallsign() {
        // Any radio on the channel picks its own callsign. Unescaped, that is an
        // injection straight into the TAK server's CoT stream.
        let e = event(uid: "mesh-1", callsign: "EVIL\"/><event uid=\"pwned\"><point lat=\"0\"")
        let xml = MeshServerRelay.relayXML(for: e)
        XCTAssertFalse(xml.contains("<event uid=\"pwned\""),
            "a hostile mesh callsign must not inject a second <event> into the server stream")
        XCTAssertTrue(xml.contains("&quot;"), "the quote in the callsign must be entity-escaped")
        XCTAssertEqual(xml.components(separatedBy: "<event ").count - 1, 1,
            "exactly one <event> element may leave the gateway per relayed CoT")
    }

    func testRelayXMLEscapesAttackerControlledUID() {
        let e = event(uid: "mesh-<&\"'>", callsign: "OK")
        let xml = MeshServerRelay.relayXML(for: e)
        XCTAssertFalse(xml.contains("uid=\"mesh-<&\"'>\""),
            "a hostile uid must be escaped, not pasted raw into the attribute")
        XCTAssertEqual(xml.components(separatedBy: "<event ").count - 1, 1)
    }

    func testRelayXMLCarriesGatewayProvenance() {
        // An operator staring at the server picture has to be able to tell which
        // contacts arrived through somebody's handheld gateway rather than
        // directly. Without it the bridge is invisible, which is the OPSEC
        // failure mode.
        let xml = MeshServerRelay.relayXML(for: event())
        XCTAssertTrue(xml.contains("OmniTAK-Gateway"),
            "relayed CoT must be attributable to the gateway that injected it")
    }

    // MARK: - 6. The hot path is not main-actor bound

    func testDecisionAndThrottleRunOffTheMainThread() {
        // Compile-time as much as runtime: if anyone marks these @MainActor the
        // relay starts hopping the main queue per inbound CoT on a busy server.
        let relay = MeshServerRelay()
        let done = expectation(description: "relay decision off main")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            let target = MeshServerRelay.relayTarget(
                MeshServerRelay.RelayInputs(
                    event: self.event(), source: .mesh("Meshtastic"),
                    serverConnected: true, meshConnected: true, enabled: true))
            XCTAssertEqual(target, .toServer)
            XCTAssertTrue(relay.admitForward(uid: "U1", target: target,
                                             now: Date(timeIntervalSince1970: 1_714_000_000)))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testThrottleStateIsSafeUnderConcurrentInbound() {
        // Server read loop and mesh frame handler both feed the relay. Racing
        // them under TSan is what catches an unguarded dictionary.
        let relay = MeshServerRelay()
        let t0 = Date(timeIntervalSince1970: 1_714_000_000)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            _ = relay.admitForward(uid: "RACE-\(i % 50)", target: i % 2 == 0 ? .toMesh : .toServer,
                                   now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertLessThanOrEqual(relay.throttleEntryCount, MeshServerRelay.maxThrottleEntries)
    }

    // MARK: - 7. Transport layer — the same loop invariant, through the sends

    func testOnInboundMeshEventGoesUpAndNeverBackDown() {
        let up = expectation(description: "relayed up to the server")
        let down = expectation(description: "must never go back onto the mesh")
        down.isInverted = true
        let relay = MeshServerRelay(
            sendToServer: { xml in
                XCTAssertTrue(xml.contains("MESH-1"), "the relayed XML must carry the mesh node's uid")
                up.fulfill()
                return true
            },
            sendToMesh: { _ in down.fulfill() }
        )
        relay.onInbound(event(), source: .mesh("Meshtastic"),
                        serverConnected: true, meshConnected: true, enabled: true)
        wait(for: [up, down], timeout: 2)
    }

    func testOnInboundServerEventGoesDownAndNeverBackUp() {
        let down = expectation(description: "relayed down to the mesh")
        let up = expectation(description: "must never go back to the server")
        up.isInverted = true
        let relay = MeshServerRelay(
            sendToServer: { _ in up.fulfill(); return true },
            sendToMesh: { e in
                XCTAssertEqual(e.uid, "MESH-1")
                down.fulfill()
            }
        )
        relay.onInbound(event(), source: .takServer("HQ"),
                        serverConnected: true, meshConnected: true, enabled: true)
        wait(for: [down, up], timeout: 2)
    }

    func testOnInboundSendsNothingWhenGatewayDisabled() {
        let anySend = expectation(description: "a disabled gateway must not transmit anything")
        anySend.isInverted = true
        let relay = MeshServerRelay(
            sendToServer: { _ in anySend.fulfill(); return true },
            sendToMesh: { _ in anySend.fulfill() }
        )
        relay.onInbound(event(), source: .mesh("Meshtastic"),
                        serverConnected: true, meshConnected: true, enabled: false)
        relay.onInbound(event(), source: .takServer("HQ"),
                        serverConnected: true, meshConnected: true, enabled: false)
        wait(for: [anySend], timeout: 1)
    }

    func testOnInboundThrottlesRepeatsOfTheSameUidToTheMesh() {
        let first = expectation(description: "first server→mesh relay")
        let second = expectation(description: "the immediate repeat must be throttled")
        second.isInverted = true
        var seen = 0
        let gate = NSLock()
        let relay = MeshServerRelay(
            sendToMesh: { _ in
                gate.lock(); seen += 1; let n = seen; gate.unlock()
                n == 1 ? first.fulfill() : second.fulfill()
            }
        )
        for _ in 0..<5 {
            relay.onInbound(event(), source: .takServer("HQ"),
                            serverConnected: true, meshConnected: true, enabled: true)
        }
        wait(for: [first, second], timeout: 2)
    }

    // MARK: - 8. Ingest tagging — the precondition the whole loop guard rests on

    func testUntaggedIngestResolvesToTheServer() {
        // This is *why* every mesh ingest point has to tag explicitly: the
        // fallback assumes a server, so an untagged mesh packet would be handed
        // to the relay as server-origin and pushed straight back onto the mesh.
        XCTAssertEqual(
            CoTEventHandler.resolveSource(explicit: nil, existing: nil, serverName: "HQ"),
            .takServer("HQ"))
    }

    func testExplicitTagWinsOverTheServerFallback() {
        XCTAssertEqual(
            CoTEventHandler.resolveSource(explicit: .mesh("Meshtastic"), existing: nil, serverName: "HQ"),
            .mesh("Meshtastic"))
        XCTAssertEqual(
            CoTEventHandler.resolveSource(explicit: .mesh("Meshtastic"),
                                          existing: .takServer("HQ"), serverName: "HQ"),
            .mesh("Meshtastic"),
            "the ingest point knows the transport better than any tag already on the event")
    }

    func testAlreadyTaggedEventKeepsItsTransport() {
        XCTAssertEqual(
            CoTEventHandler.resolveSource(explicit: nil, existing: .mesh("MeshCore"), serverName: "HQ"),
            .mesh("MeshCore"))
    }

    func testMeshtasticRadioTagIsAMeshTransport() {
        XCTAssertEqual(CoTSource.meshtasticRadio.transport, .mesh)
        XCTAssertEqual(
            MeshServerRelay.relayTarget(inputs(source: .meshtasticRadio)), .toServer,
            "every Meshtastic radio ingest point tags with this constant — the day it stops "
            + "being .mesh, radio traffic starts looping back onto the channel")
    }
}
