//
//  MeshtasticSettingsControlsTests.swift
//  OmniTAKMobileTests
//
//  #148: what the Device and Position controls start at and what Apply writes
//  from them. The controls are a plain value (MeshtasticSettingsControls), so
//  the rules are tested without a view. The screen used to start its pickers at
//  a role and a rebroadcast mode of its own (TAK, All) and a fixed interval, so
//  Apply could change settings the operator never looked at; a test here fails
//  if a fixed default comes back.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

final class MeshtasticSettingsControlsTests: XCTestCase {

    private typealias Controls = MeshtasticSettingsControls

    private func radio(
        device: ProtoFixture?,
        position: ProtoFixture? = nil
    ) -> MeshtasticRadioSettings {
        var settings = MeshtasticRadioSettings()
        settings.apply(.downloadStarted(nodeNum: 0x0A0B_0C0D))
        if let device { settings.apply(.config(variant: RadioProto.Config.device, body: device.data)) }
        if let position { settings.apply(.config(variant: RadioProto.Config.position, body: position.data)) }
        return settings
    }

    // MARK: - Starting at the radio's values

    func testAFactoryRadioStartsAtClientAndAllAndItsOwnInterval() {
        let factory = radio(device: RadioFixtures.factoryDeviceConfig(),
                            position: RadioFixtures.factoryPositionConfig(broadcastSecs: 900))
        let controls = Controls(radio: factory)
        XCTAssertEqual(controls.role, .client, "the role the radio has, not a role of the screen's own")
        XCTAssertEqual(controls.rebroadcast, .all)
        XCTAssertEqual(controls.sliderValue(radio: factory), 900)
        XCTAssertEqual(controls.intervalLabel(radio: factory), "900s")
        XCTAssertNil(controls.intervalToWrite(), "nothing chosen, nothing to write")
    }

    func testARadioWithOtherValuesStartsAtThose() {
        let device = RadioFixtures.deviceConfig()
            .varint(RadioProto.Device.role, RadioProto.DeviceRole.router)
            .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.knownOnly)
        let settings = radio(device: device, position: RadioFixtures.positionConfig(broadcastSecs: 1800))
        let controls = Controls(radio: settings)
        XCTAssertEqual(controls.role, .router)
        XCTAssertEqual(controls.rebroadcast, .knownOnly)
        XCTAssertEqual(controls.sliderValue(radio: settings), 1800)
    }

    func testTheControlsAreNeverTAKUnlessTheRadioIs() {
        // A screen that started at TAK would have written TAK to every radio.
        for device in [RadioFixtures.factoryDeviceConfig(), RadioFixtures.deviceConfig()] {
            XCTAssertNotEqual(Controls(radio: radio(device: device)).role, .tak)
        }
        let tak = RadioFixtures.deviceConfig().varint(RadioProto.Device.role, RadioProto.DeviceRole.tak)
        XCTAssertEqual(Controls(radio: radio(device: tak)).role, .tak)
    }

    func testBeforeTheRadioHasReportedTheControlsHoldNothing() {
        let controls = Controls(radio: radio(device: nil))
        XCTAssertNil(controls.role)
        XCTAssertNil(controls.rebroadcast)
        XCTAssertEqual(Controls().role, nil)
        XCTAssertEqual(controls.intervalLabel(radio: radio(device: nil)), "Not loaded")
    }

    func testARoleOrModeTheAppHasNoNameForLeavesTheControlEmpty() {
        let device = ProtoFixture()
            .varint(RadioProto.Device.role, 12)
            .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.coreOnly)
        let settings = radio(device: device)
        let controls = Controls(radio: settings)
        XCTAssertNil(controls.role, "no named role stands in for role 12")
        XCTAssertNil(controls.rebroadcast)
        XCTAssertEqual(settings.unlistedDeviceRole, 12)
        XCTAssertEqual(settings.unlistedRebroadcastMode, 5)
    }

    func testAnIntervalOfZeroIsTheRadiosDefaultAndIsShownAsSuch() {
        let settings = radio(device: RadioFixtures.factoryDeviceConfig(),
                             position: ProtoFixture().varint(RadioProto.Position.gpsMode, 1))
        let controls = Controls(radio: settings)
        XCTAssertEqual(controls.intervalLabel(radio: settings), "radio default")
        XCTAssertNil(controls.intervalToWrite(), "and it is not written unless the operator moves the slider")
        XCTAssertEqual(controls.sliderValue(radio: settings), 30, "held at the slider's end")
    }

    func testTheIntervalIsShownInSeconds() {
        let settings = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.positionConfig(broadcastSecs: 3600))
        XCTAssertEqual(Controls(radio: settings).intervalLabel(radio: settings), "3600s")
    }

    // MARK: - What Apply writes

    func testApplyWritesNothingForControlsLeftAsTheyWere() {
        let settings = radio(device: RadioFixtures.factoryDeviceConfig())
        let edits = Controls(radio: settings).deviceEdits(against: settings)
        XCTAssertNil(edits.role)
        XCTAssertNil(edits.rebroadcast)
    }

    func testApplyWritesOnlyTheControlTheOperatorChanged() {
        let settings = radio(device: RadioFixtures.factoryDeviceConfig())
        var controls = Controls(radio: settings)

        controls.rebroadcast = .localOnly
        var edits = controls.deviceEdits(against: settings)
        XCTAssertNil(edits.role, "the role control stands at the radio's role: not written")
        XCTAssertEqual(edits.rebroadcast, .localOnly)

        controls.rebroadcast = .all
        controls.role = .router
        edits = controls.deviceEdits(against: settings)
        XCTAssertEqual(edits.role, .router)
        XCTAssertNil(edits.rebroadcast)
    }

    func testApplyLeavesAnUnlistedRoleAloneUnlessAnotherIsPicked() {
        let device = ProtoFixture().varint(RadioProto.Device.role, 12)
        let settings = radio(device: device)
        var controls = Controls(radio: settings)

        controls.rebroadcast = .knownOnly
        XCTAssertNil(controls.deviceEdits(against: settings).role, "role 12 is not touched")

        controls.role = .tracker
        XCTAssertEqual(controls.deviceEdits(against: settings).role, .tracker, "unless the operator picks one")
    }

    func testTheIntervalAppliedIsWhatTheOperatorMovedTheSliderTo() {
        let settings = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig(broadcastSecs: 900))
        var controls = Controls(radio: settings)
        XCTAssertNil(controls.intervalToWrite())

        controls.sliderMoved(to: 1830, radio: settings)
        XCTAssertEqual(controls.intervalToWrite(), 1830)
        XCTAssertEqual(controls.intervalLabel(radio: settings), "1830s")

        controls.sliderMoved(to: -5, radio: settings)
        XCTAssertEqual(controls.intervalToWrite(), 30, "never below the slider's range, never a negative number into a UInt32")
        controls.sliderMoved(to: .infinity, radio: settings)
        XCTAssertEqual(controls.intervalToWrite(), 30, "not finite: ignored")
        controls.sliderMoved(to: 1e12, radio: settings)
        XCTAssertEqual(controls.intervalToWrite(), 3600, "held within the range")
    }

    func testASliderThatReportsWhatItAlreadyShowsHasNotBeenMoved() {
        let settings = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig(broadcastSecs: 900))
        var controls = Controls(radio: settings)

        // A slider that reports its own value back, as one that snaps does.
        controls.sliderMoved(to: controls.sliderValue(radio: settings), radio: settings)

        XCTAssertNil(controls.intervalToWrite())
    }

    // MARK: - A radio's interval outside the slider

    func testARadioIntervalAboveTheSliderIsShownAsItIsAndIsNotWrittenUnlessTheSliderMoves() {
        // A TAK radio has a day.
        let settings = radio(device: RadioFixtures.deviceConfig().varint(RadioProto.Device.role, RadioProto.DeviceRole.tak),
                             position: RadioFixtures.positionConfig(broadcastSecs: 86_400))
        var controls = Controls(radio: settings)

        XCTAssertEqual(controls.intervalLabel(radio: settings), "86400s", "the real value, not the one the slider can reach")
        XCTAssertEqual(controls.sliderValue(radio: settings), 3600, "the slider rests at its end")
        XCTAssertTrue(controls.intervalOutsideSlider(radio: settings))
        XCTAssertNil(controls.intervalToWrite(), "what the slider shows for a value it cannot reach is not written")

        // The slider reports its end, as a slider with a value outside its
        // range may: that is not the operator moving it.
        controls.sliderMoved(to: 3600, radio: settings)
        XCTAssertNil(controls.intervalToWrite())
        XCTAssertEqual(controls.intervalLabel(radio: settings), "86400s")

        // Moving it is a choice.
        controls.sliderMoved(to: 3570, radio: settings)
        XCTAssertEqual(controls.intervalToWrite(), 3570)
        XCTAssertEqual(controls.intervalLabel(radio: settings), "3570s")
        XCTAssertFalse(controls.intervalOutsideSlider(radio: settings))
    }

    func testARadioIntervalBelowTheSliderIsAlsoShownAsItIsAndLeftAlone() {
        let settings = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig(broadcastSecs: 10))
        let controls = Controls(radio: settings)
        XCTAssertEqual(controls.intervalLabel(radio: settings), "10s")
        XCTAssertEqual(controls.sliderValue(radio: settings), 30)
        XCTAssertTrue(controls.intervalOutsideSlider(radio: settings))
        XCTAssertNil(controls.intervalToWrite())
    }

    func testAnIntervalOffTheSlidersStepsGetsAFinerStepSoItIsNotSnapped() {
        let onTheGrid = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig(broadcastSecs: 900))
        XCTAssertEqual(Controls(radio: onTheGrid).sliderStep(radio: onTheGrid), 30)
        let offTheGrid = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig(broadcastSecs: 1000))
        let controls = Controls(radio: offTheGrid)
        XCTAssertEqual(controls.sliderStep(radio: offTheGrid), 1)
        XCTAssertEqual(controls.sliderValue(radio: offTheGrid), 1000)
        XCTAssertNil(controls.intervalToWrite())
    }

    func testAnIntervalTheRadioChangedStartsTheSliderOver() {
        let first = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig(broadcastSecs: 900))
        var controls = Controls(radio: first)
        controls.sliderMoved(to: 1800, radio: first)
        XCTAssertEqual(controls.intervalToWrite(), 1800)

        let after = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig(broadcastSecs: 1800))
        controls.seed(from: after)

        XCTAssertNil(controls.intervalToWrite(), "the radio has it now: nothing left to write")
        XCTAssertEqual(controls.intervalLabel(radio: after), "1800s")
    }

    // MARK: - Showing the screen again

    func testSeedingAgainForTheSameRadioKeepsTheOperatorsChoices() {
        let settings = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig(broadcastSecs: 900))
        var controls = Controls(radio: settings)
        controls.role = .router
        controls.rebroadcast = .knownOnly
        controls.sliderMoved(to: 1800, radio: settings)

        // A pushed picker pops back and the form appears again.
        controls.seed(from: settings)

        XCTAssertEqual(controls.role, .router)
        XCTAssertEqual(controls.rebroadcast, .knownOnly)
        XCTAssertEqual(controls.intervalToWrite(), 1800)
    }

    func testSeedingKeepsTheChoicesWhenOnlyChannelsChange() {
        var settings = radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig())
        var controls = Controls(radio: settings)
        controls.role = .tracker

        settings.apply(.channel(index: 1, body: RadioFixtures.channel(index: 1).data))
        controls.seed(from: settings)

        XCTAssertEqual(controls.role, .tracker, "a channel arriving does not undo a role choice")
    }

    func testANewDownloadWithOtherValuesStartsTheControlsOver() {
        var controls = Controls(radio: radio(device: RadioFixtures.factoryDeviceConfig(), position: RadioFixtures.factoryPositionConfig(broadcastSecs: 900)))
        controls.role = .router

        let other = RadioFixtures.deviceConfig().varint(RadioProto.Device.role, RadioProto.DeviceRole.tak)
        let after = radio(device: other, position: RadioFixtures.positionConfig(broadcastSecs: 600))
        controls.seed(from: after)

        XCTAssertEqual(controls.role, .tak)
        XCTAssertEqual(controls.sliderValue(radio: after), 600)
    }

    func testControlsStartOverWhenTheRadioTheyWereFromIsGone() {
        var controls = Controls(radio: radio(device: RadioFixtures.factoryDeviceConfig()))
        XCTAssertEqual(controls.role, .client)

        controls.seed(from: MeshtasticRadioSettings())

        XCTAssertNil(controls.role)
        XCTAssertNil(controls.rebroadcast)
    }

    func testTheControlsOfARadioThatLoadsLaterStartThenAndNotBefore() {
        var controls = Controls()
        let empty = radio(device: nil)
        controls.seed(from: empty)
        XCTAssertNil(controls.role)

        controls.seed(from: radio(device: RadioFixtures.deviceConfig().varint(RadioProto.Device.role, RadioProto.DeviceRole.router)))
        XCTAssertEqual(controls.role, .router)
    }
}
