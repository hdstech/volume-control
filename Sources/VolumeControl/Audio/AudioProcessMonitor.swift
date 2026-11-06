import CoreAudio
import Foundation

struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    var isRunningOutput: Bool
}

/// Tracks Core Audio's process objects and whether each one is currently sending audio to an output.
///
/// On macOS 26+, listeners for `kAudioProcessPropertyIsRunningOutput` often never fire even though
/// reads are correct. `kAudioProcessPropertyIsRunning` does notify, so we listen to that and
/// re-read the output flag on every wakeup.
@MainActor
final class AudioProcessMonitor {
    var onChange: (@MainActor () -> Void)?
    private(set) var processes: [AudioObjectID: AudioProcess] = [:]

    private var listListener: PropertyListener?
    private var runningListeners: [AudioObjectID: PropertyListener] = [:]
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
        runningListeners.values.forEach { $0.invalidate() }
        runningListeners = [:]
    }

    /// Re-enumerates process objects and re-reads output-running state.
    /// Useful when the menu opens, in case a Core Audio listener was missed.
    func refresh() {
        refreshList()
    }

    private func refreshList() {
        let ids = (try? AudioObject.readArray(
            AudioObject.system,
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self
        )) ?? []
        let current = Set(ids)
        var changed = false

        for gone in Set(processes.keys).subtracting(current) {
            runningListeners.removeValue(forKey: gone)?.invalidate()
            processes[gone] = nil
            changed = true
        }
        ignored.formIntersection(current)

        for id in ids {
            if var existing = processes[id] {
                let running = Self.isRunningOutput(id)
                if running != existing.isRunningOutput {
                    existing.isRunningOutput = running
                    processes[id] = existing
                    changed = true
                }
                continue
            }
            guard !ignored.contains(id) else { continue }
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
            // IsRunning is the reliable change notification on recent macOS; we still *read*
            // IsRunningOutput to decide whether the process is playing to an output.
            runningListeners[id] = PropertyListener(
                object: id,
                selector: kAudioProcessPropertyIsRunning
            ) { [weak self] in
                self?.refreshOutputState(of: id)
            }
            changed = true
        }

        if changed { onChange?() }
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
