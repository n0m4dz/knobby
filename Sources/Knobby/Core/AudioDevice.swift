import AudioToolbox
import CoreAudio
import Foundation

/// 'vmvc' — settable virtual volume selector (lives in AudioToolbox's
/// AudioHardwareService.h, works with the plain AudioObject property API).
private let kVirtualMainVolume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let hasOutput: Bool
    let hasInput: Bool

    var symbolName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return hasOutput ? "laptopcomputer" : "mic"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            return "speaker.wave.2"
        }
    }

    static func all() -> [AudioDevice] {
        let ids: [AudioDeviceID] = CA.getArray(CA.system, CA.addr(kAudioHardwarePropertyDevices))
        return ids.compactMap { id in
            guard let uid = CA.getString(id, CA.addr(kAudioDevicePropertyDeviceUID)), !uid.isEmpty,
                  let name = CA.getString(id, CA.addr(kAudioObjectPropertyName)), !name.isEmpty else { return nil }
            let outputStreams: [AudioStreamID] = CA.getArray(id, CA.addr(kAudioDevicePropertyStreams, CA.outputScope))
            let inputStreams: [AudioStreamID] = CA.getArray(id, CA.addr(kAudioDevicePropertyStreams, CA.inputScope))
            guard !outputStreams.isEmpty || !inputStreams.isEmpty else { return nil }
            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                transportType: CA.get(id, CA.addr(kAudioDevicePropertyTransportType), default: UInt32(0)),
                hasOutput: !outputStreams.isEmpty,
                hasInput: !inputStreams.isEmpty)
        }
    }

    static func uid(of id: AudioDeviceID) -> String? {
        guard id != 0 else { return nil }
        return CA.getString(id, CA.addr(kAudioDevicePropertyDeviceUID))
    }

    /// Hardware volume, or nil when the device has no controllable volume (HDMI/DisplayPort displays).
    static func volume(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Float? {
        guard id != 0 else { return nil }
        let address = CA.addr(kVirtualMainVolume, scope)
        guard CA.has(id, address), CA.isSettable(id, address) else { return nil }
        let value: Float = CA.get(id, address, default: -1)
        guard value >= 0 else { return nil }
        return min(max(value, 0), 1)
    }

    static func setVolume(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope, _ volume: Float) {
        guard id != 0 else { return }
        CA.set(id, CA.addr(kVirtualMainVolume, scope), min(max(volume, 0), 1))
    }

    static func canMute(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        id != 0 && CA.isSettable(id, CA.addr(kAudioDevicePropertyMute, scope))
    }

    static func isMuted(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        guard id != 0 else { return false }
        return CA.get(id, CA.addr(kAudioDevicePropertyMute, scope), default: UInt32(0)) == 1
    }

    static func setMuted(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope, _ muted: Bool) {
        guard id != 0 else { return }
        CA.set(id, CA.addr(kAudioDevicePropertyMute, scope), UInt32(muted ? 1 : 0))
    }
}
