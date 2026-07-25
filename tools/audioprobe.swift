// audioprobe — dump public CoreAudio state as JSON for observation/diffing.
// Usage: audioprobe [--watch seconds]
import CoreAudio
import Foundation

func gpa(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func getData(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Data? {
    var a = addr
    guard AudioObjectHasProperty(objectID, &a) else { return nil }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &a, 0, nil, &size) == noErr, size > 0 else { return nil }
    var data = Data(count: Int(size))
    let err = data.withUnsafeMutableBytes { buf -> OSStatus in
        AudioObjectGetPropertyData(objectID, &a, 0, nil, &size, buf.baseAddress!)
    }
    return err == noErr ? data.prefix(Int(size)) : nil
}

func getScalar<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ type: T.Type) -> T? {
    guard let d = getData(objectID, addr), d.count >= MemoryLayout<T>.size else { return nil }
    return d.withUnsafeBytes { $0.load(as: T.self) }
}

func getArray<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ type: T.Type) -> [T]? {
    guard let d = getData(objectID, addr) else { return nil }
    let n = d.count / MemoryLayout<T>.stride
    return d.withUnsafeBytes { buf in (0..<n).map { buf.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) } }
}

func getString(_ objectID: AudioObjectID, _ sel: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
    guard let cf = getScalar(objectID, gpa(objectID, sel, scope), Unmanaged<CFString>?.self),
          let s = cf?.takeUnretainedValue() else { return nil }
    return s as String
}

func fourCC(_ v: UInt32) -> String {
    let chars = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    if chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return String(bytes: chars, encoding: .ascii)!
    }
    return String(format: "0x%08X", v)
}

func streamConfig(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
    guard let d = getData(dev, gpa(dev, kAudioDevicePropertyStreamConfiguration, scope)) else { return [] }
    return d.withUnsafeBytes { buf -> [Int] in
        let abl = buf.baseAddress!.assumingMemoryBound(to: AudioBufferList.self)
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        return list.map { Int($0.mNumberChannels) }
    }
}

func asbdDict(_ f: AudioStreamBasicDescription) -> [String: Any] {
    ["sampleRate": f.mSampleRate, "formatID": fourCC(f.mFormatID), "flags": f.mFormatFlags,
     "bytesPerFrame": f.mBytesPerFrame, "channels": f.mChannelsPerFrame, "bitsPerChannel": f.mBitsPerChannel]
}

func streamInfo(_ sid: AudioObjectID) -> [String: Any] {
    var s: [String: Any] = ["streamID": sid]
    if let dir = getScalar(sid, gpa(sid, kAudioStreamPropertyDirection), UInt32.self) {
        s["direction"] = dir == 1 ? "input" : "output"
    }
    if let term = getScalar(sid, gpa(sid, kAudioStreamPropertyTerminalType), UInt32.self) {
        s["terminalType"] = String(format: "0x%X", term)
    }
    if let active = getScalar(sid, gpa(sid, kAudioStreamPropertyIsActive), UInt32.self) {
        s["isActive"] = active
    }
    if let f = getScalar(sid, gpa(sid, kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription.self) {
        s["physicalFormat"] = asbdDict(f)
    }
    if let f = getScalar(sid, gpa(sid, kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription.self) {
        s["virtualFormat"] = asbdDict(f)
    }
    if let avail = getArray(sid, gpa(sid, kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription.self) {
        s["availablePhysicalFormats"] = avail.map { r -> [String: Any] in
            var d = asbdDict(r.mFormat)
            d["rateRange"] = [r.mSampleRateRange.mMinimum, r.mSampleRateRange.mMaximum]
            return d
        }
    }
    return s
}

func deviceInfo(_ dev: AudioObjectID) -> [String: Any] {
    var d: [String: Any] = ["objectID": dev]
    d["uid"] = getString(dev, kAudioDevicePropertyDeviceUID) ?? "?"
    d["name"] = getString(dev, kAudioObjectPropertyName) ?? "?"
    d["modelUID"] = getString(dev, kAudioDevicePropertyModelUID)
    if let t = getScalar(dev, gpa(dev, kAudioDevicePropertyTransportType), UInt32.self) {
        d["transportType"] = fourCC(t)
    }
    d["inputChannelsByStream"] = streamConfig(dev, kAudioObjectPropertyScopeInput)
    d["outputChannelsByStream"] = streamConfig(dev, kAudioObjectPropertyScopeOutput)
    if let sr = getScalar(dev, gpa(dev, kAudioDevicePropertyNominalSampleRate), Float64.self) {
        d["nominalSampleRate"] = sr
    }
    if let rates = getArray(dev, gpa(dev, kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange.self) {
        d["availableSampleRates"] = rates.map { [$0.mMinimum, $0.mMaximum] }
    }
    if let alive = getScalar(dev, gpa(dev, kAudioDevicePropertyDeviceIsAlive), UInt32.self) {
        d["isAlive"] = alive
    }
    if let running = getScalar(dev, gpa(dev, kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32.self) {
        d["isRunningSomewhere"] = running
    }
    if let hog = getScalar(dev, gpa(dev, kAudioDevicePropertyHogMode), pid_t.self) {
        d["hogPID"] = hog
    }
    for (label, scope) in [("input", kAudioObjectPropertyScopeInput), ("output", kAudioObjectPropertyScopeOutput)] {
        if let sids = getArray(dev, gpa(dev, kAudioDevicePropertyStreams, scope), AudioObjectID.self), !sids.isEmpty {
            d["\(label)Streams"] = sids.map(streamInfo)
        }
        if let src = getScalar(dev, gpa(dev, kAudioDevicePropertyDataSource, scope), UInt32.self) {
            d["\(label)DataSource"] = fourCC(src)
        }
        if let srcs = getArray(dev, gpa(dev, kAudioDevicePropertyDataSources, scope), UInt32.self) {
            d["\(label)DataSources"] = srcs.map(fourCC)
        }
    }
    return d
}

func snapshot() -> [String: Any] {
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var out: [String: Any] = [:]
    out["timestamp"] = ISO8601DateFormatter().string(from: Date())
    let devs = getArray(sys, gpa(sys, kAudioHardwarePropertyDevices), AudioObjectID.self) ?? []
    func defaultUID(_ sel: AudioObjectPropertySelector) -> [String: Any] {
        guard let id = getScalar(sys, gpa(sys, sel), AudioObjectID.self) else { return [:] }
        return ["objectID": id, "uid": getString(id, kAudioDevicePropertyDeviceUID) ?? "?",
                "name": getString(id, kAudioObjectPropertyName) ?? "?"]
    }
    out["defaultInput"] = defaultUID(kAudioHardwarePropertyDefaultInputDevice)
    out["defaultOutput"] = defaultUID(kAudioHardwarePropertyDefaultOutputDevice)
    out["defaultSystemOutput"] = defaultUID(kAudioHardwarePropertyDefaultSystemOutputDevice)
    out["devices"] = devs.map(deviceInfo)
    // Process-visible plugin list omitted; devices[] covers endpoint membership.
    return out
}

let json = try! JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
