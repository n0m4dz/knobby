import CoreAudio
import Foundation

/// A process known to the audio HAL (has or had an audio client connection).
struct AudioProcessInfo {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

enum AudioProcessList {
    static func all() -> [AudioProcessInfo] {
        let ids: [AudioObjectID] = CA.getArray(CA.system, CA.addr(kAudioHardwarePropertyProcessObjectList))
        return ids.compactMap { objectID in
            let pid: pid_t = CA.get(objectID, CA.addr(kAudioProcessPropertyPID), default: pid_t(-1))
            guard pid > 0 else { return nil }
            return AudioProcessInfo(
                objectID: objectID,
                pid: pid,
                bundleID: CA.getString(objectID, CA.addr(kAudioProcessPropertyBundleID)),
                isRunningOutput: CA.get(objectID, CA.addr(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0)
        }
    }
}
