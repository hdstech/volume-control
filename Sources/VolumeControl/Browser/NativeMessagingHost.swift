import Darwin
import Foundation

/// Run when a browser launches `VolumeControl chrome-extension://<id>/` as a native-messaging host.
/// Relays the browser's length-prefixed JSON on stdin/stdout to the menu bar app's line-based socket,
/// reconnecting whenever the app isn't running yet or restarts.
final class NativeMessagingHost: @unchecked Sendable {
    private let lock = NSLock()
    private var socketDescriptor: Int32 = -1
    private let browserPID = getppid()

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let host = NativeMessagingHost()
        Thread.detachNewThread { host.maintainAppConnection() }
        host.relayBrowserInput()
        exit(0)
    }

    // MARK: Browser → app

    private func relayBrowserInput() {
        while let message = readBrowserMessage() {
            lock.lock()
            let descriptor = socketDescriptor
            lock.unlock()
            guard descriptor >= 0 else { continue }
            var line = message
            line.append(0x0A)
            _ = BridgeSocket.writeAll(line, to: descriptor)
        }
    }

    private func readBrowserMessage() -> Data? {
        guard let header = readExactly(4, from: STDIN_FILENO) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length > 0, length < 64 * 1024 * 1024 else { return nil }
        return readExactly(Int(length), from: STDIN_FILENO)
    }

    private func readExactly(_ count: Int, from descriptor: Int32) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let success = data.withUnsafeMutableBytes { buffer -> Bool in
            while offset < count {
                let result = read(descriptor, buffer.baseAddress! + offset, count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        return success ? data : nil
    }

    // MARK: App → browser

    private func maintainAppConnection() {
        while true {
            if let descriptor = connectToApp() {
                lock.lock()
                socketDescriptor = descriptor
                lock.unlock()

                sendHello(on: descriptor)
                relayAppOutput(from: descriptor)

                lock.lock()
                socketDescriptor = -1
                lock.unlock()
                close(descriptor)
            }
            sleep(2)
        }
    }

    private func connectToApp() -> Int32? {
        guard var address = BridgeSocket.address(for: BridgeSocket.url.path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func sendHello(on descriptor: Int32) {
        let hello: [String: Any] = ["type": "hello", "browserPID": Int(browserPID)]
        guard var line = try? JSONSerialization.data(withJSONObject: hello) else { return }
        line.append(0x0A)
        _ = BridgeSocket.writeAll(line, to: descriptor)
    }

    private func relayAppOutput(from descriptor: Int32) {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: chunk[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if !line.isEmpty { writeBrowserMessage(Data(line)) }
            }
        }
    }

    private func writeBrowserMessage(_ message: Data) {
        var length = UInt32(message.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(message)
        if !BridgeSocket.writeAll(frame, to: STDOUT_FILENO) { exit(0) }
    }
}
