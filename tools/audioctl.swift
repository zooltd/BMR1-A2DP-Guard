// audioctl — minimal CLI to get/set CoreAudio defaults and rates (integration-test helper).
// Usage:
//   audioctl get-default-input | get-default-output
//   audioctl set-default-input <uid>
//   audioctl set-default-output <uid>
//   audioctl get-rate <uid>
//   audioctl set-rate <uid> <hz>
//   audioctl list
//   audioctl record-default <seconds>   (records from system-default input, discards data)
import CoreAudio
import AudioToolbox
import Foundation

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

let sys = AudioObjectID(kAudioObjectSystemObject)

func allDevices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func uid(of dev: AudioObjectID) -> String? {
    var a = addr(kAudioDevicePropertyDeviceUID)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &cf) == noErr else { return nil }
    return cf?.takeRetainedValue() as String?
}

func name(of dev: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &cf) == noErr else { return "?" }
    return (cf?.takeRetainedValue() as String?) ?? "?"
}

func device(forUID target: String) -> AudioObjectID? {
    allDevices().first { uid(of: $0) == target }
}

func getDefault(_ sel: AudioObjectPropertySelector) -> AudioObjectID {
    var a = addr(sel)
    var dev = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &dev)
    return dev
}

func setDefault(_ sel: AudioObjectPropertySelector, _ dev: AudioObjectID) -> OSStatus {
    var a = addr(sel)
    var d = dev
    return AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: see header") }

switch args[1] {
case "list":
    for d in allDevices() { print("\(d)\t\(uid(of: d) ?? "?")\t\(name(of: d))") }
case "get-default-input":
    let d = getDefault(kAudioHardwarePropertyDefaultInputDevice)
    print(uid(of: d) ?? "?")
case "get-default-output":
    let d = getDefault(kAudioHardwarePropertyDefaultOutputDevice)
    print(uid(of: d) ?? "?")
case "set-default-input":
    guard args.count == 3, let d = device(forUID: args[2]) else { fail("no device with uid \(args[2])") }
    let err = setDefault(kAudioHardwarePropertyDefaultInputDevice, d)
    if err != noErr { fail("set failed: \(err)") }
case "set-default-output":
    guard args.count == 3, let d = device(forUID: args[2]) else { fail("no device with uid \(args[2])") }
    let err = setDefault(kAudioHardwarePropertyDefaultOutputDevice, d)
    if err != noErr { fail("set failed: \(err)") }
case "get-rate":
    guard args.count == 3, let d = device(forUID: args[2]) else { fail("no device with uid \(args[2])") }
    var a = addr(kAudioDevicePropertyNominalSampleRate)
    var rate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &rate) == noErr else { fail("get rate failed") }
    print(rate)
case "set-rate":
    guard args.count == 4, let d = device(forUID: args[2]), let hz = Float64(args[3]) else { fail("bad args") }
    var a = addr(kAudioDevicePropertyNominalSampleRate)
    var rate = hz
    let err = AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
    if err != noErr { fail("set rate failed: \(err)") }
case "record-default":
    // Opens an input AudioQueue on the SYSTEM DEFAULT input (like any default-input app) and discards buffers.
    let seconds = args.count >= 3 ? (Double(args[2]) ?? 2.0) : 2.0
    var fmt = AudioStreamBasicDescription(
        mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
        mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var queue: AudioQueueRef?
    let cb: AudioQueueInputCallback = { _, q, buf, _, _, _ in AudioQueueEnqueueBuffer(q, buf, 0, nil) }
    guard AudioQueueNewInput(&fmt, cb, nil, nil, nil, 0, &queue) == noErr, let q = queue else {
        fail("AudioQueueNewInput failed (mic permission?)")
    }
    for _ in 0..<3 {
        var buf: AudioQueueBufferRef?
        AudioQueueAllocateBuffer(q, 3200, &buf)
        if let b = buf { AudioQueueEnqueueBuffer(q, b, 0, nil) }
    }
    guard AudioQueueStart(q, nil) == noErr else { fail("AudioQueueStart failed") }
    print("recording from default input for \(seconds)s ...")
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    AudioQueueStop(q, true)
    AudioQueueDispose(q, true)
    print("stopped")
default:
    fail("unknown command \(args[1])")
}
