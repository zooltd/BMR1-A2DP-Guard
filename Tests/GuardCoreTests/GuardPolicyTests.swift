import XCTest
@testable import GuardCore

final class GuardPolicyTests: XCTestCase {

    // Device fixtures mirroring the real machine.
    let builtinMic = AudioDeviceInfo(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                     transport: "bltn", hasInput: true, hasOutput: false)
    let builtinSpk = AudioDeviceInfo(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                                     transport: "bltn", hasInput: false, hasOutput: true)
    let bmr1In  = AudioDeviceInfo(uid: "42-DA-EC-84-61-F5:input", name: "Drop-BMR1",
                                  transport: "blue", hasInput: true, hasOutput: false)
    let bmr1Out = AudioDeviceInfo(uid: "42-DA-EC-84-61-F5:output", name: "Drop-BMR1",
                                  transport: "blue", hasInput: false, hasOutput: true)
    let usbMic  = AudioDeviceInfo(uid: "USB-MIC-1", name: "Blue Yeti",
                                  transport: "usb ", hasInput: true, hasOutput: false)
    let airpodsIn = AudioDeviceInfo(uid: "AC-90-85-BD-76-02:input", name: "Youhan's AirPods",
                                    transport: "blue", hasInput: true, hasOutput: false)
    let teamsVirt = AudioDeviceInfo(uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio",
                                    transport: "virt", hasInput: true, hasOutput: true)

    func makePolicy(lastGood: String? = nil, restoreRate: Bool = true) -> GuardPolicy {
        GuardPolicy(config: GuardConfig(blockedBluetoothNames: ["Drop-BMR1"],
                                        restoreA2DPRate: restoreRate),
                    lastGoodInputUID: lastGood)
    }

    // MARK: Classification

    func testOnlyBMR1InputIsBlocked() {
        let p = makePolicy()
        XCTAssertTrue(p.isBlockedInput(bmr1In))
        XCTAssertFalse(p.isBlockedInput(builtinMic))
        XCTAssertFalse(p.isBlockedInput(usbMic))
        // Rule 8: other Bluetooth microphones are NOT blocked.
        XCTAssertFalse(p.isBlockedInput(airpodsIn))
        XCTAssertFalse(p.isBlockedInput(teamsVirt))
        // Output side of BMR1 is not an input block target but is guarded for rate.
        XCTAssertFalse(p.isBlockedInput(bmr1Out))
        XCTAssertTrue(p.isGuardedOutput(bmr1Out))
        XCTAssertFalse(p.isGuardedOutput(builtinSpk))
    }

    func testUIDBlockMatchesEvenIfRenamed() {
        let p = GuardPolicy(config: GuardConfig(blockedBluetoothNames: [],
                                                blockedInputUIDs: ["42-DA-EC-84-61-F5:input"]))
        var renamed = bmr1In
        renamed.name = "Living Room Speaker"
        XCTAssertTrue(p.isBlockedInput(renamed))
    }

    // MARK: Acceptance 1 & 6 — takeover is reverted to the tracked input

    func testTakeoverRestoresLastGood() {
        var p = makePolicy()
        let devices = [builtinMic, builtinSpk, bmr1In, bmr1Out]
        XCTAssertEqual(p.onDefaultInput(uid: builtinMic.uid, devices: devices), [])
        XCTAssertEqual(p.lastGoodInputUID, builtinMic.uid)

        let actions = p.onDefaultInput(uid: bmr1In.uid, devices: devices)
        guard case let .setDefaultInput(uid, _)? = actions.first else {
            return XCTFail("expected restore action, got \(actions)")
        }
        XCTAssertEqual(uid, builtinMic.uid)
        // BMR1 must never become the tracked input.
        XCTAssertEqual(p.lastGoodInputUID, builtinMic.uid)
    }

    // MARK: Acceptance 2 — switching to USB mic is learned

    func testUserSwitchToUSBIsLearnedAndPreserved() {
        var p = makePolicy()
        let devices = [builtinMic, usbMic, bmr1In, bmr1Out]
        _ = p.onDefaultInput(uid: builtinMic.uid, devices: devices)
        // User switches to USB mic: not an error, becomes tracked.
        XCTAssertEqual(p.onDefaultInput(uid: usbMic.uid, devices: devices), [])
        XCTAssertEqual(p.lastGoodInputUID, usbMic.uid)
        // Takeover now restores the USB mic, not the built-in.
        let actions = p.onDefaultInput(uid: bmr1In.uid, devices: devices)
        XCTAssertEqual(actions.count, 1)
        if case let .setDefaultInput(uid, _) = actions[0] { XCTAssertEqual(uid, usbMic.uid) }
    }

    // MARK: Acceptance 3 — USB unplugged, macOS picks an allowed device: accepted

    func testMacOSFallbackToAllowedDeviceIsAccepted() {
        var p = makePolicy(lastGood: usbMic.uid)
        // USB is gone; macOS made builtin default on its own.
        let devices = [builtinMic, builtinSpk, bmr1In, bmr1Out]
        XCTAssertEqual(p.onDefaultInput(uid: builtinMic.uid, devices: devices), [])
        XCTAssertEqual(p.lastGoodInputUID, builtinMic.uid)
    }

    // MARK: Acceptance 3 (worst case) — USB unplugged AND macOS picks BMR1

    func testFallbackWhenLastGoodGoneAndBlockedTakesOver() {
        var p = makePolicy(lastGood: usbMic.uid)
        let devices = [builtinMic, builtinSpk, bmr1In, bmr1Out] // USB absent
        let actions = p.onDefaultInput(uid: bmr1In.uid, devices: devices)
        XCTAssertEqual(actions.count, 1)
        if case let .setDefaultInput(uid, _) = actions[0] {
            XCTAssertEqual(uid, builtinMic.uid, "fallback should pick a safe non-BMR1 device")
        }
    }

    func testFallbackPicksAnyAllowedInputWhenNoBuiltin() {
        var p = makePolicy(lastGood: "GONE-DEVICE")
        let devices = [teamsVirt, bmr1In, bmr1Out] // no builtin present
        let actions = p.onDefaultInput(uid: bmr1In.uid, devices: devices)
        XCTAssertEqual(actions.count, 1)
        if case let .setDefaultInput(uid, _) = actions[0] { XCTAssertEqual(uid, teamsVirt.uid) }
    }

    func testNoActionWhenOnlyBlockedInputExists() {
        var p = makePolicy()
        let devices = [builtinSpk, bmr1In, bmr1Out] // no allowed inputs at all
        XCTAssertEqual(p.onDefaultInput(uid: bmr1In.uid, devices: devices), [])
    }

    // MARK: Acceptance 4 — reconnecting USB must not force a switch

    func testReconnectedUSBDoesNotForceSwitch() {
        var p = makePolicy()
        var devices = [builtinMic, bmr1In, bmr1Out]
        _ = p.onDefaultInput(uid: builtinMic.uid, devices: devices)
        // USB reappears; default is still builtin — policy must not act.
        devices.append(usbMic)
        XCTAssertEqual(p.onDefaultInput(uid: builtinMic.uid, devices: devices), [])
        XCTAssertEqual(p.lastGoodInputUID, builtinMic.uid)
    }

    // MARK: Acceptance 9 — other Bluetooth mics selectable intentionally

    func testOtherBluetoothMicSelectable() {
        var p = makePolicy()
        let devices = [builtinMic, airpodsIn, bmr1In, bmr1Out]
        XCTAssertEqual(p.onDefaultInput(uid: airpodsIn.uid, devices: devices), [])
        XCTAssertEqual(p.lastGoodInputUID, airpodsIn.uid)
        // And takeover restores the AirPods, not something else.
        let actions = p.onDefaultInput(uid: bmr1In.uid, devices: devices)
        if case let .setDefaultInput(uid, _)? = actions.first {
            XCTAssertEqual(uid, airpodsIn.uid)
        } else { XCTFail("expected restore") }
    }

    // MARK: Takeover storm — enforcement never gives up

    func testRepeatedTakeoversKeepEnforcing() {
        var p = makePolicy()
        let devices = [builtinMic, bmr1In, bmr1Out]
        _ = p.onDefaultInput(uid: builtinMic.uid, devices: devices)
        for _ in 0..<20 {
            let actions = p.onDefaultInput(uid: bmr1In.uid, devices: devices)
            XCTAssertEqual(actions.count, 1)
            _ = p.onDefaultInput(uid: builtinMic.uid, devices: devices)
        }
        XCTAssertEqual(p.lastGoodInputUID, builtinMic.uid)
    }

    // MARK: Acceptance 8 — output rate guard

    func testOutputRateRestoredWhenIdle() {
        let p = makePolicy()
        let actions = p.onGuardedOutputRate(currentRate: 16000, maxAvailableRate: 44100,
                                            outputUID: bmr1Out.uid, blockedInputBusy: false)
        XCTAssertEqual(actions, [.setNominalRate(uid: bmr1Out.uid, rate: 44100,
                                                 reason: "output at 16000 Hz (HFP); restoring A2DP 44100 Hz")])
    }

    func testOutputRateDeferredWhileBlockedInputBusy() {
        let p = makePolicy()
        // Someone is actively recording from BMR1's input (explicit selection):
        // do not fight the SCO link; recover after it stops.
        XCTAssertEqual(p.onGuardedOutputRate(currentRate: 16000, maxAvailableRate: 44100,
                                             outputUID: bmr1Out.uid, blockedInputBusy: true), [])
    }

    /// Rate forcing renegotiates the Bluetooth link and can wedge speaker
    /// firmware, so it must be opt-in — the default build must never write a
    /// sample rate.
    func testRateForcingIsOffByDefault() {
        let p = GuardPolicy(config: GuardConfig(blockedBluetoothNames: ["Drop-BMR1"]))
        XCTAssertFalse(p.config.restoreA2DPRate)
        XCTAssertEqual(p.onGuardedOutputRate(currentRate: 16000, maxAvailableRate: 44100,
                                             outputUID: bmr1Out.uid, blockedInputBusy: false), [],
                       "default configuration must not touch the sample rate")
    }

    /// Blocking the default input must keep working with rate forcing off —
    /// that is the mechanism that actually prevents HFP.
    func testInputBlockingStillWorksWithRateForcingOff() {
        var p = makePolicy(restoreRate: false)
        let devices = [builtinMic, bmr1In, bmr1Out]
        _ = p.onDefaultInput(uid: builtinMic.uid, devices: devices)
        let actions = p.onDefaultInput(uid: bmr1In.uid, devices: devices)
        XCTAssertEqual(actions.count, 1)
        if case let .setDefaultInput(uid, _) = actions[0] { XCTAssertEqual(uid, builtinMic.uid) }
    }

    func testOutputRateNoActionAtA2DP() {
        let p = makePolicy()
        XCTAssertEqual(p.onGuardedOutputRate(currentRate: 44100, maxAvailableRate: 44100,
                                             outputUID: bmr1Out.uid, blockedInputBusy: false), [])
    }

    // MARK: Persisted state

    func testAdoptPersistedLastGoodIgnoresBlockedUID() {
        var p = makePolicy()
        p.adoptPersistedLastGood(bmr1In.uid, devices: [builtinMic, bmr1In])
        XCTAssertNil(p.lastGoodInputUID)
        p.adoptPersistedLastGood(usbMic.uid, devices: [builtinMic, bmr1In]) // even if absent: adopted
        XCTAssertEqual(p.lastGoodInputUID, usbMic.uid)
    }
}
