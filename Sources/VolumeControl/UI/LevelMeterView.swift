import SwiftUI
import VolumeControlKit

/// Slim horizontal peak meter on a decibel scale: green through the normal range, warming to red near 0 dBFS.
struct LevelMeterView: View {
    let peak: Float

    private static let gradient = LinearGradient(
        stops: [
            .init(color: .green.opacity(0.85), location: 0),
            .init(color: .green.opacity(0.85), location: 0.72),
            .init(color: .yellow, location: 0.86),
            .init(color: .red, location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        let position = LevelMeter.position(forPeak: peak)
        Capsule()
            .fill(Color.primary.opacity(0.07))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Self.gradient)
                    .mask(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().frame(width: proxy.size.width * position)
                        }
                    }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Level")
            .accessibilityValue("\(Int(position * 100)) percent")
    }
}

/// Reports whether the hosting window is actually on screen. The menu bar panel stays alive while hidden,
/// so this, rather than `onAppear`, decides when meters run.
///
/// Also keeps the panel sized to `contentSize`: `MenuBarExtra` doesn't reliably shrink its window when the
/// content gets shorter, which leaves the content floating in the middle of empty space.
struct WindowVisibilityReader: NSViewRepresentable {
    let contentSize: CGSize
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
        view.contentSize = contentSize
        view.scheduleFit()
    }

    final class VisibilityView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        var contentSize: CGSize = .zero
        private var observer: NSObjectProtocol?
        private var isFitScheduled = false

        /// Deferred so the window isn't resized in the middle of a SwiftUI layout pass.
        func scheduleFit() {
            guard !isFitScheduled else { return }
            isFitScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFitScheduled = false
                self.fitWindow()
            }
        }

        private func fitWindow() {
            guard let window, contentSize.width > 0, contentSize.height > 0 else { return }
            let current = window.contentRect(forFrameRect: window.frame)
            let size = NSSize(width: contentSize.width.rounded(), height: contentSize.height.rounded())
            guard abs(current.width - size.width) >= 1 || abs(current.height - size.height) >= 1 else { return }
            // Keep the top edge pinned under the menu bar.
            let content = NSRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
            window.setFrame(window.frameRect(forContentRect: content), display: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else {
                onChange?(false)
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            let isVisible = window?.occlusionState.contains(.visible) ?? false
            if isVisible { fitWindow() }
            onChange?(isVisible)
        }
    }
}
