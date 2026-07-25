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
}

/// Binds the pure policy to an AudioSystem. All work happens on a serial queue;
/// every trigger (listener event, timer, manual poke) runs the same idempotent
/// `sweep()`, so races and duplicate events are harmless.
public final class GuardEngine: @unchecked Sendable {
    private let audio: AudioSystem
    private let store: GuardStateStore
    private let queue = DispatchQueue(label: "bmr1guard.engine")
    private var policy: GuardPolicy
    private var timer: DispatchSourceTimer?
    private var events: [GuardEvent] = []
    private var lastEventMessage: String?
    private var lastEventDate = Date.distantPast
    private let log = Logger(subsystem: "com.youhan.bmr1guard", category: "engine")

    /// UI notification hook (called on the engine queue).
    public var onStatusChanged: (() -> Void)?

    public private(set) var enabled = true

    /// Safety-net sweep interval. Listeners are the primary trigger; this catches
    /// anything missed (e.g. a rate change while listeners were being re-armed).
    private let sweepInterval: TimeInterval

    public init(audio: AudioSystem, store: GuardStateStore,
                config: GuardConfig = GuardConfig(), sweepInterval: TimeInterval = 3.0) {
        self.audio = audio
        self.store = store
        self.policy = GuardPolicy(config: config)
        self.sweepInterval = sweepInterval
    }

    // MARK: - Lifecycle

    public func start() {
        queue.sync {
            let devices = audio.snapshotDevices()
            policy.adoptPersistedLastGood(store.loadLastGoodInputUID(), devices: devices)
            audio.onChange = { [weak self] in self?.queue.async { self?.sweepLocked() } }
            audio.start()

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + sweepInterval, repeating: sweepInterval)
            t.setEventHandler { [weak self] in self?.sweepLocked() }
            t.resume()
            timer = t

            appendEvent("Guard started")
            sweepLocked()
        }
    }

    /// Stops listeners and enforcement. Leaves current system state untouched —
    /// quitting the app restores ordinary macOS behaviour by construction.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            audio.onChange = nil
            audio.stop()
            appendEvent("Guard stopped")
        }
    }

    public func setEnabled(_ on: Bool) {
        queue.sync {
            enabled = on
            appendEvent(on ? "Guard resumed" : "Guard paused")
            if on { sweepLocked() }
        }
    }

    /// Trigger an immediate sweep (e.g. from tests or menu "Enforce now").
    public func poke() {
        queue.async { self.sweepLocked() }
    }

    // MARK: - Status for UI

    public func status() -> GuardStatus {
        queue.sync {
            let devices = audio.snapshotDevices()
            func nameOf(_ uid: String?) -> String {
                guard let uid else { return "—" }
                return devices.first(where: { $0.uid == uid })?.name ?? uid
            }
            let guarded = devices.first(where: { policy.isGuardedOutput($0) })
            return GuardStatus(
                enabled: enabled,
                defaultInputName: nameOf(audio.defaultInputUID()),
                defaultOutputName: nameOf(audio.defaultOutputUID()),
                lastGoodInputName: nameOf(policy.lastGoodInputUID),
                guardedOutputRate: guarded.flatMap { audio.nominalRate(uid: $0.uid) },
                blockedDevicePresent: devices.contains(where: { policy.isBlockedInput($0) || policy.isGuardedOutput($0) }),
                events: events
            )
        }
    }

    public var lastGoodInputUID: String? { queue.sync { policy.lastGoodInputUID } }

    // MARK: - Core sweep (must run on queue)

    private func sweepLocked() {
        let devices = audio.snapshotDevices()

        // Keep device-level listeners pointed at the guarded endpoints.
        let watch = devices.filter { policy.isBlockedInput($0) || policy.isGuardedOutput($0) }.map(\.uid)
        audio.watchDevices(uids: watch)

        let previousLastGood = policy.lastGoodInputUID
        var actions: [PolicyAction] = []

        // 1. Default-input rule. Tracking of "last good" continues even while
        //    paused so resuming has fresh state; enforcement actions are gated.
        actions += policy.onDefaultInput(uid: audio.defaultInputUID(), devices: devices)

        // 2. Output A2DP rate rule.
        if let out = devices.first(where: { policy.isGuardedOutput($0) }), out.isAlive,
           let rate = audio.nominalRate(uid: out.uid),
           let maxRate = audio.maxAvailableRate(uid: out.uid) {
            let busy = devices.first(where: { policy.isBlockedInput($0) })
                .map { audio.isRunningSomewhere(uid: $0.uid) } ?? false
            actions += policy.onGuardedOutputRate(currentRate: rate, maxAvailableRate: maxRate,
                                                  outputUID: out.uid, blockedInputBusy: busy)
        }

        if previousLastGood != policy.lastGoodInputUID {
            store.saveLastGoodInputUID(policy.lastGoodInputUID)
            let name = devices.first(where: { $0.uid == policy.lastGoodInputUID })?.name ?? policy.lastGoodInputUID ?? "—"
            appendEvent("Tracking input: \(name)")
        }

        guard enabled else { return }

        for action in actions {
            switch action {
            case let .setDefaultInput(uid, reason):
                let ok = audio.setDefaultInput(uid: uid)
                appendEvent("\(reason) → set default input \(ok ? "OK" : "FAILED")")
                if !ok { scheduleRetry() }
                // Verify: listeners will fire again; also do a quick re-check.
                scheduleVerify()
            case let .setNominalRate(uid, rate, reason):
                let ok = audio.setNominalRate(uid: uid, rate: rate)
                appendEvent("\(reason) → set rate \(ok ? "OK" : "FAILED")")
                if !ok { scheduleRetry() }
            }
        }
        if !actions.isEmpty { onStatusChanged?() }
    }

    private func scheduleVerify() {
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.sweepLocked() }
    }

    private func scheduleRetry() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sweepLocked() }
    }

    private func appendEvent(_ message: String) {
        // Collapse identical messages arriving in a tight loop (listener storms).
        let now = Date()
        if message == lastEventMessage && now.timeIntervalSince(lastEventDate) < 2.0 { return }
        lastEventMessage = message
        lastEventDate = now
        events.append(GuardEvent(date: now, message: message))
        if events.count > 50 { events.removeFirst(events.count - 50) }
        log.info("\(message, privacy: .public)")
        onStatusChanged?()
    }
}
