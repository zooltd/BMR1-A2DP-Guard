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
    /// Proxy for "how much work did the engine do" — one per sweep.
    private(set) var snapshotCount = 0
    /// Counts only calls that actually change the watch set (i.e. listener re-arms).
    private(set) var watchChangeCount = 0

    private let lock = NSLock()

    func snapshotDevices() -> [AudioDeviceInfo] {
        lock.lock(); snapshotCount += 1; lock.unlock()
        return devices
    }
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
    func watchDevices(uids: [String]) {
        // Mirrors CoreAudioSystem: order-insensitive, no-op when unchanged.
        let wanted = uids.sorted()
        lock.lock(); defer { lock.unlock() }
        guard watched != wanted else { return }
        watched = wanted
        watchChangeCount += 1
    }
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
        engine = GuardEngine(audio: audio, store: store, sweepInterval: 3600, minSweepGap: 0.05)
        engine.start()
    }

    override func tearDown() {
        engine.stop()
        super.tearDown()
    }

    /// Deterministically run one sweep to completion (bypasses coalescing).
    private func settle() {
        engine.sweepSynchronously()
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

    // MARK: - CPU-runaway regressions (v1.0.0 shipped a 107%-CPU loop)

    /// A storm of CoreAudio notifications must collapse into a handful of
    /// sweeps, not one sweep per notification.
    func testNotificationStormIsCoalesced() {
        settle()
        let before = audio.snapshotCount
        for _ in 0..<200 { audio.fireChange() }
        // Long enough for several coalescing windows (0.05s in this fixture).
        Thread.sleep(forTimeInterval: 0.4)
        let sweeps = audio.snapshotCount - before
        XCTAssertLessThan(sweeps, 20, "200 events produced \(sweeps) sweeps — coalescing is broken")
        XCTAssertGreaterThan(sweeps, 0, "events must still produce at least one sweep")
    }

    /// Steady-state sweeps must not churn the device-listener set: re-arming
    /// listeners takes a process-wide HAL mutex and was the CPU hog.
    func testRepeatedSweepsDoNotRearmListeners() {
        settle()
        let after1 = audio.watchChangeCount
        for _ in 0..<50 { settle() }
        XCTAssertEqual(audio.watchChangeCount, after1, "watch set must be stable across sweeps")
    }

    /// Watch-set comparison must be order-insensitive — CoreAudio does not
    /// guarantee a stable device enumeration order.
    func testDeviceReorderDoesNotRearmListeners() {
        settle()
        let baseline = audio.watchChangeCount
        audio.devices = [bmr1Out, bmr1In, builtinMic]   // same set, different order
        settle()
        audio.devices = [builtinMic, bmr1In, bmr1Out]
        settle()
        XCTAssertEqual(audio.watchChangeCount, baseline, "reordering must not re-arm listeners")
    }

    /// stop() must not block behind queued work, and must silence further work.
    func testStopIsPromptAndSilencesPendingWork() {
        settle()
        for _ in 0..<100 { audio.fireChange() }
        let t0 = Date()
        engine.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "stop() must not hang behind a backlog")

        let after = audio.snapshotCount
        for _ in 0..<50 { audio.fireChange() }
        engine.poke()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(audio.snapshotCount, after, "no sweeps may run after stop()")
        engine.start()   // tearDown expects a live engine
    }

    /// A permanently failing action must back off, not spin.
    func testFailingActionBacksOffInsteadOfSpinning() {
        settle()
        // Tracked device vanishes from the fake's world so setDefaultInput fails,
        // while the policy keeps asking for it.
        audio.defaultInput = bmr1In.uid
        audio.devices = [bmr1In, bmr1Out]
        settle()
        let attempts1 = audio.setInputCalls.count
        Thread.sleep(forTimeInterval: 0.3)
        let attempts2 = audio.setInputCalls.count
        XCTAssertLessThan(attempts2 - attempts1, 5,
                          "failed action retried \(attempts2 - attempts1)× in 0.3 s — backoff is broken")
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
