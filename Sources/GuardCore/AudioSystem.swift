import Foundation

/// Abstraction over CoreAudio so the engine can be exercised in tests.
public protocol AudioSystem: AnyObject {
    /// Fresh snapshot of all devices.
    func snapshotDevices() -> [AudioDeviceInfo]
    func defaultInputUID() -> String?
    func defaultOutputUID() -> String?
    @discardableResult func setDefaultInput(uid: String) -> Bool
    func nominalRate(uid: String) -> Double?
    /// Highest nominal sample rate the device currently advertises, if any.
    func maxAvailableRate(uid: String) -> Double?
    @discardableResult func setNominalRate(uid: String, rate: Double) -> Bool
    /// kAudioDevicePropertyDeviceIsRunningSomewhere — true if any process has IO running on it.
    func isRunningSomewhere(uid: String) -> Bool

    /// Ask the system to emit `onChange` for property changes on these specific
    /// devices (nominal rate, running state) in addition to system-level events.
    func watchDevices(uids: [String])

    /// Fired on any potentially relevant change (default devices, device list,
    /// watched-device properties, coreaudiod restart). May fire spuriously;
    /// consumers must treat it as "re-inspect the world".
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()
}

/// Persistence for the tracked last-good input.
public protocol GuardStateStore: AnyObject {
    func loadLastGoodInputUID() -> String?
    func saveLastGoodInputUID(_ uid: String?)
}

public final class UserDefaultsStateStore: GuardStateStore {
    static let key = "LastGoodInputUID"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func loadLastGoodInputUID() -> String? { defaults.string(forKey: Self.key) }
    public func saveLastGoodInputUID(_ uid: String?) {
        if let uid { defaults.set(uid, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }
}
