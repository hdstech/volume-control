import SwiftUI

struct AppVolumeRow: View {
    let app: AudioAppItem

    @Environment(AudioController.self) private var controller
    // Declared as a plain `State` value: the Command Line Tools lack the plugin behind the `@State` macro.
    private let hover = State(initialValue: false)
    private var isHovering: Bool { hover.wrappedValue }

    var body: some View {
        let setting = controller.setting(for: app.id)

        HStack(spacing: 14) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .opacity(app.isPlaying ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !app.isPlaying {
                        Text("Paused")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(percentText(for: setting))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(setting.isUnity ? .tertiary : .secondary)
                        .contentTransition(.numericText())
                        .onTapGesture(count: 2) { controller.reset(app.id) }
                        .help("Double-click to reset to 100%")
                }

                HStack(spacing: 10) {
                    Button {
                        controller.toggleMute(app.id)
                    } label: {
                        Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                              variableValue: Double(min(setting.volume, 1)))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(setting.muted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(setting.muted ? "Unmute" : "Mute")

                    Slider(
                        value: Binding(
                            get: { Double(setting.volume) },
                            set: { controller.setVolume(Float($0), for: app.id) }
                        ),
                        in: 0...Double(controller.maxVolume)
                    )
                    .controlSize(.small)
                    .opacity(setting.muted ? 0.45 : 1)
                }

                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !app.isPlaying)) { _ in
                    LevelMeterView(peak: app.isPlaying ? controller.level(for: app.id) ?? 0 : 0)
                }
                // Line the meter up with the slider track (mute button width + spacing).
                .padding(.leading, 32)
                .padding(.trailing, 2)
                .opacity(controller.permission == .denied ? 0 : (app.isPlaying ? 1 : 0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .contextMenu {
            Button(setting.muted ? "Unmute" : "Mute") { controller.toggleMute(app.id) }
            Button("Reset to 100%") { controller.reset(app.id) }
                .disabled(setting.isUnity)
        }
    }

    private func percentText(for setting: AppSetting) -> String {
        setting.muted ? "Muted" : "\(Int((setting.volume * 100).rounded()))%"
    }
}
