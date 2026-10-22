import CoreAudio
import Foundation

public enum LevelMeter {
    /// Level in dBFS shown at the left end of the meter.
    public static let floorDecibels: Float = -54
    /// Time for a held peak to fall by a factor of e once the signal drops.
    public static let releaseTime: Float = 0.3

    /// Peak-hold with exponential release. Runs on the real-time audio thread.
    @inline(__always)
    public static func decayed(previous: Float, peak: Float, frames: Int, sampleRate: Float) -> Float {
        guard sampleRate > 0 else { return peak }
        let falloff = expf(-Float(frames) / (sampleRate * releaseTime))
        return max(peak, previous * falloff)
    }

    /// Maps a linear peak to a 0...1 meter position on a decibel scale.
    public static func position(forPeak peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10f(peak)
        return Double(min(max((decibels - floorDecibels) / -floorDecibels, 0), 1))
    }

    /// Absolute peak of an interleaved Float32 buffer. Runs on the real-time audio thread.
    public static func peak(of buffer: AudioBuffer?) -> Float {
        guard let buffer, let data = buffer.mData else { return 0 }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(samples[index]))
        }
        return peak
    }

    public static func frameCount(of buffer: AudioBuffer?) -> Int {
        guard let buffer, buffer.mNumberChannels > 0 else { return 0 }
        return Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels))
    }
}
