import SwiftUI

/// A secondary millisecond scale drawn over the mel image. It uses exactly the lane's
/// horizontal transform and never handles gestures or changes the frequency scale.
struct SpectrogramJitterOverlay: View {
    let rows: [CaptureJitterOverview.Series]
    let timeline: SpectrogramJitterTimeline
    let window: ClosedRange<Date>
    let pinch: CGFloat
    let anchor: CGFloat

    var body: some View {
        let range = timeline.range(for: window)
        let values = rows.flatMap { row in
            row.points.enumerated().filter { index, point in
                let low = index > 0 ? min(point.seconds, row.points[index - 1].seconds) : point.seconds
                let high = index + 1 < row.points.count ? max(point.seconds, row.points[index + 1].seconds) : point.seconds
                return (low...max(low, high)).overlaps(range)
            }.map { $0.element.jitterMS }
        }
        let domain = CaptureJitterOverview.valueDomain(values)
        let measured = values.contains { $0 != nil }
        GeometryReader { geo in
            Canvas { context, size in
                let top = 30.0, bottom = max(31, size.height - 20)
                func x(_ seconds: Double) -> CGFloat {
                    let fraction = (seconds - range.lowerBound) / (range.upperBound - range.lowerBound)
                    return (anchor + (fraction - anchor) * pinch) * size.width
                }
                func y(_ value: Double) -> CGFloat { bottom - (bottom - top) * (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound) }
                if measured {
                    for (low, high, color) in [(0.0, 5.0, Color.green), (5.0, 30.0, .orange), (30.0, max(30, domain.upperBound), .red)] {
                        let a = max(domain.lowerBound, low), b = min(domain.upperBound, high)
                        if b > a { context.fill(Path(CGRect(x: 1, y: y(b), width: 3, height: y(a) - y(b))), with: .color(color)) }
                    }
                }
                for row in rows {
                    var path = Path(), connected = false
                    for bucket in row.points {
                        guard let value = bucket.jitterMS, value.isFinite else { connected = false; continue }
                        let point = CGPoint(x: x(bucket.seconds), y: y(value))
                        if connected { path.addLine(to: point) } else { path.move(to: point) }
                        connected = true
                        if range.contains(bucket.seconds) {
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(Self.color(row.number)))
                        }
                    }
                    context.stroke(path, with: .color(.black.opacity(0.85)), lineWidth: 3.5)
                    context.stroke(path, with: .color(Self.color(row.number)), lineWidth: 1.5)
                }
            }
            if measured {
                Text(String(format: "%.3g ms", domain.upperBound)).font(.caption2.monospacedDigit())
                    .padding(.horizontal, 3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 2))
                    .offset(x: 6, y: 25)
            }
            HStack(spacing: 5) {
                Text(measured ? String(format: "Jitter · %.3g ms", domain.lowerBound) : "Jitter · no measurements here")
                ForEach(rows) { row in
                    Text("RTP \(row.number)").foregroundStyle(row.points.contains { $0.jitterMS != nil } ? Self.color(row.number) : .gray)
                }
            }
            .font(.caption2.monospacedDigit()).lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(3)
        }
        .foregroundStyle(.white)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jitter overlay: " + rows.map { "RTP \($0.number)" }.joined(separator: ", "))
    }

    static func color(_ number: Int) -> Color {
        [.cyan, .purple, .yellow, .pink, .mint, .orange, .blue, .white][(number - 1) % 8]
    }
}
