import CoreAudio
import Foundation
import os

/// What a TapEngine captures.
enum TapTarget {
    /// Audio of a single process (per-app volume / redirect).
    case process(AudioObjectID)
    /// All system audio except the given processes (software volume for
    /// devices without hardware volume, e.g. HDMI/DisplayPort displays).
    case globalExcluding([AudioObjectID])
}

struct TapEngineError: LocalizedError {
    enum Kind {
        case permission
        case other
    }

    let message: String
    let kind: Kind
    var errorDescription: String? { message }

    init(message: String, kind: Kind = .other) {
        self.message = message
        self.kind = kind
    }
}

/// Captures audio with a Core Audio process tap (the tapped processes are muted
/// at the HAL), then plays it back through the chosen output device with a gain
/// applied via a private aggregate device and an IO proc.
final class TapEngine {
    private(set) var target: TapTarget
    private(set) var outputUID: String?

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let gainState = OSAllocatedUnfairLock(initialState: Float(1))

    var gain: Float {
        get { gainState.withLock { $0 } }
        set { gainState.withLock { $0 = newValue } }
    }

    init(target: TapTarget) {
        self.target = target
    }

    deinit {
        stop()
    }

    /// Replaces the tap target; restarts the engine in place when it is running.
    func update(target newTarget: TapTarget) throws {
        target = newTarget
        if let uid = outputUID {
            try start(outputDeviceUID: uid)
        }
    }

    func start(outputDeviceUID: String) throws {
        stop()

        let description: CATapDescription
        switch target {
        case .process(let objectID):
            description = CATapDescription(stereoMixdownOfProcesses: [objectID])
        case .globalExcluding(let objectIDs):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: objectIDs)
        }
        description.name = "Knobby Tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTapID = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != 0 else {
            throw TapEngineError(
                message: "Audio control needs the System Audio Recording permission (error \(status)).",
                kind: .permission)
        }
        tapID = newTapID

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Knobby Playthrough",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != 0 else {
            stop()
            throw TapEngineError(message: "Could not create playthrough device (error \(status)).")
        }
        aggregateID = newAggregateID

        let state = gainState
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, outputData, _ in
            TapEngine.render(input: inputData, output: outputData, gain: state.withLock { $0 })
        }
        guard status == noErr, let procID = ioProcID else {
            stop()
            throw TapEngineError(message: "Could not create audio IO proc (error \(status)).")
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw TapEngineError(message: "Could not start playthrough (error \(status)).")
        }
        outputUID = outputDeviceUID
    }

    func stop() {
        if let procID = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        outputUID = nil
    }

    /// Copies tap input to the output buffers, mapping channels round-robin and
    /// applying the gain. Runs on the HAL IO thread — no allocation or locks
    /// beyond the single gain load.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gain: Float) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        guard let inputBuffer = inputList.first(where: { $0.mData != nil }) else {
            for buffer in outputList {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return
        }

        let inChannels = max(Int(inputBuffer.mNumberChannels), 1)
        let inFrames = Int(inputBuffer.mDataByteSize) / (MemoryLayout<Float32>.size * inChannels)
        let inSamples = inputBuffer.mData!.assumingMemoryBound(to: Float32.self)

        var channelOffset = 0
        for buffer in outputList {
            guard let data = buffer.mData else { continue }
            let outChannels = max(Int(buffer.mNumberChannels), 1)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * outChannels)
            let outSamples = data.assumingMemoryBound(to: Float32.self)
            let frames = min(inFrames, outFrames)

            for frame in 0..<frames {
                for channel in 0..<outChannels {
                    let sourceChannel = (channelOffset + channel) % inChannels
                    outSamples[frame * outChannels + channel] = inSamples[frame * inChannels + sourceChannel] * gain
                }
            }
            if frames < outFrames {
                let start = frames * outChannels
                let end = outFrames * outChannels
                for index in start..<end {
                    outSamples[index] = 0
                }
            }
            channelOffset += outChannels
        }
    }
}
