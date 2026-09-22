import AudioToolbox
import CoreAudio

/// Mutes the Mac's built-in speakers while the microphone listens, so sound from
/// the speakers is not transcribed. Headphones and other outputs are left alone.
/// The output comes back only if this guard muted it.
@MainActor
final class SpeakerGuard {
    private enum Change { case muted(AudioDeviceID), volume(AudioDeviceID, Float32) }
    private var change: Change?

    func engage() {
        guard change == nil, let device = Self.defaultOutput(), Self.isBuiltIn(device) else { return }
        if Self.isSettable(device, Self.mute) {
            guard Self.readUInt32(device, Self.mute) == 0, Self.writeUInt32(device, Self.mute, 1) else { return }
            change = .muted(device)
        } else if Self.isSettable(device, Self.volume), let level = Self.readFloat(device, Self.volume), level > 0,
                  Self.writeFloat(device, Self.volume, 0) {
            change = .volume(device, level)
        }
    }

    func release() {
        guard let change else { return }
        self.change = nil
        switch change {
        case .muted(let device): _ = Self.writeUInt32(device, Self.mute, 0)
        case .volume(let device, let level): _ = Self.writeFloat(device, Self.volume, level)
        }
    }

    private static var mute: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static var volume: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func isBuiltIn(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    private static func isSettable(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address) else { return false }
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func readUInt32(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address, value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func writeUInt32(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        var address = address, value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func readFloat(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Float32? {
        var address = address, value = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func writeFloat(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress, _ value: Float32) -> Bool {
        var address = address, value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}
