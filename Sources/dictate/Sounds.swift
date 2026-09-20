import AppKit
import AudioToolbox
import CoreAudio

enum Sounds {
    /// `name` is a system sound name ("Tink") or a file path ("~/x.aiff").
    static func play(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        let sound: NSSound?
        if name.contains("/") {
            sound = NSSound(contentsOfFile: (name as NSString).expandingTildeInPath, byReference: true)
        } else {
            sound = NSSound(named: name)
                ?? NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        }
        if sound == nil { log("sound not found: \(name)") }
        sound?.play()
    }
}

/// Mutes the default output device and restores it. Uses the mute switch
/// where the device has one, otherwise drops the volume to zero.
final class OutputMute {
    private var device: AudioDeviceID = 0
    private var savedMute: UInt32?
    private var savedVolume: Float32?

    func engage() {
        guard let dev = OutputMute.defaultOutput() else { return }
        device = dev
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &addr) {
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr {
                savedMute = v
                var on: UInt32 = 1
                AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &on)
                return
            }
        }
        addr.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr {
            savedVolume = vol
            var zero: Float32 = 0
            AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &zero)
        }
    }

    func release() {
        guard device != 0 else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if var m = savedMute {
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
        if var v = savedVolume {
            addr.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
        savedMute = nil
        savedVolume = nil
        device = 0
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }
}
