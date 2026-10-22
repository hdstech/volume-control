import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String { "\(operation) failed (\(Self.code(for: status)))" }

    static func code(for status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
            return "'\(String(decoding: bytes, as: UTF8.self))'"
        }
        return String(status)
    }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

enum AudioObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default initial: T
    ) throws -> T {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, "Reading property \(CoreAudioError.code(for: OSStatus(bitPattern: selector)))")
        return value
    }

    static func readArray<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of _: T.Type
    ) throws -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Reading property size")
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }
        var status: OSStatus = noErr
        let values = [T](unsafeUninitializedCapacity: capacity) { buffer, count in
            status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
            count = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
        try check(status, "Reading property list")
        return values
    }

    static func readString(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, "Reading string property")
        return (value?.takeRetainedValue() as String?) ?? ""
    }
}

/// Registers a Core Audio property listener delivered on the main queue, and removes it on `invalidate()`.
@MainActor
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var isActive: Bool

    init(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        var address = AudioObject.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        self.object = object
        self.address = address
        self.block = block
        self.isActive = status == noErr
    }

    func invalidate() {
        guard isActive else { return }
        isActive = false
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}
