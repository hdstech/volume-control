import Foundation

public enum GainMath {
    public static let boostLimit: Float = 1.5

    /// Maps a slider position to linear gain. The square taper makes the slider feel even to the ear.
    public static func gain(volume: Float, muted: Bool) -> Float {
        if muted { return 0 }
        let clamped = min(max(volume, 0), boostLimit)
        return clamped * clamped
    }

    /// Leaves samples under the knee untouched and bends louder ones smoothly toward ±1.
    @inline(__always)
    public static func softClip(_ sample: Float) -> Float {
        let knee: Float = 0.9
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let headroom = 1 - knee
        let shaped = knee + headroom * tanhf((magnitude - knee) / headroom)
        return sample < 0 ? -shaped : shaped
    }
}
