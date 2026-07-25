import XCTest
@testable import GuardCore

/// In-memory AudioSystem fake with a mutable world model.
final class FakeAudioSystem: AudioSystem {
    var onChange: (() -> Void)?
    var devices: [AudioDeviceInfo] = []
    var defaultInput: String?
    var defaultOutput: String?
    var rates: [String: Double] = [:]
    var maxRates: [String: Double] = [:]
    var running: Set<String> = []
    private(set) var watched: [String] = []
    private(set) var setInputCalls: [String] = []
    private(set) var setRateCalls: [(String, Double)] = []

    func snapshotDevices() -> [AudioDeviceInfo] { devices }
    func defaultInputUID() -> String? { defaultInput }
    func defaultOutputUID() -> String? { defaultOutput }
    func setDefaultInput(uid: String) -> Bool {
        setInputCalls.append(uid)
        guard devices.contains(where: { $0.uid == uid && $0.isAlive }) else { return false }
        defaultInput = uid
        return true
    }
    func nominalRate(uid: String) -> Double? { rates[uid] }
    func maxAvailableRate(uid: String) -> Double? { maxRates[uid] }
    func setNominalRate(uid: String, rate: Double) -> Bool {
        setRateCalls.append((uid, rate))
        rates[uid] = rate
        return true
    }
    func isRunningSomewhere(uid: String) -> Bool { running.contains(uid) }
    func watchDevices(uids: [String]) { watched = uids }
    func start() {}
    func stop() {}

    func fireChange() { onChange?() }
}

final class MemoryStore: GuardStateStore {
    var value: String?
    func loadLastGoodInputUID() -> String? { value }
    func saveLastGoodInputUID(_ uid: String?) { value = uid }
}

final class GuardEngineTests: XCTestCase {
    var audio: FakeAudioSystem!
    var store: MemoryStore!
    var engine: GuardEngine!

    let builtinMic = AudioDeviceInfo(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                     transport: "bltn", hasInput: true, hasOutput: false)
    let bmr1In  = AudioDeviceInfo(uid: "42-DA-EC-84-61-F5:input", name: "Drop-BMR1",
                                  transport: "blue", hasInput: true, hasOutput: false)
    let bmr1Out = AudioDeviceInfo(uid: "42-DA-EC-84-61-F5:output", name: "Drop-BMR1",
                                  transport: "blue", hasInput: false, hasOutput: true)
    let usbMic  = AudioDeviceInfo(uid: "USB-MIC-1", name: "Blue Yeti",
                                  transport: "usb ", hasInput: true, hasOutput: false)

    override func setUp() {
        super.setUp()
        audio = FakeAudioSystem()
        store = MemoryStore()
        audio.devices = [builtinMic, bmr1In, bmr1Out]
        audio.defaultInput = builtinMic.uid
        audio.defaultOutput = bmr1Out.uid
        audio.rates[bmr1Out.uid] = 44100
        audio.maxRates[bmr1Out.uid] = 44100
        engine = GuardEngine(audio: audio, store: store, sweepInterval: 3600)
        engine.start()
    }

    override func tearDown() {
        engine.stop()
        super.tearDown()
    }

    /// Run pending engine work by poking and syncing via status().
    private func settle() {
        engine.poke()
        _ = engine.status()
    }

    func testTakeoverIsRevertedAndPersisted() {
        settle()
        XCTAssertEqual(store.value, builtinMic.uid)

        audio.defaultInput = bmr1In.uid
        audio.fireChange()
        settle()
        XCTAssertEqual(audio.defaultInput, builtinMic.uid, "engine must revert takeover")
        XCTAssertEqual(engine.lastGoodInputUID, builtinMic.uid)
    }

    func testUserSwitchIsRespectedThenProtected() {
        settle()
        audio.devices.append(usbMic)
        audio.defaultInput = usbMic.uid
        audio.fireChange()
        settle()
        XCTAssertEqual(audio.defaultInput, usbMic.uid, "user switch must not be reverted")
        XCTAssertEqual(store.value, usbMic.uid)

        audio.defaultInput = bmr1In.uid
        audio.fireChange()
        settle()
        XCTAssertEqual(audio.defaultInput, usbMic.uid, "restore goes to the USB mic")
    }

    func testUSBDisappearsFallback() {
        audio.devices = [builtinMic, usbMic, bmr1In, bmr1Out]
        audio.defaultInput = usbMic.uid
        settle()
        XCTAssertEqual(store.value, usbMic.uid)

        // USB vanishes and macOS (worst case) points default at BMR1.
        audio.devices = [builtinMic, bmr1In, bmr1Out]
        audio.defaultInput = bmr1In.uid
        audio.fireChange()
        settle()
        XCTAssertEqual(audio.defaultInput, builtinMic.uid, "safe fallback expected")
    }

    func testHFPRateIsRestoredWhenIdle() {
        settle()
        audio.rates[bmr1Out.uid] = 16000
        audio.fireChange()
        settle()
        XCTAssertEqual(audio.rates[bmr1Out.uid], 44100)
    }

    func testHFPRateDeferredWhileBusyThenRestored() {
        settle()
        audio.rates[bmr1Out.uid] = 16000
        audio.running.insert(bmr1In.uid)
        audio.fireChange()
        settle()
        XCTAssertEqual(audio.rates[bmr1Out.uid], 16000, "must not fight an active SCO link")

        audio.running.remove(bmr1In.uid)
        audio.fireChange()
        settle()
        XCTAssertEqual(audio.rates[bmr1Out.uid], 44100, "restore once idle")
    }

    func testPausedEngineDoesNotEnforceButKeepsTracking() {
        settle()
        engine.setEnabled(false)
        audio.defaultInput = bmr1In.uid
        audio.fireChange()
        settle()
        XCTAssertEqual(audio.defaultInput, bmr1In.uid, "paused: no enforcement")

        engine.setEnabled(true)
        settle()
        XCTAssertEqual(audio.defaultInput, builtinMic.uid, "resume enforces immediately")
    }

    func testWatchListCoversGuardedEndpoints() {
        settle()
        XCTAssertTrue(audio.watched.contains(bmr1In.uid))
        XCTAssertTrue(audio.watched.contains(bmr1Out.uid))
        XCTAssertFalse(audio.watched.contains(builtinMic.uid))
    }

    func testPersistedLastGoodAdoptedOnStart() {
        let store2 = MemoryStore()
        store2.value = usbMic.uid
        let audio2 = FakeAudioSystem()
        audio2.devices = [builtinMic, usbMic, bmr1In, bmr1Out]
        audio2.defaultInput = bmr1In.uid   // takeover happened while app was not running
        audio2.rates[bmr1Out.uid] = 44100
        audio2.maxRates[bmr1Out.uid] = 44100
        let engine2 = GuardEngine(audio: audio2, store: store2, sweepInterval: 3600)
        engine2.start()
        _ = engine2.status()
        XCTAssertEqual(audio2.defaultInput, usbMic.uid, "startup sweep restores persisted last-good input")
        engine2.stop()
    }
}
