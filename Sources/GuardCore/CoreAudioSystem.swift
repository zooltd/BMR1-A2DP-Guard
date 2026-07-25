import Foundation
import CoreAudio

/// Real CoreAudio implementation.
///
/// Performance-critical design rules (a violation of any of these caused a
/// runaway CPU loop in v1.0.0 — see TEST-RESULTS.md):
///
///  1. **Never re-arm listeners from inside a listener callback.** Adding and
///     removing property listeners takes a process-wide HAL mutex; doing it on
///     every notification serialises against coreaudiod's own delivery and
///     burns CPU in both processes. Listeners are re-armed only on structural
///     events (device list changed / coreaudiod restarted) or when the set of
///     watched devices actually changes.
///  2. **One device enumeration per sweep.** `snapshotDevices()` refreshes a
///     UID→AudioObjectID map that every other call reuses, so a property read
///     costs one IPC instead of a full enumeration.
///  3. **Cache only immutable properties.** UID / name / transport never change
///     for a live AudioObjectID, and these are the expensive CFString reads.
///     The cache is dropped whenever the device ID set changes, so a recycled
///     ID can never return another device's identity.
public final class CoreAudioSystem: AudioSystem {
    public var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "bmr1guard.coreaudio")
    private let cacheLock = NSLock()

    private var started = false
    private var watchedUIDs: [String] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var listenerBlock: AudioObjectPropertyListenerBlock!

    // Caches (guarded by cacheLock).
    private var idByUID: [String: AudioObjectID] = [:]
    private var knownDeviceIDs: [AudioObjectID] = []
    private struct StaticInfo { let uid: String; let name: String; let transport: String }
    private var staticByID: [AudioObjectID: StaticInfo] = [:]

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
        listenerBlock = { [weak self] count, addresses in
            guard let self else { return }
            // Structural changes invalidate cached IDs and require re-arming.
            // Everything else is just "re-inspect the world" — no listener churn.
            var structural = false
            for i in 0..<Int(count) {
                let sel = addresses[i].mSelector
                if sel == kAudioHardwarePropertyDevices || sel == kAudioHardwarePropertyServiceRestarted {
                    structural = true
                    break
                }
            }
            if structural {
                self.invalidateCaches()
                // Deferred: never touch the HAL listener list while it is
                // delivering a notification on this queue.
                self.queue.async { self.rearmDeviceListeners() }
            }
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
        invalidateCaches()
    }

    public func watchDevices(uids: [String]) {
        // Sorted: CoreAudio's enumeration order is not guaranteed stable, and an
        // order-only difference must not be mistaken for a change.
        let wanted = uids.sorted()
        queue.async {
            guard self.watchedUIDs != wanted else { return }
            self.watchedUIDs = wanted
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
            guard let dev = deviceID(forUID: uid) else { continue }
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

    // MARK: - Caches

    private func invalidateCaches() {
        cacheLock.lock()
        idByUID.removeAll()
        staticByID.removeAll()
        knownDeviceIDs.removeAll()
        cacheLock.unlock()
    }

    /// Immutable identity of a device, read once per AudioObjectID lifetime.
    private func staticInfo(_ dev: AudioObjectID) -> StaticInfo? {
        cacheLock.lock()
        if let hit = staticByID[dev] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let uid = Self.getString(dev, kAudioDevicePropertyDeviceUID) else { return nil }
        let info = StaticInfo(uid: uid,
                              name: Self.getString(dev, kAudioObjectPropertyName) ?? uid,
                              transport: Self.getScalar(dev, Self.address(kAudioDevicePropertyTransportType),
                                                        UInt32.self).map(Self.fourCC) ?? "?")
        cacheLock.lock()
        staticByID[dev] = info
        idByUID[uid] = dev
        cacheLock.unlock()
        return info
    }

    /// O(1) after the sweep's enumeration; falls back to a rescan if the UID is
    /// unknown (device appeared between events).
    private func deviceID(forUID uid: String) -> AudioObjectID? {
        cacheLock.lock()
        let hit = idByUID[uid]
        cacheLock.unlock()
        if let hit { return hit }
        _ = snapshotDevices()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return idByUID[uid]
    }

    // MARK: - AudioSystem

    public func snapshotDevices() -> [AudioDeviceInfo] {
        let ids = Self.allDeviceIDs()

        // A changed ID set means IDs may have been recycled: drop identity caches.
        cacheLock.lock()
        let idsChanged = ids != knownDeviceIDs
        if idsChanged {
            knownDeviceIDs = ids
            staticByID.removeAll()
            idByUID.removeAll()
        }
        cacheLock.unlock()

        return ids.compactMap { dev -> AudioDeviceInfo? in
            guard let s = staticInfo(dev) else { return nil }
            let alive = (Self.getScalar(dev, Self.address(kAudioDevicePropertyDeviceIsAlive), UInt32.self) ?? 1) != 0
            return AudioDeviceInfo(uid: s.uid, name: s.name, transport: s.transport,
                                   hasInput: Self.channelCount(dev, kAudioObjectPropertyScopeInput) > 0,
                                   hasOutput: Self.channelCount(dev, kAudioObjectPropertyScopeOutput) > 0,
                                   isAlive: alive)
        }
    }

    private func defaultDeviceUID(_ sel: AudioObjectPropertySelector) -> String? {
        guard let dev = Self.getScalar(Self.systemObject, Self.address(sel), AudioObjectID.self),
              dev != 0 else { return nil }
        return staticInfo(dev)?.uid
    }

    public func defaultInputUID() -> String? { defaultDeviceUID(kAudioHardwarePropertyDefaultInputDevice) }
    public func defaultOutputUID() -> String? { defaultDeviceUID(kAudioHardwarePropertyDefaultOutputDevice) }

    public func setDefaultInput(uid: String) -> Bool {
        guard let dev = deviceID(forUID: uid) else { return false }
        var a = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var d = dev
        return AudioObjectSetPropertyData(Self.systemObject, &a, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &d) == noErr
    }

    public func nominalRate(uid: String) -> Double? {
        guard let dev = deviceID(forUID: uid) else { return nil }
        return Self.getScalar(dev, Self.address(kAudioDevicePropertyNominalSampleRate), Float64.self)
    }

    public func maxAvailableRate(uid: String) -> Double? {
        guard let dev = deviceID(forUID: uid) else { return nil }
        return Self.getArray(dev, Self.address(kAudioDevicePropertyAvailableNominalSampleRates),
                             AudioValueRange.self).map(\.mMaximum).max()
    }

    public func setNominalRate(uid: String, rate: Double) -> Bool {
        guard let dev = deviceID(forUID: uid) else { return false }
        var a = Self.address(kAudioDevicePropertyNominalSampleRate)
        var r = Float64(rate)
        return AudioObjectSetPropertyData(dev, &a, 0, nil,
                                          UInt32(MemoryLayout<Float64>.size), &r) == noErr
    }

    public func isRunningSomewhere(uid: String) -> Bool {
        guard let dev = deviceID(forUID: uid) else { return false }
        return (Self.getScalar(dev, Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere),
                               UInt32.self) ?? 0) != 0
    }
}
