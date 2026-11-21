import Foundation
import ObserverCore

@main struct AnalysisBenchmark {
    static func main() throws {
        let target = Int(CommandLine.arguments.dropFirst().first ?? "2147483648")!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("observer-analysis-\(UUID()).pcap")
        defer { try? FileManager.default.removeItem(at: file) }
        func put(_ number: UInt64, at: Int, width: Int, little: Bool, into bytes: inout [UInt8]) {
            for i in 0..<width { bytes[at + i] = UInt8(truncatingIfNeeded: number >> (8 * (little ? i : width - 1 - i))) }
        }
        var header = [UInt8](repeating: 0, count: 24)
        put(0xa1b2c3d4, at: 0, width: 4, little: true, into: &header)
        put(2, at: 4, width: 2, little: true, into: &header); put(4, at: 6, width: 2, little: true, into: &header)
        put(65535, at: 16, width: 4, little: true, into: &header); put(1, at: 20, width: 4, little: true, into: &header)
        try Data(header).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let count = max(256, (target - 24) / 1516)
        var record = [UInt8](repeating: 0, count: 1516)
        put(1500, at: 8, width: 4, little: true, into: &record); put(1500, at: 12, width: 4, little: true, into: &record)
        record[28] = 8; record[30] = 0x45
        put(1486, at: 32, width: 2, little: false, into: &record)
        record[38] = 64; record[39] = 17
        record.replaceSubrange(42..<50, with: [192, 0, 2, 1, 192, 0, 2, 2])
        put(1466, at: 54, width: 2, little: false, into: &record); record[58] = 0x80
        for start in stride(from: 0, to: count, by: 1024) {
            try autoreleasepool {
                var chunk = Data(); chunk.reserveCapacity(1516 * 1024)
                for i in start..<min(start + 1024, count) {
                    let sequence = UInt64(i / 128), stream = UInt64(i % 128)
                    let micros = sequence * 20_000
                    put(micros / 1_000_000, at: 0, width: 4, little: true, into: &record)
                    put(micros % 1_000_000, at: 4, width: 4, little: true, into: &record)
                    put(4000 + stream, at: 50, width: 2, little: false, into: &record)
                    put(5000 + stream, at: 52, width: 2, little: false, into: &record)
                    put(sequence, at: 60, width: 2, little: false, into: &record)
                    put(sequence * 160, at: 62, width: 4, little: false, into: &record)
                    put(stream + 1, at: 66, width: 4, little: false, into: &record)
                    chunk.append(contentsOf: record)
                }
                try handle.write(contentsOf: chunk)
            }
        }
        try handle.close()
        let started = Date()
        let result = try CaptureAnalyzer.scan(file)
        guard result.complete, result.processed == count, result.streams.count == 128,
              result.streams.allSatisfy({ $0.chart.count <= 513 && $0.sequence.gaps == 0 && ($0.peakJitterMS ?? 100) < 0.001 }) else {
            fatalError("Analysis coverage, timing or bounded-chart check failed")
        }
        print("bytes=\(24 + count * 1516) packets=\(count) streams=128 analysis_seconds=\(Date().timeIntervalSince(started))")
    }
}
