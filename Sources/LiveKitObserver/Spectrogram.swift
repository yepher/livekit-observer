import ObserverCore
import Accelerate
import AVFoundation
import CoreGraphics

/// A log-mel spectrogram of every channel of a recording, quantized to one byte per cell.
///
/// Columns are 10 ms apart and centered on their time; cell values map a fixed dBFS range
/// (`floorDB`…`ceilingDB`) to 0…255, so levels compare across recordings and channels.
struct Spectrogram: Sendable {
    /// Distinguishes replacement recordings even when their visible time range is unchanged.
    let id = UUID()
    static let bands = 80
    static let minHz: Float = 50
    static let maxHz: Float = 12_000
    static let floorDB: Float = -100
    static let ceilingDB: Float = -5

    /// Seconds between columns.
    let hop: TimeInterval
    /// One array per channel, `frameCount × bands`, column-major (a column's bands are contiguous, lowest first).
    let channels: [[UInt8]]
    let frameCount: Int
    /// The file stores the same signal in every channel (a mono mix written as stereo).
    let identicalChannels: Bool
    /// Per channel, the measures StaticDetector uses, one value per column.
    let noise: [NoiseTrack]
    var byteCount: Int { channels.reduce(0) { $0 + $1.count } + noise.reduce(0) { $0 + ($1.level.count + $1.harmonicity.count + $1.lowShare.count) * MemoryLayout<Float>.stride } }
    var duration: TimeInterval { Double(frameCount) * hop }

    init(hop: TimeInterval, channels: [[UInt8]], frameCount: Int, identicalChannels: Bool, noise: [NoiseTrack] = []) {
        self.hop = hop
        self.channels = channels
        self.frameCount = frameCount
        self.identicalChannels = identicalChannels
        self.noise = noise
    }

    /// Decodes `file` in chunks (a long session is hundreds of MB as PCM) and analyzes every channel.
    static func compute(file: URL) throws -> Spectrogram {
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = audio.processingFormat
        let channelCount = Int(format.channelCount)
        let analyzer = MelAnalyzer(sampleRate: Float(format.sampleRate))
        let chunk = AVAudioFrameCount(format.sampleRate)  // one second
        guard channelCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Pad by half a window so column i is centered on i × hop.
        var pending = Array(repeating: [Float](repeating: 0, count: analyzer.size / 2), count: channelCount)
        var output = Array(repeating: [UInt8](), count: channelCount)
        var noise = Array(repeating: NoiseTrack(), count: channelCount)
        // Energy of each channel's difference from channel 0, against channel 0's energy.
        var difference: Float = 0, signal: Float = 0
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            try audio.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for c in 0..<channelCount { pending[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: n)) }
            var energy: Float = 0
            vDSP_svesq(data[0], 1, &energy, vDSP_Length(n))
            signal += energy
            for c in 1..<channelCount {
                var diff: Float = 0
                vDSP_distancesq(data[0], 1, data[c], 1, &diff, vDSP_Length(n))
                difference += diff
            }
            for c in 0..<channelCount {
                var start = 0
                while pending[c].count - start >= analyzer.size {
                    pending[c].withUnsafeBufferPointer { analyzer.column(from: $0.baseAddress! + start, into: &output[c], noise: &noise[c]) }
                    start += analyzer.hop
                }
                pending[c].removeFirst(start)
            }
        }
        // Lossy stereo coding leaves a mono mix's channels slightly different; -40 dB counts as the same.
        let identical = channelCount > 1 && difference <= signal * 1e-4
        let frames = output.map { $0.count / bands }.min() ?? 0
        return Spectrogram(
            hop: Double(analyzer.hop) / format.sampleRate,
            channels: identical ? [output[0]] : output,
            frameCount: frames,
            identicalChannels: identical,
            noise: identical ? [noise[0]] : noise
        )
    }

    /// The 0…255 level of `band` (0 = lowest) in column `frame`.
    func level(channel: Int, frame: Int, band: Int) -> UInt8 { channels[channel][frame * Self.bands + band] }

    /// Renders `[start, end)` seconds of one channel as `columns` pixels wide and one pixel per band tall.
    /// A pixel covering several columns shows their maximum so short sounds stay visible when zoomed out.
    func image(channel: Int, from start: TimeInterval, to end: TimeInterval, columns: Int) -> CGImage? {
        let bands = Self.bands
        guard columns > 0, start.isFinite, end.isFinite, end > start, hop > 0,
              channels.indices.contains(channel), frameCount > 0 else { return nil }
        let data = channels[channel]
        var pixels = [UInt32](repeating: Colormap.background, count: columns * bands)
        let perColumn = (end - start) / hop / Double(columns)
        // Reuse storage and borrow the buffers once. Array subscripting and allocating a peak
        // array for every pixel made a whole-call redraw take seconds in Debug builds.
        var peak = [UInt8](repeating: 0, count: bands)
        data.withUnsafeBytes { raw in
            peak.withUnsafeMutableBytes { scratch in
                pixels.withUnsafeMutableBufferPointer { pixels in
                    Colormap.magma.withUnsafeBufferPointer { palette in
                        let destination = pixels.baseAddress!
                        let colors = palette.baseAddress!
                        let levels = scratch.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        for x in 0..<columns {
                            if x.isMultiple(of: 32), Task.isCancelled { return }
                            let firstTime = (start / hop) + Double(x) * perColumn
                            let lastTime = max(firstTime.rounded(.down), ((start / hop) + Double(x + 1) * perColumn).rounded(.down) - 1)
                            guard lastTime >= 0, firstTime < Double(frameCount) else { continue }
                            let first = Int(max(0, firstTime.rounded(.down)))
                            let last = Int(min(Double(frameCount - 1), lastTime))
                            let column = raw.baseAddress! + first * bands
                            scratch.copyMemory(from: UnsafeRawBufferPointer(start: column, count: bands))
                            if first < last {
                                for f in (first + 1)...last {
                                    if f.isMultiple(of: 256), Task.isCancelled { return }
                                    let values = (raw.baseAddress! + f * bands).assumingMemoryBound(to: UInt8.self)
                                    for b in 0..<bands { levels[b] = max(levels[b], values[b]) }
                                }
                            }
                            for b in 0..<bands { destination[(bands - 1 - b) * columns + x] = colors[Int(levels[b])] }
                        }
                    }
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        return pixels.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: columns, height: bands, bitsPerComponent: 8, bytesPerRow: columns * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    /// Loudness per column, summed over bands and channels, with its mean removed.
    var envelope: [Float] {
        var result = [Float](repeating: 0, count: frameCount)
        var column = [Float](repeating: 0, count: Self.bands)
        for data in channels {
            data.withUnsafeBufferPointer { data in
                result.withUnsafeMutableBufferPointer { result in
                    column.withUnsafeMutableBufferPointer { column in
                        for f in 0..<frameCount {
                            if f.isMultiple(of: 256), Task.isCancelled { return }
                            vDSP_vfltu8(data.baseAddress! + f * Self.bands, 1, column.baseAddress!, 1, vDSP_Length(Self.bands))
                            var sum: Float = 0
                            vDSP_sve(column.baseAddress!, 1, &sum, vDSP_Length(Self.bands))
                            result[f] += sum
                        }
                    }
                }
            }
        }
        guard !Task.isCancelled else { return [] }
        let mean = result.isEmpty ? 0 : result.reduce(0, +) / Float(result.count)
        return result.map { $0 - mean }
    }

    /// How many seconds after `other` this recording starts, found by matching their loudness over time.
    /// Searches `expected ± range` seconds, coarsely at first when the range is wide; nil when the recordings do not clearly match.
    func startOffset(from other: Spectrogram, expected: TimeInterval, range: TimeInterval = 120) -> TimeInterval? {
        guard abs(hop - other.hop) < 1e-9 else { return nil }
        let a = envelope, b = other.envelope
        guard !Task.isCancelled else { return nil }
        // Short overlaps match by chance, so require a good share of the shorter recording.
        let minimumOverlap = max(100, min(a.count, b.count) / 4)
        let center = Int((expected / hop).rounded()), reach = Int(range / hop)
        var guess = center, near = reach
        if reach > 300 {
            let step = 10
            let coarse = Self.bestLag(Self.decimate(a, by: step), Self.decimate(b, by: step),
                                      lags: (center - reach) / step...(center + reach) / step, minimumOverlap: minimumOverlap / step)
            guard let coarse, coarse.score >= 0.5 else { return nil }
            guess = coarse.lag * step
            near = 2 * step
        }
        guard let best = Self.bestLag(a, b, lags: (guess - near)...(guess + near), minimumOverlap: minimumOverlap),
              best.score >= 0.5 else { return nil }
        return Double(best.lag) * hop
    }

    /// The lag with the highest normalized correlation, where `a`'s frame i is `b`'s frame i + lag.
    private static func bestLag(_ a: [Float], _ b: [Float], lags: ClosedRange<Int>, minimumOverlap: Int) -> (lag: Int, score: Float)? {
        var best: (lag: Int, score: Float)?
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for lag in lags {
                    if Task.isCancelled { return }
                    let i0 = max(0, -lag), i1 = min(a.count, b.count - lag)
                    guard i1 - i0 >= max(minimumOverlap, 2) else { continue }
                    var dot: Float = 0, aa: Float = 0, bb: Float = 0
                    let n = vDSP_Length(i1 - i0)
                    vDSP_dotpr(pa.baseAddress! + i0, 1, pb.baseAddress! + i0 + lag, 1, &dot, n)
                    vDSP_svesq(pa.baseAddress! + i0, 1, &aa, n)
                    vDSP_svesq(pb.baseAddress! + i0 + lag, 1, &bb, n)
                    let score = dot / max(sqrt(aa * bb), 1e-9)
                    if score > (best?.score ?? -.infinity) { best = (lag, score) }
                }
            }
        }
        return best
    }

    private static func decimate(_ values: [Float], by step: Int) -> [Float] {
        stride(from: 0, to: values.count - step + 1, by: step).map { values[$0..<$0 + step].reduce(0, +) }
    }

    /// The center frequency of each band, lowest first.
    static let bandCenters: [Float] = MelAnalyzer.edges(bands: bands, minHz: minHz, maxHz: maxHz).dropFirst().dropLast().map { $0 }
}

/// Bitmap work has its own serial executor so it neither blocks SwiftUI nor waits behind a
/// long audio decode. Cancelled scroll/resize requests are skipped before touching the data.
actor SpectrogramRenderer {
    static let shared = SpectrogramRenderer()

    func image(_ spectrogram: Spectrogram, channel: Int, from: TimeInterval, to: TimeInterval, columns: Int) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return spectrogram.image(channel: channel, from: from, to: to, columns: columns)
    }
}

/// One short-time Fourier transform frame → log-mel column, using vDSP.
private final class MelAnalyzer {
    let size: Int
    let hop: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    /// Per band: first FFT bin and its triangular weights.
    private let filters: [(start: Int, weights: [Float], normalization: Float)]
    private let scale: Float
    // For the static measures.
    private let windowEnergy: Float
    private let lowBins: Int
    private let quefrencies: ClosedRange<Int>
    private var logMagnitude: [Float]
    private var cepReal: [Float]
    private var cepImag: [Float]
    private let pitchIndices: [Float]
    private let pitchSum: Float
    private let pitchDenominator: Float
    private var pitchValues: [Float]

    init(sampleRate: Float) {
        hop = Int((sampleRate / 100).rounded())  // 10 ms
        var n = 1
        while Float(n) < sampleRate * 0.04 { n <<= 1 }  // ≥ 40 ms window: 2048 at 48 kHz
        size = n
        log2n = vDSP_Length(n.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        frame = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        power = [Float](repeating: 0, count: n / 2 + 1)
        // vDSP's real FFT is scaled by 2; normalize so a full-scale sine is about 0 dBFS.
        let windowSum = window.reduce(0, +)
        scale = 1 / (windowSum * windowSum)
        let binHz = sampleRate / Float(n)
        windowEnergy = window.reduce(0) { $0 + $1 * $1 }
        lowBins = min(n / 2, Int(NoiseTrack.lowShareHz / binHz))
        // Pitch periods of 2.5–12.5 ms (80–400 Hz), where voiced speech puts its cepstral peak.
        quefrencies = Int(sampleRate * 0.0025)...min(n / 2 - 1, Int(sampleRate * 0.0125))
        let indices = quefrencies.map(Float.init)
        pitchIndices = indices
        pitchSum = indices.reduce(0, +)
        pitchDenominator = max(Float(indices.count) * indices.reduce(0) { $0 + $1 * $1 } - pitchSum * pitchSum, 1e-9)
        pitchValues = [Float](repeating: 0, count: indices.count)
        logMagnitude = [Float](repeating: 0, count: n)
        cepReal = [Float](repeating: 0, count: n / 2)
        cepImag = [Float](repeating: 0, count: n / 2)
        let edges = Self.edges(bands: Spectrogram.bands, minHz: Spectrogram.minHz, maxHz: min(Spectrogram.maxHz, sampleRate / 2))
        filters = (0..<Spectrogram.bands).map { b in
            let (lo, mid, hi) = (edges[b], edges[b + 1], edges[b + 2])
            let first = max(1, Int((lo / binHz).rounded(.up)))
            let last = min(n / 2, Int((hi / binHz).rounded(.down)))
            guard first <= last else {  // narrower than a bin: take the nearest one
                let bin = min(n / 2, max(1, Int((mid / binHz).rounded())))
                return (bin, [1], 1)
            }
            let weights = (first...last).map { k in
                let f = Float(k) * binHz
                return max(0, f < mid ? (f - lo) / (mid - lo) : (hi - f) / (hi - mid))
            }
            return (first, weights, 1 / max(weights.reduce(0, +), 1e-9))
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Band edges equally spaced on the mel scale (`bands + 2` values).
    static func edges(bands: Int, minHz: Float, maxHz: Float) -> [Float] {
        func mel(_ f: Float) -> Float { 2595 * log10(1 + f / 700) }
        func hz(_ m: Float) -> Float { 700 * (pow(10, m / 2595) - 1) }
        let (lo, hi) = (mel(minHz), mel(maxHz))
        return (0..<(bands + 2)).map { hz(lo + (hi - lo) * Float($0) / Float(bands + 1)) }
    }

    func column(from samples: UnsafePointer<Float>, into output: inout [UInt8], noise: inout NoiseTrack) {
        let half = size / 2
        vDSP_vmul(samples, 1, window, 1, &frame, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Packed output: imag[0] holds the Nyquist bin.
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                power[0] = r[0] * r[0]
                power[half] = i[0] * i[0]
            }
        }
        let span = Spectrogram.ceilingDB - Spectrogram.floorDB
        power.withUnsafeBufferPointer { power in
            for filter in filters {
                var energy: Float = 0
                vDSP_dotpr(power.baseAddress! + filter.start, 1, filter.weights, 1, &energy, vDSP_Length(filter.weights.count))
                let db = 10 * log10(energy * filter.normalization * scale + 1e-20)
                output.append(UInt8(max(0, min(255, (db - Spectrogram.floorDB) / span * 255))))
            }
        }
        appendNoiseMeasures(to: &noise)
    }

    /// Loudness, how much of it sits below 2.5 kHz, and cepstral peak prominence: the strength of the evenly
    /// spaced harmonics a voice makes, which static lacks. Uses the power spectrum `column` just computed.
    private func appendNoiseMeasures(to noise: inout NoiseTrack) {
        let half = size / 2
        // Parseval: a one-sided spectrum holds half of n times the windowed frame's energy, and vDSP's ×2
        // scaling makes `power` 4× that, so the frame's mean square is total / (2n), normalized by the window.
        var total: Float = 0, low: Float = 0
        power.withUnsafeBufferPointer { power in
            vDSP_sve(power.baseAddress! + 1, 1, &total, vDSP_Length(half))
            vDSP_sve(power.baseAddress! + 1, 1, &low, vDSP_Length(max(1, lowBins)))
        }
        noise.level.append(10 * log10(total / (2 * Float(size) * windowEnergy) + 1e-12))
        noise.lowShare.append(total > 0 ? low / total : 0)

        // Real cepstrum: the FFT of the log magnitude spectrum, mirrored so it is real and even.
        logMagnitude.withUnsafeMutableBufferPointer { magnitude in
            var epsilon: Float = 1e-18, factor: Float = 0.5, one: Float = 1
            var count = Int32(half + 1)
            vDSP_vsadd(power, 1, &epsilon, magnitude.baseAddress!, 1, vDSP_Length(count))
            vvlogf(magnitude.baseAddress!, magnitude.baseAddress!, &count)
            vDSP_vsmul(magnitude.baseAddress!, 1, &factor, magnitude.baseAddress!, 1, vDSP_Length(count))
            vDSP_vsmul(magnitude.baseAddress! + 1, 1, &one, magnitude.baseAddress! + size - 1, -1, vDSP_Length(half - 1))
        }
        var prominence: Float = 0
        cepReal.withUnsafeMutableBufferPointer { r in
            cepImag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                logMagnitude.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP doubles the result and the inverse transform divides by n; the packed slot 0 is unused here.
                var norm = 1 / (2 * Float(size))
                // Peak above the straight line fitted through the pitch range.
                let count = vDSP_Length(pitchValues.count)
                var sy: Float = 0, sxy: Float = 0, peak: Float = 0
                var peakIndex: vDSP_Length = 0
                pitchValues.withUnsafeMutableBufferPointer { values in
                    vDSP_vabs(r.baseAddress! + quefrencies.lowerBound, 1, values.baseAddress!, 1, count)
                    vDSP_vsmul(values.baseAddress!, 1, &norm, values.baseAddress!, 1, count)
                    vDSP_sve(values.baseAddress!, 1, &sy, count)
                    vDSP_dotpr(pitchIndices, 1, values.baseAddress!, 1, &sxy, count)
                    vDSP_maxvi(values.baseAddress!, 1, &peak, &peakIndex, count)
                }
                let slope = (Float(count) * sxy - pitchSum * sy) / pitchDenominator
                let intercept = (sy - slope * pitchSum) / Float(count)
                prominence = peak - (slope * Float(quefrencies.lowerBound + Int(peakIndex)) + intercept)
            }
        }
        noise.harmonicity.append(prominence)
    }
}

enum Colormap {
    /// A dark-to-bright perceptual ramp (approximating matplotlib's "magma"), as RGBA in memory order.
    static let magma: [UInt32] = {
        let stops: [(Float, Float, Float)] = [
            (0, 0, 4), (28, 16, 68), (79, 18, 123), (129, 37, 129), (181, 54, 122),
            (229, 80, 100), (251, 135, 97), (254, 194, 135), (252, 253, 191),
        ]
        return (0..<256).map { i in
            let p = Float(i) / 255 * Float(stops.count - 1)
            let a = stops[min(Int(p), stops.count - 1)], b = stops[min(Int(p) + 1, stops.count - 1)]
            let t = p - Float(Int(p))
            func mix(_ x: Float, _ y: Float) -> UInt32 { UInt32((x + (y - x) * t).rounded()) }
            return mix(a.0, b.0) | mix(a.1, b.1) << 8 | mix(a.2, b.2) << 16 | 0xFF << 24
        }
    }()
    /// Outside the recording: transparent.
    static let background: UInt32 = 0
}
