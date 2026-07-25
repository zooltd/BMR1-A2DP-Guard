import Foundation
import CoreAudio

/// Real CoreAudio implementation.
///
/// Design notes:
///  - AudioObjectIDs are never cached across events; every query resolves the
///    UID afresh, so device-list churn (Bluetooth reconnects, coreaudiod
///    restarts) cannot leave us acting on a stale ID.
///  - All listeners funnel into a single `onChange` callback; the engine
///    re-inspects full state on every event (idempotent sweep).
public final class CoreAudioSystem: AudioSystem {
    public var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "bmr1guard.coreaudio")
    private var started = false
    private var watchedUIDs: [String] = []
    /// Device-level listeners currently installed: (deviceID, address).
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var listenerBlock: AudioObjectPropertyListenerBlock!

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static let systemSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyServiceRestarted,
    ]

    public init() {
        listenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Re-arm device listeners on any event: device IDs may have churned.
            self.queue.async { self.rearmDeviceListeners() }
            self.onChange?()
        }
    }

    // MARK: - Lifecycle

    public func start() {
        queue.sync {
            guard !started else { return }
            started = true
            for sel in Self.systemSelectors {
                var a = Self.address(sel)
                AudioObjectAddPropertyListenerBlock(Self.systemObject, &a, queue, listenerBlock)
            }
            rearmDeviceListeners()
        }
    }

    public func stop() {
        queue.sync {
            guard started else { return }
            started = false
            for sel in Self.systemSelectors {
                var a = Self.address(sel)
                AudioObjectRemovePropertyListenerBlock(Self.systemObject, &a, queue, listenerBlock)
            }
            removeDeviceListeners()
        }
    }

    public func watchDevices(uids: [String]) {
        queue.async {
            guard self.watchedUIDs != uids else { return }
            self.watchedUIDs = uids
            self.rearmDeviceListeners()
        }
    }

    /// Must run on `queue`.
    private func removeDeviceListeners() {
        for (dev, a) in deviceListeners {
            var addr = a
            AudioObjectRemovePropertyListenerBlock(dev, &addr, queue, listenerBlock)
        }
        deviceListeners.removeAll()
    }

    /// Must run on `queue`.
    private func rearmDeviceListeners() {
        guard started else { return }
        removeDeviceListeners()
        for uid in watchedUIDs {
            guard let dev = Self.deviceID(forUID: uid) else { continue }
            for sel in [kAudioDevicePropertyNominalSampleRate,
                        kAudioDevicePropertyDeviceIsRunningSomewhere,
                        kAudioDevicePropertyDeviceIsAlive] {
                var a = Self.address(sel)
                if AudioObjectAddPropertyListenerBlock(dev, &a, queue, listenerBlock) == noErr {
                    deviceListeners.append((dev, a))
                }
            }
        }
    }

    // MARK: - Property plumbing

    private static func getData(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Data? {
        var addr = a
        guard AudioObjectHasProperty(obj, &addr) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var data = Data(count: Int(size))
        let err = data.withUnsafeMutableBytes { buf -> OSStatus in
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, buf.baseAddress!)
        }
        return err == noErr ? data.prefix(Int(size)) : nil
    }

    private static func getScalar<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ type: T.Type) -> T? {
        guard let d = getData(obj, a), d.count >= MemoryLayout<T>.size else { return nil }
        return d.withUnsafeBytes { $0.load(as: T.self) }
    }

    private static func getArray<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
        guard let d = getData(obj, a) else { return [] }
        let n = d.count / MemoryLayout<T>.stride
        return d.withUnsafeBytes { buf in
            (0..<n).map { buf.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
        }
    }

    private static func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        guard let cf = getScalar(obj, address(sel), Unmanaged<CFString>?.self),
              let s = cf?.takeUnretainedValue() else { return nil }
        return s as String
    }

    private static func fourCC(_ v: UInt32) -> String {
        let chars = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                     UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        guard chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(format: "0x%08X", v) }
        return String(bytes: chars, encoding: .ascii)!
    }

    private static func channelCount(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        guard let d = getData(dev, address(kAudioDevicePropertyStreamConfiguration, scope)) else { return 0 }
        return d.withUnsafeBytes { buf -> Int in
            let abl = buf.baseAddress!.assumingMemoryBound(to: AudioBufferList.self)
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            return list.reduce(0) { $0 + Int($1.mNumberChannels) }
        }
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        getArray(systemObject, address(kAudioHardwarePropertyDevices), AudioObjectID.self)
    }

    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        allDeviceIDs().first { getString($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func info(for dev: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = getString(dev, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = getString(dev, kAudioObjectPropertyName) ?? uid
        let transport = getScalar(dev, address(kAudioDevicePropertyTransportType), UInt32.self).map(fourCC) ?? "?"
        let alive = (getScalar(dev, address(kAudioDevicePropertyDeviceIsAlive), UInt32.self) ?? 1) != 0
        return AudioDeviceInfo(uid: uid, name: name, transport: transport,
                               hasInput: channelCount(dev, kAudioObjectPropertyScopeInput) > 0,
                               hasOutput: channelCount(dev, kAudioObjectPropertyScopeOutput) > 0,
                               isAlive: alive)
    }

    // MARK: - AudioSystem

    public func snapshotDevices() -> [AudioDeviceInfo] {
        Self.allDeviceIDs().compactMap(Self.info(for:))
    }

    public func defaultInputUID() -> String? {
        guard let dev = Self.getScalar(Self.systemObject,
                                       Self.address(kAudioHardwarePropertyDefaultInputDevice),
                                       AudioObjectID.self), dev != 0 else { return nil }
        return Self.getString(dev, kAudioDevicePropertyDeviceUID)
    }

    public func defaultOutputUID() -> String? {
        guard let dev = Self.getScalar(Self.systemObject,
                                       Self.address(kAudioHardwarePropertyDefaultOutputDevice),
                                       AudioObjectID.self), dev != 0 else { return nil }
        return Self.getString(dev, kAudioDevicePropertyDeviceUID)
    }

    public func setDefaultInput(uid: String) -> Bool {
        guard let dev = Self.deviceID(forUID: uid) else { return false }
        var a = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var d = dev
        return AudioObjectSetPropertyData(Self.systemObject, &a, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &d) == noErr
    }

    public func nominalRate(uid: String) -> Double? {
        guard let dev = Self.deviceID(forUID: uid) else { return nil }
        return Self.getScalar(dev, Self.address(kAudioDevicePropertyNominalSampleRate), Float64.self)
    }

    public func maxAvailableRate(uid: String) -> Double? {
        guard let dev = Self.deviceID(forUID: uid) else { return nil }
        let ranges = Self.getArray(dev, Self.address(kAudioDevicePropertyAvailableNominalSampleRates),
                                   AudioValueRange.self)
        return ranges.map(\.mMaximum).max()
    }

    public func setNominalRate(uid: String, rate: Double) -> Bool {
        guard let dev = Self.deviceID(forUID: uid) else { return false }
        var a = Self.address(kAudioDevicePropertyNominalSampleRate)
        var r = Float64(rate)
        return AudioObjectSetPropertyData(dev, &a, 0, nil,
                                          UInt32(MemoryLayout<Float64>.size), &r) == noErr
    }

    public func isRunningSomewhere(uid: String) -> Bool {
        guard let dev = Self.deviceID(forUID: uid) else { return false }
        return (Self.getScalar(dev, Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere),
                               UInt32.self) ?? 0) != 0
    }
}
