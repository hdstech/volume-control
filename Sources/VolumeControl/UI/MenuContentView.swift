import SwiftUI

struct MenuContentView: View {
    @Environment(AudioController.self) private var controller

    private static let rowHeight: CGFloat = 76
    private static let tabRowHeight: CGFloat = 46
    private static let hintHeight: CGFloat = 26
    private static let maxListHeight: CGFloat = 470

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            if controller.permission == .denied {
                NoticeView(
                    symbol: "lock.shield",
                    tint: .orange,
                    title: "Audio access is off",
                    message: "Volume Control needs permission to capture app audio before it can change an app's level.",
                    actionTitle: "Open System Settings",
                    action: AudioCapturePermission.openSystemSettings
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            if let message = controller.errorMessage {
                NoticeView(
                    symbol: "exclamationmark.triangle",
                    tint: .red,
                    title: "Something went wrong",
                    message: message,
                    actionTitle: "Dismiss",
                    action: controller.dismissError
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            content

            Divider()
                .padding(.horizontal, 20)

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            WindowVisibilityReader(contentSize: proxy.size) { isVisible in
                if isVisible { controller.refreshPermission() }
                controller.setMetering(isVisible)
            }
        })
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Volume Control")
                    .font(.system(size: 15, weight: .semibold))
                if let device = controller.outputDevice {
                    Label(device.name, systemImage: device.symbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            SettingsMenu()
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.apps.isEmpty {
            EmptyStateView()
                .padding(.vertical, 36)
                .padding(.horizontal, 24)
        } else if estimatedListHeight > Self.maxListHeight {
            ScrollView {
                rows
            }
            .frame(height: Self.maxListHeight)
            .scrollIndicators(.automatic)
        } else {
            rows
        }
    }

    private var estimatedListHeight: CGFloat {
        controller.apps.reduce(12) { height, app in
            let tabs = CGFloat(controller.tabs(for: app.id).count)
            let hint = controller.needsBrowserExtension(app.id) ? Self.hintHeight : 0
            return height + Self.rowHeight + tabs * Self.tabRowHeight + hint
        }
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(controller.apps) { app in
                VStack(spacing: 0) {
                    AppVolumeRow(app: app)
                    ForEach(controller.tabs(for: app.id)) { tab in
                        TabVolumeRow(tab: tab)
                    }
                    if controller.needsBrowserExtension(app.id) {
                        BrowserExtensionHint()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.2), value: controller.apps.map(\.id))
        .animation(.easeOut(duration: 0.2), value: controller.browserBridge.tabsByBrowser.values.joined().map(\.id))
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("q")
            .help("Quit Volume Control (⌘Q)")
        }
    }

    private var summary: String {
        let playing = controller.apps.filter(\.isPlaying).count
        switch playing {
        case 0: return "Idle"
        case 1: return "1 app playing"
        default: return "\(playing) apps playing"
        }
    }
}

private struct SettingsMenu: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        Menu {
            Toggle("Allow Boost up to 150%", isOn: Binding(
                get: { controller.allowBoost },
                set: { controller.setAllowBoost($0) }
            ))
            Toggle("Launch at Login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            Divider()
            Button("Reset All to 100%", action: controller.resetAll)
                .disabled(controller.settings.isEmpty)
            Divider()
            Button("Show Browser Extension…", action: controller.revealBrowserExtension)
            Divider()
            Button("Quit Volume Control") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Options")
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("Nothing is playing")
                .font(.system(size: 13, weight: .semibold))
            Text("Apps show up here as soon as they play sound.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct NoticeView: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}
