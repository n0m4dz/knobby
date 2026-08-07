import CoreAudio
import Foundation

/// Thin typed wrappers around the CoreAudio HAL property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let outputScope = kAudioDevicePropertyScopeOutput
    static let inputScope = kAudioDevicePropertyScopeInput

    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(objectID, &a)
    }

    static func isSettable(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(objectID, &a, &settable) == noErr && settable.boolValue
    }

    static func get<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, default defaultValue: T) -> T {
        var a = address
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = AudioObjectGetPropertyData(objectID, &a, 0, nil, &size, &value)
        return status == noErr ? value : defaultValue
    }

    static func getArray<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [T] {
        var a = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &a, 0, nil, &size, raw) == noErr else { return [] }
        let buffer = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var a = address
        guard AudioObjectHasProperty(objectID, &a) else { return nil }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(objectID, &a, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    static func set<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = address
        var v = value
        return AudioObjectSetPropertyData(objectID, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    /// Resolves the HAL process object for a pid (used to tap or exclude specific processes).
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { pidPtr in
            AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object)
        }
        guard status == noErr, object != 0 else { return nil }
        return object
    }
}
