import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import LiveKitObserver

@Suite struct SpectrogramRenderingTests {
    @Test func renderingPreservesPeaksBandOrderAndBlankMargins() throws {
        let frames = 17, bands = Spectrogram.bands
        let cells = (0..<(frames * bands)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let gram = Spectrogram(hop: 0.01, channels: [cells], frameCount: frames, identicalChannels: false)
        // Includes magnification, fractional frame boundaries, downsampling and out-of-file windows.
        for (from, to, width) in [(-0.1, 0.3, 20), (0.0, 0.17, 3), (0.011, 0.025, 23), (0.2, 0.4, 8)] {
            let image = try #require(gram.image(channel: 0, from: from, to: to, columns: width))
            let bytes = try #require(image.dataProvider?.data as Data?)
            for x in 0..<width {
                let step = (to - from) / gram.hop / Double(width)
                let first = Int(floor(from / gram.hop + Double(x) * step))
                let last = max(first, Int(floor(from / gram.hop + Double(x + 1) * step)) - 1)
                for band in 0..<bands {
                    let covered = (0..<frames).filter { $0 >= first && $0 <= last }
                    let expected = covered.map { cells[$0 * bands + band] }.max().map { Colormap.magma[Int($0)] } ?? Colormap.background
                    let offset = (bands - 1 - band) * image.bytesPerRow + x * 4
                    let actual = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                    #expect(actual == expected)
                }
            }
        }
    }

    @Test @MainActor func cancelledBackgroundRenderingReturnsNoBitmap() async {
        let gram = Spectrogram(hop: 0.01, channels: [[UInt8](repeating: 50, count: 80)], frameCount: 1, identicalChannels: false)
        let task = Task { await SpectrogramRenderer.shared.image(gram, channel: 0, from: 0, to: 1, columns: 400) }
        task.cancel()
        #expect(await task.value == nil)
        // A cancelled request must not keep the serial renderer from handling the next view.
        let next = await SpectrogramRenderer.shared.image(gram, channel: 0, from: 0, to: 1, columns: 400)
        #expect(next?.width == 400)
    }

    @Test func invalidWindowsDoNotRender() {
        let gram = Spectrogram(hop: 0.01, channels: [[UInt8](repeating: 0, count: 80)], frameCount: 1, identicalChannels: false)
        #expect(gram.image(channel: -1, from: 0, to: 1, columns: 400) == nil)
        #expect(gram.image(channel: 1, from: 0, to: 1, columns: 400) == nil)
        #expect(gram.image(channel: 0, from: .nan, to: 1, columns: 400) == nil)
        #expect(gram.image(channel: 0, from: 0, to: .infinity, columns: 400) == nil)
        #expect(gram.image(channel: 0, from: 1, to: 1, columns: 400) == nil)
    }

    @Test func vectorizedNoiseMeasuresMatchReference() throws {
        // Values from the original scalar implementation, with deterministic silence, harmonics
        // and noise. Keep the static detector's inputs stable when changing the FFT hot path.
        let fixtures: [(Double, [[Float]])] = [
            (8000, [[-11.777485, 0.11441931, 0.9956665], [-17.069912, 0.049396917, 0.6335299]]),
            (16000, [[-11.769004, 0.08651504, 0.99025834], [-16.739296, 0.04411619, 0.23507233]]),
            (44100, [[-11.792353, 0.048014544, 0.98873216], [-16.878822, 0.033098295, 0.09129942]]),
            (48000, [[-11.874713, 0.037517838, 0.9889798], [-16.918102, 0.03704229, 0.12001748]])
        ]
        for (rate, reference) in fixtures {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mel-reference-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let count = Int(rate * 2)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                let samples = try #require(buffer.floatChannelData)
                var seed: UInt64 = 12345
                for i in 0..<count {
                    seed = seed &* 6364136223846793005 &+ 1
                    let noise = Double(seed >> 40) / Double(1 << 24) - 0.5
                    let time = Double(i) / rate
                    samples[0][i] = time < 0.3 ? 0 : Float(0.3 * sin(2 * .pi * 220 * time) + 0.2 * sin(2 * .pi * 880 * time) + noise * 0.1)
                    samples[1][i] = Float(noise * 0.5)
                }
                try file.write(from: buffer)
            }
            let gram = try Spectrogram.compute(file: url)
            for channel in 0..<2 {
                let noise = gram.noise[channel]
                #expect(abs(noise.level[100] - reference[channel][0]) < 0.0001)
                #expect(abs(noise.harmonicity[100] - reference[channel][1]) < 0.00001)
                #expect(abs(noise.lowShare[100] - reference[channel][2]) < 0.00001)
            }
        }
    }
}
