import CoreAudio
import Testing
@testable import VolumeControlKit

@Suite struct GainMathTests {
    @Test func mutedIsSilent() {
        #expect(GainMath.gain(volume: 1, muted: true) == 0)
    }

    @Test func usesSquareTaper() {
        #expect(GainMath.gain(volume: 1, muted: false) == 1)
        #expect(GainMath.gain(volume: 0.5, muted: false) == 0.25)
    }

    @Test func clampsToBoostLimit() {
        #expect(GainMath.gain(volume: 3, muted: false) == GainMath.boostLimit * GainMath.boostLimit)
        #expect(GainMath.gain(volume: -1, muted: false) == 0)
    }

    @Test func softClipPassesQuietSamplesAndBoundsLoudOnes() {
        #expect(GainMath.softClip(0.5) == 0.5)
        #expect(GainMath.softClip(-0.5) == -0.5)
        #expect(GainMath.softClip(4) <= 1)
        #expect(GainMath.softClip(-4) >= -1)
        #expect(GainMath.softClip(0.95) < 0.95)
    }
}

@Suite struct SourceRouteTests {
    @Test func stereoToStereo() {
        #expect(SourceRoute.route(outputChannel: 0, outputChannels: 2, inputChannels: 2) == .channel(0))
        #expect(SourceRoute.route(outputChannel: 1, outputChannels: 2, inputChannels: 2) == .channel(1))
    }

    @Test func stereoToMonoMixesDown() {
        #expect(SourceRoute.route(outputChannel: 0, outputChannels: 1, inputChannels: 2) == .mixdown)
    }

    @Test func extraOutputChannelsStaySilent() {
        #expect(SourceRoute.route(outputChannel: 4, outputChannels: 6, inputChannels: 2) == .silent)
    }

    @Test func monoInputFeedsBothFrontChannels() {
        #expect(SourceRoute.route(outputChannel: 1, outputChannels: 2, inputChannels: 1) == .channel(0))
        #expect(SourceRoute.route(outputChannel: 2, outputChannels: 4, inputChannels: 1) == .silent)
    }
}

@Suite struct AudioRendererTests {
    private func makeTap(_ samples: [Float], channels: UInt32) -> (AudioBuffer, UnsafeMutablePointer<Float>) {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
        pointer.initialize(from: samples, count: samples.count)
        let buffer = AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
            mData: pointer
        )
        return (buffer, pointer)
    }

    private func makeOutput(frames: Int, channelsPerBuffer: [UInt32]) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)
        for (index, channels) in channelsPerBuffer.enumerated() {
            let count = frames * Int(channels)
            let data = UnsafeMutablePointer<Float>.allocate(capacity: count)
            data.initialize(repeating: 99, count: count)
            list[index] = AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: data
            )
        }
        return list
    }

    private func samples(_ list: UnsafeMutableAudioBufferListPointer, buffer: Int) -> [Float] {
        let b = list[buffer]
        let count = Int(b.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: b.mData!.assumingMemoryBound(to: Float.self), count: count))
    }

    @Test func appliesConstantGainToInterleavedStereo() {
        let (tap, storage) = makeTap([0.2, -0.4, 0.6, -0.8], channels: 2)
        defer { storage.deallocate() }
        let output = makeOutput(frames: 2, channelsPerBuffer: [2])
        let peak = AudioRenderer.render(tap: tap, into: output, from: 0.5, to: 0.5)
        #expect(samples(output, buffer: 0) == [0.1, -0.2, 0.3, -0.4])
        #expect(peak == 0.4)
    }

    @Test func handlesNonInterleavedOutput() {
        let (tap, storage) = makeTap([0.2, -0.4, 0.6, -0.8], channels: 2)
        defer { storage.deallocate() }
        let output = makeOutput(frames: 2, channelsPerBuffer: [1, 1])
        AudioRenderer.render(tap: tap, into: output, from: 1, to: 1)
        #expect(samples(output, buffer: 0) == [0.2, 0.6])
        #expect(samples(output, buffer: 1) == [-0.4, -0.8])
    }

    @Test func rampsBetweenGains() {
        let (tap, storage) = makeTap([1, 1, 1, 1], channels: 1)
        defer { storage.deallocate() }
        let output = makeOutput(frames: 4, channelsPerBuffer: [1])
        AudioRenderer.render(tap: tap, into: output, from: 0, to: 1)
        #expect(samples(output, buffer: 0) == [0, 0.25, 0.5, 0.75])
    }

    @Test func silenceWhenMutedOrNoTap() {
        let (tap, storage) = makeTap([0.5, 0.5], channels: 2)
        defer { storage.deallocate() }
        let output = makeOutput(frames: 1, channelsPerBuffer: [2])
        AudioRenderer.render(tap: tap, into: output, from: 0, to: 0)
        #expect(samples(output, buffer: 0) == [0, 0])

        let empty = makeOutput(frames: 1, channelsPerBuffer: [2])
        AudioRenderer.render(tap: nil, into: empty, from: 1, to: 1)
        #expect(samples(empty, buffer: 0) == [0, 0])
    }
}

@Suite struct LevelMeterTests {
    @Test func positionsOnDecibelScale() {
        #expect(LevelMeter.position(forPeak: 0) == 0)
        #expect(LevelMeter.position(forPeak: 1) == 1)
        #expect(LevelMeter.position(forPeak: 2) == 1)
        #expect(LevelMeter.position(forPeak: 0.001) == 0)
        // -6 dBFS sits 48/54 of the way along a -54 dB scale.
        #expect(abs(LevelMeter.position(forPeak: 0.5) - 48.0 / 54.0) < 0.01)
    }

    @Test func holdsPeakThenReleases() {
        #expect(LevelMeter.decayed(previous: 0.2, peak: 0.8, frames: 512, sampleRate: 48_000) == 0.8)
        let released = LevelMeter.decayed(previous: 0.8, peak: 0, frames: 14_400, sampleRate: 48_000)
        #expect(abs(released - 0.8 * expf(-1)) < 0.001)
    }

    @Test func measuresBufferPeakAndFrames() {
        let samples: [Float] = [0.1, -0.7, 0.3, 0.2]
        samples.withUnsafeBufferPointer { pointer in
            let buffer = AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(mutating: pointer.baseAddress)
            )
            #expect(LevelMeter.peak(of: buffer) == 0.7)
            #expect(LevelMeter.frameCount(of: buffer) == 2)
        }
    }
}

@Suite struct BundleIDMatchingTests {
    @Test func walksUpHelperBundleIDs() {
        #expect(BundleIDMatching.parentCandidates(for: "com.google.Chrome.helper.renderer")
            == ["com.google.Chrome.helper", "com.google.Chrome"])
    }

    @Test func neverReturnsVendorPrefix() {
        #expect(BundleIDMatching.parentCandidates(for: "com.spotify.client") == [])
    }
}
