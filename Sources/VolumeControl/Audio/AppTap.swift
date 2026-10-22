import CAtomics
import CoreAudio
import Foundation
import VolumeControlKit

/// Raw pointers shared with the real-time callback, so the callback never touches ARC or locks.
private struct RenderState: @unchecked Sendable {
    let targetGain: UnsafeMutablePointer<UInt32>
    let currentGain: UnsafeMutablePointer<UInt32>
    let outputEnabled: UnsafeMutablePointer<UInt32>
    let level: UnsafeMutablePointer<UInt32>
    let sampleRate: Float

    init(target: Float, current: Float, outputEnabled enabled: Bool, sampleRate: Float) {
        targetGain = .allocate(capacity: 1)
        targetGain.initialize(to: target.bitPattern)
        currentGain = .allocate(capacity: 1)
        currentGain.initialize(to: current.bitPattern)
        outputEnabled = .allocate(capacity: 1)
        outputEnabled.initialize(to: enabled ? 1 : 0)
        level = .allocate(capacity: 1)
        level.initialize(to: Float(0).bitPattern)
        self.sampleRate = sampleRate
    }

    func deallocate() {
        targetGain.deallocate()
        currentGain.deallocate()
        outputEnabled.deallocate()
        level.deallocate()
    }
}

/// A Core Audio process tap on one app's processes, read through a private aggregate device built on
/// the current output device.
///
/// In `.volume` mode the app's own output is muted and its audio is replayed scaled by a gain.
/// In `.meter` mode the app plays normally and the tap is only read to measure its level.
final class AppTap {
    enum Mode {
        case volume
        case meter
    }

    let processObjects: Set<AudioObjectID>
    let outputUID: String
    private(set) var mode: Mode

    private let output: OutputDevice
    private let state: RenderState
    private var tapDescription: CATapDescription?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private var isInvalidated = false

    init(processObjects: Set<AudioObjectID>, output: OutputDevice, mode: Mode, gain: Float, startingGain: Float) {
        self.processObjects = processObjects
        self.output = output
        self.outputUID = output.uid
        self.mode = mode
        self.state = RenderState(
            target: gain,
            current: startingGain,
            outputEnabled: mode == .volume,
            sampleRate: Float(output.sampleRate)
        )
    }

    deinit {
        invalidate()
    }

    /// Peak level of what the app is currently producing (after gain), 0...1+, with release smoothing.
    var level: Float {
        Float(bitPattern: vc_atomic_load_u32(state.level))
    }

    func setGain(_ gain: Float) {
        vc_atomic_store_u32(state.targetGain, gain.bitPattern)
    }

    /// Switches mode on the live tap. Returns false if Core Audio rejected the change; the tap is then
    /// left in its previous mode and the caller should rebuild it.
    func setMode(_ newMode: Mode) -> Bool {
        guard newMode != mode else { return true }
        // Order the steps so a switch can drop a few milliseconds of audio but never play it twice.
        switch newMode {
        case .volume:
            guard updateMuteBehavior(.mutedWhenTapped) else { return false }
            vc_atomic_store_u32(state.currentGain, Float(1).bitPattern)
            vc_atomic_store_u32(state.outputEnabled, 1)
        case .meter:
            vc_atomic_store_u32(state.outputEnabled, 0)
            guard updateMuteBehavior(.unmuted) else {
                vc_atomic_store_u32(state.outputEnabled, 1)
                return false
            }
        }
        mode = newMode
        return true
    }

    func start() throws {
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjects.sorted())
        tapDescription.uuid = UUID()
        tapDescription.name = "Volume Control"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = mode == .volume ? .mutedWhenTapped : .unmuted
        self.tapDescription = tapDescription
        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "Creating the process tap")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volume Control",
            kAudioAggregateDeviceUIDKey: "com.hdstech.VolumeControl.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: output.uid],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
            "Creating the aggregate device"
        )

        let state = self.state
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, outputData, _ in
                let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                let output = UnsafeMutableAudioBufferListPointer(outputData)
                // The tap's stream comes after any input streams belonging to the output device.
                let tap = input.last

                let peak: Float
                if vc_atomic_load_u32(state.outputEnabled) != 0 {
                    let target = Float(bitPattern: vc_atomic_load_u32(state.targetGain))
                    let start = Float(bitPattern: vc_atomic_load_u32(state.currentGain))
                    peak = AudioRenderer.render(tap: tap, into: output, from: start, to: target)
                    vc_atomic_store_u32(state.currentGain, target.bitPattern)
                } else {
                    AudioRenderer.silence(output)
                    peak = LevelMeter.peak(of: tap)
                }

                let previous = Float(bitPattern: vc_atomic_load_u32(state.level))
                let level = LevelMeter.decayed(
                    previous: previous,
                    peak: peak,
                    frames: LevelMeter.frameCount(of: tap),
                    sampleRate: state.sampleRate
                )
                vc_atomic_store_u32(state.level, level.bitPattern)
            },
            "Creating the audio callback"
        )

        disableOutputDeviceInputStreams()
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio")
        isStarted = true
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true

        if aggregateID != kAudioObjectUnknown {
            if isStarted { AudioDeviceStop(aggregateID, ioProcID) }
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        state.deallocate()
    }

    private func updateMuteBehavior(_ behavior: CATapMuteBehavior) -> Bool {
        guard let tapDescription, tapID != kAudioObjectUnknown else { return false }
        let previous = tapDescription.muteBehavior
        tapDescription.muteBehavior = behavior

        var address = AudioObject.address(kAudioTapPropertyDescription)
        var description = tapDescription
        let status = withUnsafeMutablePointer(to: &description) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status != noErr {
            tapDescription.muteBehavior = previous
        }
        return status == noErr
    }

    /// Output devices that also have inputs (USB headsets, audio interfaces) would otherwise open their
    /// microphones through the aggregate device. Turn those streams off for our callback.
    private func disableOutputDeviceInputStreams() {
        guard output.inputStreamCount > 0, let ioProcID else { return }

        var address = AudioObject.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr, size > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))

        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, raw) == noErr else { return }

        let streamCount = Int(usage.pointee.mNumberStreams)
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let flags = (raw + flagsOffset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<min(output.inputStreamCount, streamCount) {
            flags[index] = 0
        }
        AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, raw)
    }
}
