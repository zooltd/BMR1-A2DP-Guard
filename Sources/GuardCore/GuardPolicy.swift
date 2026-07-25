import Foundation

/// A snapshot of one CoreAudio device, reduced to the fields the policy needs.
/// Pure value type so the policy can be unit-tested without CoreAudio.
public struct AudioDeviceInfo: Equatable, Sendable {
    public var uid: String
    public var name: String
    /// CoreAudio transport type as a four-char string, e.g. "blue", "bltn", "usb ", "virt", "ccwd".
    public var transport: String
    public var hasInput: Bool
    public var hasOutput: Bool
    public var isAlive: Bool

    public init(uid: String, name: String, transport: String,
                hasInput: Bool, hasOutput: Bool, isAlive: Bool = true) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.isAlive = isAlive
    }
}

public struct GuardConfig: Equatable, Sendable {
    /// Bluetooth devices with one of these names are blocked as *input*.
    /// Only Bluetooth-transport devices are ever name-matched, so a USB mic that
    /// happens to share the name is unaffected.
    public var blockedBluetoothNames: [String]
    /// Exact device-UID matches that are blocked as input (belt and braces;
    /// survives the device being renamed).
    public var blockedInputUIDs: [String]

    public init(blockedBluetoothNames: [String] = ["Drop-BMR1"],
                blockedInputUIDs: [String] = []) {
        self.blockedBluetoothNames = blockedBluetoothNames
        self.blockedInputUIDs = blockedInputUIDs
    }
}

/// What the engine should do in response to an observed event.
public enum PolicyAction: Equatable, Sendable {
    /// Set the system-default input device to this UID.
    case setDefaultInput(uid: String, reason: String)
    /// Set the nominal sample rate of the device with this UID.
    case setNominalRate(uid: String, rate: Double, reason: String)
}

/// Pure decision core. Holds only `lastGoodInputUID` as state; every event
/// receives a fresh device snapshot so stale IDs can never be used.
///
/// Rules implemented (from the product spec):
///  - Only the configured device (Drop-BMR1) is blocked as input; all other
///    devices — including other Bluetooth microphones — are always allowed.
///  - A change of default input to any allowed device is treated as a
///    legitimate user/system choice and recorded as "last good".
///  - A change of default input to the blocked device is reverted to the last
///    good input if it is still present, otherwise to a minimal last-resort
///    fallback (built-in mic if present, else any allowed input). There is no
///    global priority list beyond that last resort.
///  - The blocked device's *output* is left alone except that its nominal
///    sample rate is restored to its maximum whenever it drops (HFP/SCO mode)
///    and nothing is actively recording from the blocked input.
public struct GuardPolicy: Sendable {
    public var config: GuardConfig
    public private(set) var lastGoodInputUID: String?

    public init(config: GuardConfig, lastGoodInputUID: String? = nil) {
        self.config = config
        self.lastGoodInputUID = lastGoodInputUID
    }

    // MARK: - Classification

    public func isBlockedInput(_ d: AudioDeviceInfo) -> Bool {
        if config.blockedInputUIDs.contains(d.uid) { return true }
        return d.transport == "blue" && config.blockedBluetoothNames.contains(d.name) && d.hasInput
    }

    /// The guarded *output* endpoint (same physical device, output side).
    public func isGuardedOutput(_ d: AudioDeviceInfo) -> Bool {
        d.transport == "blue" && config.blockedBluetoothNames.contains(d.name) && d.hasOutput
    }

    // MARK: - Events

    /// Default input changed (or was observed during a sweep).
    /// `devices` must be a fresh snapshot including the new default.
    public mutating func onDefaultInput(uid: String?, devices: [AudioDeviceInfo]) -> [PolicyAction] {
        guard let uid, let dev = devices.first(where: { $0.uid == uid }) else { return [] }

        if !isBlockedInput(dev) {
            // Rule: never treat a switch between allowed devices as an error.
            if dev.hasInput && dev.isAlive {
                lastGoodInputUID = dev.uid
            }
            return []
        }

        // Blocked device is (or became) the default input: restore.
        if let lg = lastGoodInputUID,
           let cand = devices.first(where: { $0.uid == lg }),
           cand.isAlive, cand.hasInput, !isBlockedInput(cand) {
            return [.setDefaultInput(uid: lg, reason: "Drop-BMR1 took default input; restoring last good input")]
        }

        // Last good input is gone: minimal last-resort fallback.
        let allowed = devices.filter { $0.hasInput && $0.isAlive && !isBlockedInput($0) }
        if let pick = allowed.first(where: { $0.transport == "bltn" }) ?? allowed.first {
            return [.setDefaultInput(uid: pick.uid, reason: "Drop-BMR1 took default input; last good input unavailable, using fallback \(pick.name)")]
        }

        // No allowed input device exists at all; nothing sensible to do.
        return []
    }

    /// Observed the guarded output device's nominal sample rate.
    /// `maxAvailableRate` is the highest rate the device currently advertises.
    /// `blockedInputBusy` is true when something is actively recording from the
    /// blocked input device (SCO in active use) — restoring the rate then would
    /// fight the Bluetooth stack, so we defer until it goes idle.
    public func onGuardedOutputRate(currentRate: Double,
                                    maxAvailableRate: Double,
                                    outputUID: String,
                                    blockedInputBusy: Bool) -> [PolicyAction] {
        guard maxAvailableRate > 0, currentRate < maxAvailableRate else { return [] }
        guard !blockedInputBusy else { return [] }
        return [.setNominalRate(uid: outputUID, rate: maxAvailableRate,
                                reason: "output at \(Int(currentRate)) Hz (HFP); restoring A2DP \(Int(maxAvailableRate)) Hz")]
    }

    /// Restore persisted state (e.g. app relaunch). Ignores blocked/unknown UIDs.
    public mutating func adoptPersistedLastGood(_ uid: String?, devices: [AudioDeviceInfo]) {
        guard let uid else { return }
        if let d = devices.first(where: { $0.uid == uid }), isBlockedInput(d) { return }
        lastGoodInputUID = uid
    }
}
