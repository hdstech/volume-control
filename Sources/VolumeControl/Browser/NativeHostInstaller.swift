import Foundation

/// Registers this executable as the native-messaging host for the companion extension in every
/// installed Chromium-based browser. Rewritten on each launch so the path follows the app if it moves.
enum NativeHostInstaller {
    static let hostName = "com.hdstech.volumecontrol"
    static let extensionID = "hflddabljkphjadncmnphhphfdnnfbpp"

    /// Support directories (under ~/Library/Application Support) that contain `NativeMessagingHosts`.
    private static let browserDirectories = [
        "Google/Chrome",
        "Google/Chrome Beta",
        "Google/Chrome Dev",
        "Google/Chrome Canary",
        "Chromium",
        "Microsoft Edge",
        "BraveSoftware/Brave-Browser",
        "Vivaldi",
        "Arc/User Data",
    ]

    static func install() {
        guard let executable = Bundle.main.executablePath, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Volume Control per-tab bridge",
            "path": executable,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return
        }

        let fileManager = FileManager.default
        let support = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for directory in browserDirectories {
            let browserURL = support.appendingPathComponent(directory, isDirectory: true)
            guard fileManager.fileExists(atPath: browserURL.path) else { continue }
            let hostsURL = browserURL.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let manifestURL = hostsURL.appendingPathComponent("\(hostName).json")
            if (try? Data(contentsOf: manifestURL)) == data { continue }
            try? fileManager.createDirectory(at: hostsURL, withIntermediateDirectories: true)
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    /// The unpacked extension shipped inside the app bundle, for "Load unpacked" in the browser.
    static var bundledExtensionURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension", isDirectory: true)
    }
}
