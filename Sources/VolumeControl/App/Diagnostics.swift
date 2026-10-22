import AppKit
import CoreAudio
import SwiftUI

enum Diagnostics {
    /// `VolumeControl --list` prints what the app sees, without starting the UI or creating any taps.
    @MainActor
    static func printAudioProcesses() {
        let monitor = AudioProcessMonitor()
        let resolver = AppResolver()
        let devices = OutputDeviceMonitor()
        monitor.start()
        devices.start()

        if let device = devices.device {
            print("Output device: \(device.name) [\(device.uid)] \(Int(device.sampleRate)) Hz, input streams: \(device.inputStreamCount)")
        } else {
            print("Output device: none")
        }
        print("Audio capture permission: \(AudioCapturePermission.status)")
        print("")

        let rows = monitor.processes.values
            .sorted { $0.pid < $1.pid }
            .map { process -> String in
                let app = resolver.identity(for: process)
                let state = process.isRunningOutput ? "PLAYING" : "idle   "
                let kind = app.isApp ? "" : "  [hidden]"
                let running = ((try? AudioObject.read(process.objectID, kAudioProcessPropertyIsRunning, default: UInt32(0))) ?? 0) != 0
                let devices = ((try? AudioObject.readArray(
                    process.objectID,
                    kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeOutput,
                    of: AudioObjectID.self
                )) ?? []).map(String.init).joined(separator: ",")
                return "\(state)  pid \(process.pid)  object \(process.objectID)  io:\(running ? "on " : "off")  out-devices:[\(devices)]  \(process.bundleID ?? "-")  →  \(app.name) (\(app.id))\(kind)"
            }
        rows.forEach { print($0) }
        monitor.stop()
    }

    /// `VolumeControl --snapshot <directory>` renders the menu with sample rows to light and dark PNGs.
    @MainActor
    static func renderSnapshots(to directory: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let controller = AudioController()
        let samples: [(String, String, Bool, AppSetting)] = [
            ("com.apple.Music", "Music", true, AppSetting(volume: 0.8, muted: false)),
            ("com.google.Chrome", "Google Chrome", true, AppSetting()),
            ("com.apple.Safari", "Safari", false, AppSetting(volume: 0.35, muted: false)),
            ("us.zoom.xos", "zoom.us", true, AppSetting(volume: 0.6, muted: true)),
        ]
        controller.loadPreviewState(
            samples.map { id, name, playing, _ in
                AudioAppItem(id: id, name: name, icon: icon(for: id), isPlaying: playing)
            },
            settings: Dictionary(uniqueKeysWithValues: samples.map { ($0.0, $0.3) }),
            levels: ["com.apple.Music": 0.42, "com.google.Chrome": 0.93, "us.zoom.xos": 0]
        )
        controller.browserBridge.loadPreview(["com.google.Chrome": [
            BrowserTab(connectionID: 1, tabID: 1, title: "Lofi beats to code to – YouTube", host: "youtube.com",
                       isAudible: true, isMuted: false, volume: 0.7, faviconURL: nil),
            BrowserTab(connectionID: 1, tabID: 2, title: "Weekly sync – Google Meet", host: "meet.google.com",
                       isAudible: true, isMuted: true, volume: 1, faviconURL: nil),
        ]])

        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let root = MenuContentView()
                .environment(controller)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: root)
            hosting.appearance = NSAppearance(named: appearanceName)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("menu-\(suffix).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("Wrote \(url.path)")
        }
    }

    private static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
