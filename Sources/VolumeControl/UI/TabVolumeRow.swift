import SwiftUI

/// Leading inset for rows nested under an app: the app row's padding (12) + icon (36) + spacing (14),
/// so nested content lines up with the app's name.
private let nestedInset: CGFloat = 62

/// One browser tab, nested under its browser's row.
struct TabVolumeRow: View {
    let tab: BrowserTab

    @Environment(AudioController.self) private var controller
    private let hover = State(initialValue: false)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            favicon
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(tab.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(tab.host.isEmpty ? tab.title : "\(tab.title)\n\(tab.host)")
                    Spacer(minLength: 8)
                    Text(tab.isMuted ? "Muted" : "\(Int((tab.volume * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(tab.volume == 1 && !tab.isMuted ? .tertiary : .secondary)
                        .onTapGesture(count: 2) { controller.setVolume(1, for: tab) }
                        .help("Double-click to reset to 100%")
                }

                HStack(spacing: 8) {
                    Button {
                        controller.toggleMute(tab)
                    } label: {
                        Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                              variableValue: Double(tab.volume))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tab.isMuted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.isMuted ? "Unmute tab" : "Mute tab")

                    Slider(
                        value: Binding(
                            get: { Double(tab.volume) },
                            set: { controller.setVolume(Float($0), for: tab) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.mini)
                    .opacity(tab.isMuted ? 0.45 : 1)
                }
            }
        }
        .padding(.leading, nestedInset)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(alignment: .leading) {
            // A faint rule under the app icon ties the tabs to their browser.
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1.5)
                .padding(.leading, 30)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hover.wrappedValue ? 0.05 : 0))
                .padding(.leading, nestedInset - 10)
        )
        .contentShape(Rectangle())
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.wrappedValue)
        .contextMenu {
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { controller.toggleMute(tab) }
            Button("Reset to 100%") { controller.setVolume(1, for: tab) }
                .disabled(tab.volume == 1)
        }
    }

    @ViewBuilder
    private var favicon: some View {
        if let image = controller.favicon(for: tab) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

/// Shown under a Chromium browser that hasn't connected through the companion extension.
struct BrowserExtensionHint: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        Button(action: controller.revealBrowserExtension) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 11))
                Text("Add the companion extension to control tabs")
                    .font(.system(size: 11))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Opens the extension folder. In the browser, go to Extensions, turn on Developer mode, and choose Load unpacked.")
        .padding(.leading, nestedInset)
        .padding(.trailing, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
