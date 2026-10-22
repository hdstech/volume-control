import CoreAudio
import Foundation

struct OutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
    let sampleRate: Float64
    let inputStreamCount: Int

    var symbolName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            "tv"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            "hifispeaker"
        default:
            "speaker.wave.2"
        }
    }
}

/// Follows the system default output device and reports when it, or its sample rate, changes.
@MainActor
final class OutputDeviceMonitor {
    var onChange: (@MainActor () -> Void)?
    private(set) var device: OutputDevice?

    private var defaultDeviceListener: PropertyListener?
    private var sampleRateListener: PropertyListener?

    func start() {
        defaultDeviceListener = PropertyListener(
            object: AudioObject.system,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            self?.refresh()
        }
        refresh(notify: false)
    }

    func refresh(notify: Bool = true) {
        let updated = Self.readDefaultDevice()
        if updated?.id != device?.id {
            sampleRateListener?.invalidate()
            sampleRateListener = updated.map {
                PropertyListener(object: $0.id, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
                    self?.refresh()
                }
            }
        }
        guard updated != device else { return }
        device = updated
        if notify { onChange?() }
    }

    private static func readDefaultDevice() -> OutputDevice? {
        guard let id = try? AudioObject.read(
            AudioObject.system,
            kAudioHardwarePropertyDefaultOutputDevice,
            default: AudioObjectID(kAudioObjectUnknown)
        ), id != kAudioObjectUnknown,
            let uid = try? AudioObject.readString(id, kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        let inputStreams = (try? AudioObject.readArray(
            id,
            kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput,
            of: AudioStreamID.self
        )) ?? []
        return OutputDevice(
            id: id,
            uid: uid,
            name: (try? AudioObject.readString(id, kAudioObjectPropertyName)) ?? "Output",
            transportType: (try? AudioObject.read(id, kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0,
            sampleRate: (try? AudioObject.read(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0,
            inputStreamCount: inputStreams.count
        )
    }
}
