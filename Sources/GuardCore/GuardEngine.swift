import Foundation
import os

public struct GuardEvent: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let message: String
}

/// Snapshot of engine state for UI display.
public struct GuardStatus: Sendable {
    public var enabled: Bool
    public var defaultInputName: String
    public var defaultOutputName: String
    public var lastGoodInputName: String
    public var guardedOutputRate: Double?
    public var blockedDevicePresent: Bool
    public var events: [GuardEvent]

    static let empty = GuardStatus(enabled: true, defaultInputName: "—", defaultOutputName: "—",
                                   lastGoodInputName: "—", guardedOutputRate: nil,
                                   blockedDevicePresent: false, events: [])
}

/// Binds the pure policy to an AudioSystem.
///
/// Concurrency/CPU rules (v1.0.0 shipped a runaway loop by breaking these):
///  - Every trigger funnels into one idempotent `sweep`, and sweeps are
///    **coalesced**: a burst of CoreAudio notifications produces at most one
///    sweep per `minSweepGap`, so work can never queue up faster than it drains.
///  - `status()` is served from a cached snapshot and never blocks on the
///    engine queue, so the menu bar cannot stall behind audio work.
///  - `stop()` flips a lock-protected flag first, which makes any queued sweep
///    a no-op, so shutdown cannot hang behind a backlog.
public final class GuardEngine: @unchecked Sendable {
    private let audio: AudioSystem
    private let store: GuardStateStore
    private let queue = DispatchQueue(label: "bmr1guard.engine")
    private var policy: GuardPolicy
    private let log = Logger(subsystem: "com.youhan.bmr1guard", category: "engine")

    // Queue-confined state.
    private var events: [GuardEvent] = []
    private var lastEventMessage: String?
    private var lastEventDate = Date.distantPast
    private var sweepScheduled = false
    private var lastSweepFinished = Date.distantPast
    private var consecutiveFailures = 0

    // Lock-protected state (read from the UI thread).
    private let stateLock = NSLock()
    private var _stopped = true
    private var _enabled = true
    private var _cachedStatus = GuardStatus.empty
    private var _timer: DispatchSourceTimer?

    /// UI notification hook.
    public var onStatusChanged: (() -> Void)?

    /// Safety-net sweep interval. Listeners are the primary trigger.
    private let sweepInterval: TimeInterval
    /// Minimum spacing between sweeps; bursts collapse into one.
    private let minSweepGap: TimeInterval
    private static let maxRetryDelay: TimeInterval = 30

    public init(audio: AudioSystem, store: GuardStateStore,
                config: GuardConfig = GuardConfig(),
                sweepInterval: TimeInterval = 5.0,
                minSweepGap: TimeInterval = 0.15) {
        self.audio = audio
        self.store = store
        self.policy = GuardPolicy(config: config)
        self.sweepInterval = sweepInterval
        self.minSweepGap = minSweepGap
    }

    public var enabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _enabled
    }

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _stopped
    }

    // MARK: - Lifecycle

    public func start() {
        stateLock.lock()
        guard _stopped else { stateLock.unlock(); return }
        _stopped = false
        stateLock.unlock()

        queue.sync {
            let devices = audio.snapshotDevices()
            policy.adoptPersistedLastGood(store.loadLastGoodInputUID(), devices: devices)
            audio.onChange = { [weak self] in self?.requestSweep() }
            audio.start()
            appendEvent("Guard started")
            sweepLocked()
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + sweepInterval, repeating: sweepInterval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self, !self.isStopped else { return }
            self.sweepLocked()
            self.lastSweepFinished = Date()
        }
        t.resume()
        stateLock.lock(); _timer = t; stateLock.unlock()
    }

    /// Stops listeners and enforcement. Leaves current system state untouched —
    /// quitting the app restores ordinary macOS behaviour by construction.
    public func stop() {
        stateLock.lock()
        guard !_stopped else { stateLock.unlock(); return }
        _stopped = true                     // queued sweeps become no-ops immediately
        let t = _timer
        _timer = nil
        stateLock.unlock()

        t?.cancel()
        audio.onChange = nil
        audio.stop()
        queue.async { self.appendEvent("Guard stopped") }
    }

    public func setEnabled(_ on: Bool) {
        stateLock.lock()
        _enabled = on
        _cachedStatus.enabled = on
        stateLock.unlock()
        queue.async {
            self.appendEvent(on ? "Guard resumed" : "Guard paused")
            if on { self.sweepLocked() }
        }
    }

    /// Request a sweep soon (coalescing). Safe to call from any thread, at any rate.
    public func poke() { requestSweep() }

    /// Run one sweep synchronously — for tests and diagnostics only.
    public func sweepSynchronously() {
        queue.sync {
            sweepLocked()
            lastSweepFinished = Date()
        }
    }

    private func requestSweep() {
        guard !isStopped else { return }
        queue.async { [weak self] in
            guard let self, !self.isStopped, !self.sweepScheduled else { return }
            self.sweepScheduled = true
            // Isolated events run immediately; storms are throttled to one sweep
            // per minSweepGap instead of one sweep per notification.
            let wait = max(0, self.minSweepGap - Date().timeIntervalSince(self.lastSweepFinished))
            self.queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.sweepScheduled = false
                guard !self.isStopped else { return }
                self.sweepLocked()
                self.lastSweepFinished = Date()
            }
        }
    }

    // MARK: - Status (never touches the engine queue)

    public func status() -> GuardStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return _cachedStatus
    }

    public var lastGoodInputUID: String? { queue.sync { policy.lastGoodInputUID } }

    // MARK: - Core sweep (must run on queue)

    private func sweepLocked() {
        guard !isStopped else { return }

        let devices = audio.snapshotDevices()
        let defaultIn = audio.defaultInputUID()
        let defaultOut = audio.defaultOutputUID()

        // Keep device-level listeners pointed at the guarded endpoints. The
        // AudioSystem no-ops when the set is unchanged, so this is cheap.
        let guardedInput = devices.first(where: { policy.isBlockedInput($0) })
        let guardedOutput = devices.first(where: { policy.isGuardedOutput($0) })
        audio.watchDevices(uids: [guardedInput?.uid, guardedOutput?.uid].compactMap { $0 })

        let previousLastGood = policy.lastGoodInputUID
        var actions: [PolicyAction] = []
        actions += policy.onDefaultInput(uid: defaultIn, devices: devices)

        var outputRate: Double?
        if let out = guardedOutput, out.isAlive {
            outputRate = audio.nominalRate(uid: out.uid)
            if let rate = outputRate, let maxRate = audio.maxAvailableRate(uid: out.uid) {
                let busy = guardedInput.map { audio.isRunningSomewhere(uid: $0.uid) } ?? false
                actions += policy.onGuardedOutputRate(currentRate: rate, maxAvailableRate: maxRate,
                                                      outputUID: out.uid, blockedInputBusy: busy)
            }
        }

        if previousLastGood != policy.lastGoodInputUID {
            store.saveLastGoodInputUID(policy.lastGoodInputUID)
            let name = devices.first(where: { $0.uid == policy.lastGoodInputUID })?.name
                ?? policy.lastGoodInputUID ?? "—"
            appendEvent("Tracking input: \(name)")
        }

        var failed = false
        if enabled {
            for action in actions {
                switch action {
                case let .setDefaultInput(uid, reason):
                    let ok = audio.setDefaultInput(uid: uid)
                    appendEvent("\(reason) → set default input \(ok ? "OK" : "FAILED")")
                    failed = failed || !ok
                case let .setNominalRate(uid, rate, reason):
                    let ok = audio.setNominalRate(uid: uid, rate: rate)
                    appendEvent("\(reason) → set rate \(ok ? "OK" : "FAILED")")
                    failed = failed || !ok
                }
            }
        }

        updateCachedStatus(devices: devices, defaultIn: defaultIn, defaultOut: defaultOut,
                           outputRate: outputRate,
                           blockedPresent: guardedInput != nil || guardedOutput != nil)

        if failed {
            // Exponential backoff, capped — a permanently failing action must
            // never turn into a busy loop.
            consecutiveFailures += 1
            let delay = min(Self.maxRetryDelay, 0.5 * pow(2, Double(consecutiveFailures - 1)))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.sweepLocked()
                self.lastSweepFinished = Date()
            }
        } else {
            consecutiveFailures = 0
        }

        if !actions.isEmpty { onStatusChanged?() }
    }

    private func updateCachedStatus(devices: [AudioDeviceInfo], defaultIn: String?, defaultOut: String?,
                                   outputRate: Double?, blockedPresent: Bool) {
        func nameOf(_ uid: String?) -> String {
            guard let uid else { return "—" }
            return devices.first(where: { $0.uid == uid })?.name ?? uid
        }
        stateLock.lock()
        _cachedStatus = GuardStatus(enabled: _enabled,
                                    defaultInputName: nameOf(defaultIn),
                                    defaultOutputName: nameOf(defaultOut),
                                    lastGoodInputName: nameOf(policy.lastGoodInputUID),
                                    guardedOutputRate: outputRate,
                                    blockedDevicePresent: blockedPresent,
                                    events: events)
        stateLock.unlock()
    }

    private func appendEvent(_ message: String) {
        // Collapse identical messages arriving in a tight loop.
        let now = Date()
        if message == lastEventMessage && now.timeIntervalSince(lastEventDate) < 2.0 { return }
        lastEventMessage = message
        lastEventDate = now
        events.append(GuardEvent(date: now, message: message))
        if events.count > 50 { events.removeFirst(events.count - 50) }
        log.info("\(message, privacy: .public)")
        stateLock.lock(); _cachedStatus.events = events; stateLock.unlock()
        onStatusChanged?()
    }
}
