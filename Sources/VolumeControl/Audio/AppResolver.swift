import AppKit
import Darwin
import VolumeControlKit

struct AppIdentity {
    let id: String
    let name: String
    let icon: NSImage
    /// False for daemons and command-line tools, which are kept out of the menu.
    let isApp: Bool
}

/// Maps an audio process (often a helper like `com.apple.WebKit.GPU` or `Google Chrome Helper`)
/// to the user-facing app that owns it.
@MainActor
final class AppResolver {
    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    private static let responsiblePID: ResponsiblePIDFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    private var cache: [pid_t: AppIdentity] = [:]

    func identity(for process: AudioProcess) -> AppIdentity {
        if let cached = cache[process.pid] { return cached }
        let identity = resolve(process)
        cache[process.pid] = identity
        return identity
    }

    func prune(keeping pids: Set<pid_t>) {
        cache = cache.filter { pids.contains($0.key) }
    }

    /// A helper can start playing before macOS has registered its parent app, so lookups that found
    /// no app are retried once another app finishes launching.
    func forgetUnresolved() {
        cache = cache.filter { $0.value.isApp }
    }

    private func resolve(_ process: AudioProcess) -> AppIdentity {
        let candidates = candidatePIDs(startingAt: process.pid)
        for pid in candidates {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return identity(of: app)
            }
        }
        // Menu bar apps (e.g. Raycast) aren't `.regular`, but still own their WebKit and helper processes.
        for pid in candidates.dropFirst() {
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL?.pathExtension == "app" {
                return identity(of: app)
            }
        }

        if let bundleID = process.bundleID {
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            for candidate in BundleIDMatching.parentCandidates(for: bundleID) {
                if let app = running.first(where: { $0.bundleIdentifier == candidate }) {
                    return identity(of: app)
                }
            }
        }

        if let app = NSRunningApplication(processIdentifier: process.pid), app.bundleURL?.pathExtension == "app" {
            return identity(of: app)
        }

        let name = Self.processName(process.pid) ?? process.bundleID ?? "Process \(process.pid)"
        return AppIdentity(
            id: process.bundleID ?? "process:\(name)",
            name: name,
            icon: NSWorkspace.shared.icon(for: .unixExecutable),
            isApp: false
        )
    }

    private func candidatePIDs(startingAt pid: pid_t) -> [pid_t] {
        var candidates = [pid]
        if let responsible = Self.responsiblePID?(pid), responsible > 1, responsible != pid {
            candidates.append(responsible)
        }
        var current = pid
        for _ in 0..<4 {
            guard let parent = Self.parentPID(of: current), parent > 1, !candidates.contains(parent) else { break }
            candidates.append(parent)
            current = parent
        }
        return candidates
    }

    private func identity(of app: NSRunningApplication) -> AppIdentity {
        let name = app.localizedName ?? app.bundleIdentifier ?? "App"
        return AppIdentity(
            id: app.bundleIdentifier ?? "process:\(name)",
            name: name,
            icon: app.icon ?? NSWorkspace.shared.icon(for: .application),
            isApp: true
        )
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
