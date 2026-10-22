import AppKit
import SwiftUI

@main
enum Entry {
    @MainActor
    static func main() {
        // Browsers launch native-messaging hosts with the calling extension's origin as an argument.
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("chrome-extension://") }) {
            NativeMessagingHost.run()
        }
        if CommandLine.arguments.contains("--list") {
            Diagnostics.printAudioProcesses()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let arguments = CommandLine.arguments
            Diagnostics.renderSnapshots(to: index + 1 < arguments.count ? arguments[index + 1] : ".")
            return
        }
        VolumeControlApp.main()
    }
}

struct VolumeControlApp: App {
    private let controller = AudioController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(controller)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
