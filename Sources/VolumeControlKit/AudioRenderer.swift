import CoreAudio
import Foundation

public enum SourceRoute: Equatable, Sendable {
    case silent
    case channel(Int)
    case mixdown

    public static func route(outputChannel: Int, outputChannels: Int, inputChannels: Int) -> SourceRoute {
        if outputChannels == 1 {
            return inputChannels == 1 ? .channel(0) : .mixdown
        }
        if inputChannels == 1 {
            return outputChannel < 2 ? .channel(0) : .silent
        }
        return outputChannel < inputChannels ? .channel(outputChannel) : .silent
    }
}

public enum AudioRenderer {
    public static func silence(_ output: UnsafeMutableAudioBufferListPointer) {
        for buffer in output {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    /// Copies an interleaved Float32 tap buffer into the device's output buffers, applying a linear
    /// gain ramp across the buffer, and returns the peak of what was written.
    /// Runs on the real-time audio thread: no allocation, no locks.
    @discardableResult
    public static func render(
        tap: AudioBuffer?,
        into output: UnsafeMutableAudioBufferListPointer,
        from startGain: Float,
        to endGain: Float
    ) -> Float {
        silence(output)

        guard let tap, let tapData = tap.mData, tap.mNumberChannels > 0 else { return 0 }
        if startGain == 0 && endGain == 0 { return 0 }

        let inputChannels = Int(tap.mNumberChannels)
        let source = tapData.assumingMemoryBound(to: Float.self)
        let sourceFrames = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * inputChannels)
        let outputChannels = output.reduce(0) { $0 + Int($1.mNumberChannels) }
        let limit = max(startGain, endGain) > 1

        var peak: Float = 0
        var firstChannelOfBuffer = 0
        for buffer in output {
            let stride = Int(buffer.mNumberChannels)
            defer { firstChannelOfBuffer += stride }
            guard stride > 0, let data = buffer.mData else { continue }

            let destination = data.assumingMemoryBound(to: Float.self)
            let frames = min(sourceFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride))
            guard frames > 0 else { continue }
            let step = (endGain - startGain) / Float(frames)

            for channel in 0..<stride {
                let route = SourceRoute.route(
                    outputChannel: firstChannelOfBuffer + channel,
                    outputChannels: outputChannels,
                    inputChannels: inputChannels
                )
                if route == .silent { continue }

                var gain = startGain
                for frame in 0..<frames {
                    let base = frame * inputChannels
                    var sample: Float
                    switch route {
                    case .channel(let index):
                        sample = source[base + index]
                    case .mixdown:
                        sample = 0
                        for index in 0..<inputChannels { sample += source[base + index] }
                        sample /= Float(inputChannels)
                    case .silent:
                        sample = 0
                    }
                    var shaped = sample * gain
                    if limit { shaped = GainMath.softClip(shaped) }
                    destination[frame * stride + channel] = shaped
                    peak = max(peak, abs(shaped))
                    gain += step
                }
            }
        }
        return peak
    }
}
