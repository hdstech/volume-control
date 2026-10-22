import AppKit
import CoreAudio
import Observation
import ServiceManagement
import VolumeControlKit

@MainActor
@Observable
final class AudioController {
    /// How long an app stays listed after it stops playing, so pausing doesn't make rows jump around.
    private static let lingerInterval: TimeInterval = 8
    /// How long an app must sit at 100% before its volume tap is released, so dragging through 100%
    /// doesn't flip the tap back and forth.
    private static let settleDelay: Duration = .seconds(3)

    private(set) var apps: [AudioAppItem] = []
    private(set) var settings: [String: AppSetting]
    private(set) var outputDevice: OutputDevice?
    private(set) var permission: AudioCapturePermission.Status
    private(set) var errorMessage: String?
    private(set) var allowBoost: Bool
    private(set) var launchAtLogin: Bool

    var maxVolume: Float { allowBoost ? GainMath.boostLimit : 1 }

    /// Tabs reported by the companion browser extension.
    let browserBridge = BrowserBridge()

    @ObservationIgnored private let processMonitor = AudioProcessMonitor()
    @ObservationIgnored private let deviceMonitor = OutputDeviceMonitor()
    @ObservationIgnored private let resolver = AppResolver()
    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var groups: [String: [AudioProcess]] = [:]
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private var lastActive: [String: Date] = [:]
    @ObservationIgnored private var settleTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var isRequestingPermission = false
    @ObservationIgnored private var isMetering = false
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private var previewLevels: [String: Float] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        settings = SettingsStore.loadAppSettings()
        allowBoost = SettingsStore.allowBoost
        permission = AudioCapturePermission.status
        launchAtLogin = SMAppService.mainApp.status == .enabled

        deviceMonitor.onChange = { [weak self] in self?.outputDeviceChanged() }
        deviceMonitor.start()
        outputDevice = deviceMonitor.device

        processMonitor.onChange = { [weak self] in self?.reconcile() }
        processMonitor.start()

        if Bundle.main.bundleURL.pathExtension == "app" {
            NativeHostInstaller.install()
            browserBridge.start()
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAllTaps() }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resolver.forgetUnresolved()
                self?.reconcile()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.removeAllTaps()
                self?.browserBridge.stop()
            }
        })
    }

    // MARK: - Browser tabs

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
    ]

    func tabs(for appID: String) -> [BrowserTab] {
        browserBridge.tabsByBrowser[appID] ?? []
    }

    /// True for a Chromium browser that hasn't connected through the companion extension.
    func needsBrowserExtension(_ appID: String) -> Bool {
        Self.chromiumBrowsers.contains(appID) && !browserBridge.connectedBrowsers.contains(appID)
    }

    func setVolume(_ volume: Float, for tab: BrowserTab) {
        var value = volume
        if abs(value - 1) < 0.02 { value = 1 }
        browserBridge.setVolume(value, for: tab)
    }

    func toggleMute(_ tab: BrowserTab) {
        browserBridge.setMuted(!tab.isMuted, for: tab)
    }

    func favicon(for tab: BrowserTab) -> NSImage? {
        tab.faviconURL.flatMap { browserBridge.favicons[$0] }
    }

    func revealBrowserExtension() {
        guard let url = NativeHostInstaller.bundledExtensionURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - User actions

    func setting(for id: String) -> AppSetting {
        settings[id] ?? AppSetting()
    }

    func setVolume(_ volume: Float, for id: String) {
        var clamped = min(max(volume, 0), maxVolume)
        if abs(clamped - 1) < 0.02 { clamped = 1 }
        update(id) {
            $0.volume = clamped
            $0.muted = false
        }
    }

    func toggleMute(_ id: String) {
        update(id) { $0.muted.toggle() }
    }

    func reset(_ id: String) {
        update(id) { $0 = AppSetting() }
    }

    func resetAll() {
        let ids = Array(settings.keys)
        settings = [:]
        SettingsStore.saveAppSettings(settings)
        ids.forEach(applyTap)
    }

    func setAllowBoost(_ enabled: Bool) {
        allowBoost = enabled
        SettingsStore.allowBoost = enabled
        guard !enabled else { return }
        for (id, setting) in settings where setting.volume > 1 {
            update(id) { $0.volume = 1 }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshPermission() {
        let current = AudioCapturePermission.status
        guard current != permission else { return }
        permission = current
        reconcile()
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Level meters only run while the menu is on screen; this adds listen-only taps for apps at 100%.
    func setMetering(_ enabled: Bool) {
        guard enabled != isMetering, !isPreview else { return }
        isMetering = enabled
        reconcile()
    }

    /// Current peak level for an app, or nil when nothing is measuring it.
    func level(for id: String) -> Float? {
        if isPreview { return previewLevels[id] }
        return taps[id]?.level
    }

    /// Replaces live state with sample rows for `--snapshot`. Nothing is persisted and no taps are created.
    func loadPreviewState(
        _ items: [AudioAppItem],
        settings previewSettings: [String: AppSetting],
        levels: [String: Float]
    ) {
        isPreview = true
        processMonitor.stop()
        apps = items
        settings = previewSettings
        previewLevels = levels
    }

    // MARK: - State

    private func update(_ id: String, _ change: (inout AppSetting) -> Void) {
        var setting = setting(for: id)
        change(&setting)
        settings[id] = setting.isUnity ? nil : setting
        SettingsStore.saveAppSettings(settings)
        applyTap(for: id)
    }

    private func reconcile() {
        guard !isPreview else { return }
        let now = Date()
        var newGroups: [String: [AudioProcess]] = [:]
        var identities: [String: AppIdentity] = [:]
        for process in processMonitor.processes.values {
            let identity = resolver.identity(for: process)
            newGroups[identity.id, default: []].append(process)
            if identities[identity.id] == nil { identities[identity.id] = identity }
        }
        groups = newGroups
        names = identities.mapValues(\.name)
        resolver.prune(keeping: Set(processMonitor.processes.values.map(\.pid)))

        var items: [AudioAppItem] = []
        var nextExpiry: Date?
        for (id, processes) in newGroups {
            let isPlaying = processes.contains(where: \.isRunningOutput)
            if isPlaying { lastActive[id] = now }

            var isLingering = false
            if !isPlaying, let last = lastActive[id] {
                let expiry = last.addingTimeInterval(Self.lingerInterval)
                if expiry > now {
                    isLingering = true
                    nextExpiry = min(nextExpiry ?? expiry, expiry)
                }
            }

            guard isPlaying || isLingering || taps[id]?.mode == .volume,
                  let identity = identities[id], identity.isApp else { continue }
            items.append(AudioAppItem(id: id, name: identity.name, icon: identity.icon, isPlaying: isPlaying))
        }
        for id in lastActive.keys where newGroups[id] == nil {
            lastActive[id] = nil
        }

        apps = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        scheduleLingerRefresh(at: nextExpiry)

        for id in Set(taps.keys).union(newGroups.keys) {
            applyTap(for: id)
        }
    }

    private func scheduleLingerRefresh(at date: Date?) {
        lingerTask?.cancel()
        guard let date else { return }
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow) + 0.1))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    // MARK: - Taps

    private func applyTap(for id: String) {
        applyTap(for: id, settled: false)
    }

    /// Brings an app's tap in line with its setting:
    /// - not at 100% → volume tap
    /// - at 100%, playing, and the menu is open → listen-only meter tap
    /// - otherwise → no tap
    /// A volume tap that returns to 100% is held for `settleDelay` before it changes.
    private func applyTap(for id: String, settled: Bool) {
        let setting = setting(for: id)
        let gain = GainMath.gain(volume: setting.volume, muted: setting.muted)
        let processes = groups[id] ?? []
        let existing = taps[id]

        guard !processes.isEmpty else {
            removeTap(id)
            return
        }

        if setting.isUnity, let existing, existing.mode == .volume, !settled {
            existing.setGain(gain)
            scheduleSettle(of: id)
            return
        }
        if !setting.isUnity {
            settleTasks.removeValue(forKey: id)?.cancel()
        }

        let isPlaying = processes.contains(where: \.isRunningOutput)
        let mode: AppTap.Mode? = if !setting.isUnity {
            .volume
        } else if isMetering && isPlaying && permission != .denied {
            .meter
        } else {
            nil
        }
        guard let mode else {
            removeTap(id)
            return
        }

        // Tap only processes that are actually producing sound, plus any already tapped that are still alive.
        let alive = Set(processes.map(\.objectID))
        var wanted = Set(processes.filter(\.isRunningOutput).map(\.objectID))
        if let existing {
            wanted.formUnion(existing.processObjects.intersection(alive))
        }
        guard !wanted.isEmpty, let device = deviceMonitor.device else { return }

        if let existing, existing.processObjects == wanted, existing.outputUID == device.uid {
            existing.setGain(gain)
            if existing.setMode(mode) { return }
        }

        guard ensurePermission() else { return }

        let isReplacingVolumeTap = existing?.mode == .volume
        removeTap(id)
        let tap = AppTap(
            processObjects: wanted,
            output: device,
            mode: mode,
            gain: gain,
            startingGain: isReplacingVolumeTap ? gain : 1
        )
        do {
            try tap.start()
            taps[id] = tap
            errorMessage = nil
        } catch {
            tap.invalidate()
            if mode == .volume {
                errorMessage = "Couldn't adjust \(names[id] ?? "this app"): \(error)"
            }
        }
    }

    private func ensurePermission() -> Bool {
        switch permission {
        case .authorized, .unavailable:
            return true
        case .denied:
            return false
        case .undetermined:
            guard !isRequestingPermission else { return false }
            isRequestingPermission = true
            AudioCapturePermission.request { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRequestingPermission = false
                    self.permission = granted ? .authorized : .denied
                    self.reconcile()
                }
            }
            return false
        }
    }

    private func scheduleSettle(of id: String) {
        guard settleTasks[id] == nil else { return }
        settleTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.settleTasks[id] = nil
            guard self.setting(for: id).isUnity else { return }
            self.applyTap(for: id, settled: true)
            self.reconcile()
        }
    }

    private func removeTap(_ id: String) {
        settleTasks.removeValue(forKey: id)?.cancel()
        taps.removeValue(forKey: id)?.invalidate()
    }

    private func removeAllTaps() {
        for id in Array(taps.keys) { removeTap(id) }
    }

    private func outputDeviceChanged() {
        outputDevice = deviceMonitor.device
        rebuildAllTaps()
    }

    private func rebuildAllTaps() {
        deviceMonitor.refresh(notify: false)
        outputDevice = deviceMonitor.device
        removeAllTaps()
        reconcile()
    }
}
