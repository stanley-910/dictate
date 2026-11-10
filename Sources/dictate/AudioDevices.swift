import CoreAudio
import Foundation

/// Input device enumeration and selection via CoreAudio.
struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// `kAudioDeviceTransportType…`: built-in, Bluetooth, USB and so on.
    var transport: UInt32 = 0

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The same headset: one device for both directions, or a pair whose UIDs
    /// differ only after the last ":" ("…:input", "…:output") or that share a name.
    func sameHardware(as other: AudioInputDevice) -> Bool {
        func base(_ uid: String) -> Substring { uid.lastIndex(of: ":").map { uid[..<$0] } ?? Substring(uid) }
        return id == other.id || name == other.name || base(uid) == base(other.uid)
    }
}

enum AudioDevices {
    private static let defaultsKey = "microphone"

    /// The user's pick from the menu, persisted across launches. nil = system default.
    static var selectedUID: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }
    }

    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName),
                  // CoreAudio makes a private aggregate for any process using
                  // the default input; it is ours and not a real choice.
                  !uid.hasPrefix("CADefaultDeviceAggregate")
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, transport: transportType(id))
        }
    }

    /// The Mac's own microphone, if it has one.
    static func builtInInput() -> AudioInputDevice? {
        inputDevices().first { $0.isBuiltIn }
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return inputDevices().first { $0.id == id }
    }

    /// Resolves the effective device: the menu pick if still connected, else
    /// system default. With `preferBuiltIn`, see `choose`.
    static func resolve(configured: String?, preferBuiltIn: Bool = false) -> AudioInputDevice? {
        choose(picked: selectedUID ?? configured, devices: inputDevices(), defaultInput: defaultInputDevice(),
               output: preferBuiltIn ? defaultOutputDevice() : nil, preferBuiltIn: preferBuiltIn)
    }

    /// The input to record from: `picked` (UID or name) if connected, else
    /// the default input. With `preferBuiltIn` and nothing picked, a default
    /// input that is the Bluetooth headset playing the output is passed over
    /// for the built-in mic: recording from a headset drops its playback to
    /// call quality (HFP) for as long as the mic is open.
    static func choose(picked: String?, devices: [AudioInputDevice], defaultInput: AudioInputDevice?,
                       output: AudioInputDevice?, preferBuiltIn: Bool) -> AudioInputDevice? {
        if let picked, let d = devices.first(where: { $0.uid == picked || $0.name == picked }) { return d }
        if preferBuiltIn, let input = defaultInput, let output, output.isBluetooth, input.sameHardware(as: output),
           let builtIn = devices.first(where: \.isBuiltIn) {
            return builtIn
        }
        return defaultInput
    }

    /// The default output, described like an input device, for `choose`.
    static func defaultOutputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0, let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName)
        else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name, transport: transportType(id))
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
