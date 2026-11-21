import Foundation

public struct UsageCharge: Codable, Hashable, Sendable {
    public enum Rate: String, Codable, Sendable {
        case agentMinute, participantMinute, downstreamGB, transcodeAudioMinute, observabilityAudioMinute, observabilityEvent, noiseCancellationMinute
        case inputTokens, outputTokens, audioHour, characters
    }
    public let rate: Rate
    public let amount: Double
    public var model: String? = nil
    public func price(_ plan: PricePlan) -> Double? {
        switch rate {
        case .agentMinute: plan.agentMinute
        case .participantMinute: plan.participantMinute
        case .downstreamGB: plan.downstreamGB
        case .transcodeAudioMinute: plan.transcodeAudioMinute
        case .observabilityAudioMinute: plan.observabilityAudioMinute
        case .observabilityEvent: plan.observabilityEvent
        case .noiseCancellationMinute: plan.noiseCancellationMinute
        case .inputTokens: plan.rate(model: model ?? "", unit: .inputTokens)
        case .outputTokens: plan.rate(model: model ?? "", unit: .outputTokens)
        case .audioHour: plan.rate(model: model ?? "", unit: .audioHour)
        case .characters: plan.rate(model: model ?? "", unit: .characters)
        }
    }

    public init(rate: Rate, amount: Double, model: String? = nil) { self.rate = rate; self.amount = amount; self.model = model }
}

public struct CostUsageSnapshot: Codable, Sendable {
    public let date: Date
    public var planID: String
    public var priceDate: Date?
    public var lines: [CostLine]
    public var resourcesComplete: Bool
    public var estimate: Double { lines.compactMap(\.cost).reduce(0, +) }
    public var partial: Bool { !resourcesComplete || lines.contains { $0.cost == nil || $0.incomplete } }
    public func repriced(plan: PricePlan, priceDate: Date?) -> Self {
        var value = self; value.planID = plan.id; value.priceDate = priceDate
        value.lines = lines.map { line in
            guard let usage = line.usage else { return line }
            let price = usage.price(plan)
            return CostLine(group: line.group, item: line.item, quantity: line.quantity,
                            rate: price.map { Format.dollars($0) + " per pricing unit" } ?? "rate unknown",
                            cost: price.map { $0 * usage.amount }, usage: usage, incomplete: line.incomplete)
        }
        return value
    }
    public static func make(row: SessionRow, documents: [SessionResource: Result<SessionResourceDocument, Error>], plan: PricePlan, priceDate: Date?) -> Self {
        func json(_ kind: SessionResource) -> JSONValue? { guard case .success(let value) = documents[kind] else { return nil }; return value.json }
        let room = json(.summary).flatMap(RoomUsage.init(json:))
        let logs = (json(.logs)?.items ?? []).enumerated().map { LogRecord(json: $1, index: $0) }
        let spans = (json(.traces)?.items ?? []).enumerated().map { Span(json: $1, index: $0) }
        let metrics = (json(.metrics)?.items ?? []).enumerated().map { MetricPoint(json: $1, index: $0) }
        let complete = SessionResources.review.filter { $0 != .summary }.allSatisfy { kind in
            guard case .success(let value) = documents[kind] else { return false }; return value.readiness.state == .settled
        } && room != nil && row.session?.status != "active"
        return Self(date: row.startedAt ?? .now, planID: plan.id, priceDate: priceDate,
                    lines: SessionCost.lines(plan: plan, room: room, spans: spans, metrics: metrics, logs: logs, transcriptItems: json(.transcript)?.items.count ?? 0, noiseCancellation: false), resourcesComplete: complete)
    }

    public init(date: Date, planID: String, priceDate: Date? = nil, lines: [CostLine], resourcesComplete: Bool) { self.date = date; self.planID = planID; self.priceDate = priceDate; self.lines = lines; self.resourcesComplete = resourcesComplete }
}

public struct CostHistoryProgress: Codable, Sendable {
    public var query = SessionQuery()
    public var bookmark: SessionBookmark?
    public var completed = 0
    public var failed = 0
    public var finished = false
    public var repricing = false
    public var message: String?
    public var updated = Date()

    public init(query: SessionQuery = SessionQuery(), bookmark: SessionBookmark? = nil, completed: Int = 0, failed: Int = 0, finished: Bool = false, repricing: Bool = false, message: String? = nil, updated: Date = Date()) { self.query = query; self.bookmark = bookmark; self.completed = completed; self.failed = failed; self.finished = finished; self.repricing = repricing; self.message = message; self.updated = updated }
}

