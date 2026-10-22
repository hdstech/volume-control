import CoreAudio
import Foundation

struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    var isRunningOutput: Bool
}

/// Tracks Core Audio's process objects and whether each one is currently sending audio to an output.
@MainActor
final class AudioProcessMonitor {
    var onChange: (@MainActor () -> Void)?
    private(set) var processes: [AudioObjectID: AudioProcess] = [:]

    private var listListener: PropertyListener?
    private var outputListeners: [AudioObjectID: PropertyListener] = [:]
    private var ignored: Set<AudioObjectID> = []
    private let ownPID = getpid()

    func start() {
        listListener = PropertyListener(
            object: AudioObject.system,
            selector: kAudioHardwarePropertyProcessObjectList
        ) { [weak self] in
            self?.refreshList()
        }
        refreshList()
    }

    func stop() {
        listListener?.invalidate()
        outputListeners.values.forEach { $0.invalidate() }
        outputListeners = [:]
    }

    private func refreshList() {
        let ids = (try? AudioObject.readArray(
            AudioObject.system,
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self
        )) ?? []
        let current = Set(ids)

        for gone in Set(processes.keys).subtracting(current) {
            outputListeners.removeValue(forKey: gone)?.invalidate()
            processes[gone] = nil
        }
        ignored.formIntersection(current)

        for id in ids where processes[id] == nil && !ignored.contains(id) {
            guard let pid = try? AudioObject.read(id, kAudioProcessPropertyPID, default: pid_t(-1)),
                  pid > 0, pid != ownPID else {
                ignored.insert(id)
                continue
            }
            let bundleID = (try? AudioObject.readString(id, kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
            processes[id] = AudioProcess(
                objectID: id,
                pid: pid,
                bundleID: bundleID,
                isRunningOutput: Self.isRunningOutput(id)
            )
            outputListeners[id] = PropertyListener(
                object: id,
                selector: kAudioProcessPropertyIsRunningOutput
            ) { [weak self] in
                self?.refreshOutputState(of: id)
            }
        }
        onChange?()
    }

    private func refreshOutputState(of id: AudioObjectID) {
        guard var process = processes[id] else { return }
        let running = Self.isRunningOutput(id)
        guard running != process.isRunningOutput else { return }
        process.isRunningOutput = running
        processes[id] = process
        onChange?()
    }

    private static func isRunningOutput(_ id: AudioObjectID) -> Bool {
        ((try? AudioObject.read(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
    }
}
