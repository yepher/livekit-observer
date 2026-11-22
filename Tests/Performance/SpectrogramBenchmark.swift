import Foundation
import AVFoundation
import ObserverCore

/// Deterministic local audio only. Times DSP and four sequential lane redraws separately.
@main struct SpectrogramBenchmark {
    static func main() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("observer-mel-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let audio = try AVAudioFile(forWriting: file, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            for i in 0..<48_000 {
                buffer.floatChannelData![0][i] = Float(0.4 * sin(2 * .pi * 440 * Double(i) / 48_000))
                buffer.floatChannelData![1][i] = Float(0.3 * sin(2 * .pi * 3000 * Double(i) / 48_000))
            }
            for _ in 0..<60 { try audio.write(from: buffer) }
        }
        let began = Date()
        let gram = try Spectrogram.compute(file: file)
        print("60_second_stereo_analysis_ms=\(Date().timeIntervalSince(began) * 1000) frames=\(gram.frameCount)")
        let frames = 120_000
        let values = (0..<(frames * Spectrogram.bands)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let long = Spectrogram(hop: 0.01, channels: [values, values], frameCount: frames, identicalChannels: false)
        for span in [30.0, 1200.0] {
            var times: [Double] = []
            for run in 0..<8 {
                let began = Date()
                for lane in 0..<4 {
                    let image = long.image(channel: lane % 2, from: Double(run) * 0.01, to: span + Double(run) * 0.01, columns: 2400)
                    precondition(image?.width == 2400)
                }
                times.append(Date().timeIntervalSince(began) * 1000)
            }
            print("four_lane_\(Int(span))s_render_median_ms=\(times.sorted()[4]) max_ms=\(times.max()!)")
        }
    }
}
