import AppKit
import Darwin
import Observation

struct BrowserTab: Identifiable, Equatable {
    /// Unique across browsers and profiles: connection plus the browser's tab ID.
    var id: String { "\(connectionID)-\(tabID)" }
    let connectionID: Int
    let tabID: Int
    let title: String
    let host: String
    let isAudible: Bool
    var isMuted: Bool
    var volume: Float
    let faviconURL: URL?
}

/// Accepts connections from native-messaging relays (one per browser profile with the extension
/// installed) and keeps the latest tab list for each browser app, keyed by the browser's bundle ID.
@MainActor
@Observable
final class BrowserBridge {
    private(set) var tabsByBrowser: [String: [BrowserTab]] = [:]
    private(set) var favicons: [URL: NSImage] = [:]

    var connectedBrowsers: Set<String> {
        Set(connections.values.compactMap(\.browserID)).union(tabsByBrowser.keys)
    }

    /// Sample tabs for `--snapshot`.
    func loadPreview(_ tabs: [String: [BrowserTab]]) {
        tabsByBrowser = tabs
    }

    @ObservationIgnored private var listenDescriptor: Int32 = -1
    @ObservationIgnored private var listenSource: DispatchSourceRead?
    @ObservationIgnored private var nextConnectionID = 1
    private var connections: [Int: Connection] = [:]
    @ObservationIgnored private var faviconRequests: Set<URL> = []

    private final class Connection {
        let id: Int
        let descriptor: Int32
        var source: DispatchSourceRead?
        var pending = Data()
        var browserID: String?
        var tabs: [BrowserTab] = []

        init(id: Int, descriptor: Int32) {
            self.id = id
            self.descriptor = descriptor
        }
    }

    func start() {
        let socketURL = BridgeSocket.url
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(socketURL.path)

        guard var address = BridgeSocket.address(for: socketURL.path) else { return }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            return
        }
        chmod(socketURL.path, 0o600)
        listenDescriptor = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptConnection() }
        }
        source.resume()
        listenSource = source
    }

    func stop() {
        for id in Array(connections.keys) { closeConnection(id) }
        listenSource?.cancel()
        if listenDescriptor >= 0 { close(listenDescriptor) }
        listenDescriptor = -1
        unlink(BridgeSocket.url.path)
    }

    // MARK: Commands

    func setVolume(_ volume: Float, for tab: BrowserTab) {
        let clamped = min(max(volume, 0), 1)
        updateTab(tab) { $0.volume = clamped }
        send(["type": "setVolume", "tabId": tab.tabID, "volume": Double(clamped)], to: tab.connectionID)
    }

    func setMuted(_ muted: Bool, for tab: BrowserTab) {
        updateTab(tab) { $0.isMuted = muted }
        send(["type": "setMuted", "tabId": tab.tabID, "muted": muted], to: tab.connectionID)
    }

    // MARK: Connections

    private func acceptConnection() {
        let descriptor = accept(listenDescriptor, nil, nil)
        guard descriptor >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let connection = Connection(id: nextConnectionID, descriptor: descriptor)
        nextConnectionID += 1
        let id = connection.id
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readConnection(id) }
        }
        connection.source = source
        connections[id] = connection
        source.resume()
    }

    private func readConnection(_ id: Int) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(connection.descriptor, &chunk, chunk.count)
        guard count > 0 else {
            closeConnection(id)
            return
        }
        connection.pending.append(contentsOf: chunk[0..<count])
        while let newline = connection.pending.firstIndex(of: 0x0A) {
            let line = connection.pending[connection.pending.startIndex..<newline]
            connection.pending.removeSubrange(connection.pending.startIndex...newline)
            if let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                handle(message, from: connection)
            }
        }
    }

    private func closeConnection(_ id: Int) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source?.cancel()
        close(connection.descriptor)
        publish()
    }

    private func handle(_ message: [String: Any], from connection: Connection) {
        switch message["type"] as? String {
        case "hello":
            if let pid = message["browserPID"] as? Int,
               let browser = NSRunningApplication(processIdentifier: pid_t(pid)) {
                connection.browserID = browser.bundleIdentifier
            }
            send(["type": "requestState"], to: connection.id)
            publish()
        case "tabs":
            let entries = message["tabs"] as? [[String: Any]] ?? []
            connection.tabs = entries.compactMap { Self.tab(from: $0, connectionID: connection.id) }
            publish()
        default:
            break
        }
    }

    private static func tab(from entry: [String: Any], connectionID: Int) -> BrowserTab? {
        guard let tabID = entry["id"] as? Int else { return nil }
        return BrowserTab(
            connectionID: connectionID,
            tabID: tabID,
            title: entry["title"] as? String ?? "Untitled",
            host: entry["host"] as? String ?? "",
            isAudible: entry["audible"] as? Bool ?? false,
            isMuted: entry["muted"] as? Bool ?? false,
            volume: Float(entry["volume"] as? Double ?? 1),
            faviconURL: (entry["favIconUrl"] as? String).flatMap(URL.init(string:))
        )
    }

    private func send(_ message: [String: Any], to connectionID: Int) {
        guard let connection = connections[connectionID],
              var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(0x0A)
        if !BridgeSocket.writeAll(line, to: connection.descriptor) {
            closeConnection(connectionID)
        }
    }

    private func updateTab(_ tab: BrowserTab, _ change: (inout BrowserTab) -> Void) {
        guard let connection = connections[tab.connectionID],
              let index = connection.tabs.firstIndex(where: { $0.tabID == tab.tabID }) else { return }
        change(&connection.tabs[index])
        publish()
    }

    private func publish() {
        var grouped: [String: [BrowserTab]] = [:]
        for connection in connections.values.sorted(by: { $0.id < $1.id }) {
            guard let browserID = connection.browserID else { continue }
            grouped[browserID, default: []].append(contentsOf: connection.tabs)
        }
        tabsByBrowser = grouped
        grouped.values.joined().compactMap(\.faviconURL).forEach(loadFavicon)
    }

    private func loadFavicon(_ url: URL) {
        guard favicons[url] == nil, !faviconRequests.contains(url) else { return }
        faviconRequests.insert(url)
        Task { [weak self] in
            guard let response = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: response.0) else { return }
            self?.favicons[url] = image
        }
    }
}
