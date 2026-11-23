import Foundation

/// A manual attribution of captured media to recorded audio. SIP addresses and SSRCs
/// alone do not establish which participant's audio is on a recording channel.
enum CaptureAudioTarget: Codable, Hashable, Identifiable, Sendable {
    case unassigned, user, agent
    case channel(recording: String, index: Int)
    var id: Self { self }
}

struct CaptureAudioLane: Identifiable, Sendable {
    let recording: String
    let channel: Int
    let title: String
    let role: CaptureAudioTarget?
    var id: CaptureAudioTarget { .channel(recording: recording, index: channel) }

    init(source: RecordingSource, channel: Int, count: Int, identical: Bool) {
        recording = source.kind.rawValue
        self.channel = channel
        title = source.title + " · " + source.channelName(channel, of: count, identical: identical)
        if count == 2, !identical, source.kind == .observability || source.userLeftAgentRight {
            role = channel == 0 ? .user : .agent
        } else { role = nil }
    }

    func matches(_ target: CaptureAudioTarget) -> Bool {
        target != .unassigned && (target == id || target == role)
    }
}

/// Follow a direction through SSRC/payload changes, but keep reverse directions,
/// capture interfaces and independently identified calls separate.
struct CaptureAudioDirection: Codable, Hashable, Sendable {
    let source: String
    let destination: String
    let interface: String
    let call: String

    init(_ series: CaptureJitterOverview.Series) {
        source = series.key.source; destination = series.key.destination
        interface = series.key.interface; call = series.call
    }
}

struct CaptureAudioMapping: Sendable {
    private var assignments: [CaptureAudioDirection: CaptureAudioTarget] = [:]

    func target(for series: CaptureJitterOverview.Series) -> CaptureAudioTarget {
        assignments[CaptureAudioDirection(series)] ?? .unassigned
    }

    mutating func assign(_ target: CaptureAudioTarget, to series: CaptureJitterOverview.Series) {
        let direction = CaptureAudioDirection(series)
        if target == .unassigned { assignments.removeValue(forKey: direction) }
        else { assignments[direction] = target }
    }

    static func title(_ target: CaptureAudioTarget, lanes: [CaptureAudioLane]) -> String {
        switch target {
        case .unassigned: "Unassigned"
        case .user: "User (left)"
        case .agent: "Agent (right)"
        case .channel: lanes.first { $0.id == target }?.title ?? "Unavailable recording channel"
        }
    }

    static func targets(lanes: [CaptureAudioLane]) -> [CaptureAudioTarget] {
        [.unassigned] + [.user, .agent].filter { target in lanes.contains { $0.role == target } } + lanes.map(\.id)
    }

    static func load(for capture: UUID, defaults: UserDefaults = .standard) -> Self {
        var result = Self()
        if let data = defaults.data(forKey: key(capture)),
           let saved = try? JSONDecoder().decode([CaptureAudioDirection: CaptureAudioTarget].self, from: data), saved.count <= 128 {
            result.assignments = saved
        }
        return result
    }

    func save(for capture: UUID, defaults: UserDefaults = .standard) {
        if assignments.isEmpty { defaults.removeObject(forKey: Self.key(capture)) }
        else if let data = try? JSONEncoder().encode(assignments) { defaults.set(data, forKey: Self.key(capture)) }
    }

    private static func key(_ id: UUID) -> String { "spectrogramCaptureChannels." + id.uuidString }
}
