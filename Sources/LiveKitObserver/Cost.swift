import Foundation

/// What LiveKit reports about a room's participants and bandwidth (`lk analytics session get`).
struct RoomUsage: Sendable, Hashable {
    struct Participant: Sendable, Hashable {
        let identity: String
        let seconds: Double
        /// Agents join as `agent-AJ_…`, egress as `EG_…`.
        var isAgent: Bool { identity.hasPrefix("agent-") }
        var isEgress: Bool { identity.hasPrefix("EG_") }
    }

    let participants: [Participant]
    let bytesOut: Double

    init(participants: [Participant], bytesOut: Double) {
        self.participants = participants
        self.bytesOut = bytesOut
    }

    init?(json: JSONValue) {
        guard let detail = json["detail"] ?? json["session"] else { return nil }
        participants = (detail["participants"]?.array ?? []).map { p in
            let sessions = p["sessions"]?.array ?? []
            var seconds = sessions.compactMap { $0["durationSeconds"]?.double }.reduce(0, +)
            if sessions.isEmpty, let joined = p["joinedAt"]?.date, let left = p["leftAt"]?.date { seconds = max(0, left.timeIntervalSince(joined)) }
            return Participant(identity: p["participantIdentity"]?.string ?? "", seconds: seconds)
        }
        bytesOut = detail["bandwidthOut"]?.double ?? 0
    }

    func seconds(_ include: (Participant) -> Bool) -> Double { participants.filter(include).map(\.seconds).reduce(0, +) }
}

/// A LiveKit Cloud plan's overage rates, in US dollars. Included allowances are not applied: the
/// breakdown says what a session costs once the month's allowance is used up.
struct PricePlan: Identifiable, Sendable {
    enum Unit: Sendable { case inputTokens, outputTokens, audioHour, characters }

    /// A LiveKit Inference price. `model` matches the reported model name exactly or as a prefix,
    /// so "cartesia/sonic-3" covers sonic-3.5 and sonic-3.6.
    struct ModelRate: Sendable {
        let model: String
        let unit: Unit
        let price: Double
    }

    let id: String
    let monthly: Double
    let agentMinute: Double
    let participantMinute: Double
    let downstreamGB: Double
    let transcodeAudioMinute: Double
    let observabilityAudioMinute: Double
    let observabilityEvent: Double
    let noiseCancellationMinute: Double
    /// Built in for a few models; replaced by LiveKit's full price list once it has been fetched.
    var inference: [ModelRate]
    let note: String

    var name: String { id }

    /// This plan with model prices from LiveKit's price list, when the list has prices for it.
    func with(_ catalog: PricingCatalog?) -> PricePlan {
        guard let rates = catalog?.rates[id.lowercased()], !rates.isEmpty else { return self }
        var plan = self
        plan.inference = rates
        return plan
    }

    func rate(model: String, unit: Unit) -> Double? {
        inference.filter { $0.unit == unit && (model == $0.model || model.hasPrefix($0.model)) }
            .max { $0.model.count < $1.model.count }?.price
    }

    /// Rates from livekit.com/pricing and a November 2026 Scale invoice (inference credits).
    static let scale = PricePlan(
        id: "Scale", monthly: 500, agentMinute: 0.01, participantMinute: 0.0004, downstreamGB: 0.10,
        transcodeAudioMinute: 0.004, observabilityAudioMinute: 0.005, observabilityEvent: 0.00003, noiseCancellationMinute: 0.0012,
        inference: [
            ModelRate(model: "openai/gpt-4.1-mini", unit: .inputTokens, price: 0.4),
            ModelRate(model: "openai/gpt-4.1-mini", unit: .outputTokens, price: 1.6),
            ModelRate(model: "openai/gpt-4.1", unit: .inputTokens, price: 2),
            ModelRate(model: "openai/gpt-4.1", unit: .outputTokens, price: 8),
            ModelRate(model: "deepgram/nova-3", unit: .audioHour, price: 0.252),
            ModelRate(model: "cartesia/sonic-3", unit: .characters, price: 37.5),
        ],
        note: "Scale: $500 a month includes 50,000 agent minutes, 1.5M participant minutes, 3 TB downstream, 8,000 transcode minutes, 50,000 observability audio minutes, 5M observability events, 10,000 noise cancellation minutes, and $50 of inference.")

    /// Ship's rates from livekit.com/pricing. Its model prices come from LiveKit's price list once fetched.
    static let ship = PricePlan(
        id: "Ship", monthly: 50, agentMinute: 0.01, participantMinute: 0.0005, downstreamGB: 0.12,
        transcodeAudioMinute: 0.005, observabilityAudioMinute: 0.005, observabilityEvent: 0.00003, noiseCancellationMinute: 0.0012,
        inference: [],
        note: "Ship: $50 a month includes 5,000 agent minutes, 150,000 participant minutes, 250 GB downstream, 600 transcode minutes, and $5 of inference. Inference is billed at Ship's model prices.")

    static let all = [scale, ship]
    static func named(_ id: String) -> PricePlan { all.first { $0.id == id } ?? scale }
}

/// LiveKit Inference prices for every model and plan, from the price list the LiveKit docs server publishes (the
/// same data as `lk docs pricing-info --json`). Fetched at most once a day and cached; until then, or if it can't be
/// reached, the built-in rates are used. Connection, recording, and other rates stay built in: the list gives
/// those only as sentences.
struct PricingCatalog: Sendable {
    let fetched: Date
    /// Model prices by plan ID ("build", "ship", "scale").
    let rates: [String: [PricePlan.ModelRate]]

    static let endpoint = URL(string: "https://docs.livekit.io/mcp/")!
    static let maximumAge: TimeInterval = 24 * 3600

    init(fetched: Date, rates: [String: [PricePlan.ModelRate]]) {
        self.fetched = fetched
        self.rates = rates
    }

    /// Reads the price list's `inference` section: speech-to-text per minute, LLM tokens per million, and
    /// text-to-speech characters per million.
    init?(json: JSONValue, fetched: Date) {
        guard let inference = json["inference"] else { return nil }
        var rates: [String: [PricePlan.ModelRate]] = [:]
        for kind in ["stt", "llm", "tts"] {
            for model in inference[kind]?.array ?? [] {
                guard let id = model["model_id"]?.string else { continue }
                for rate in model["rates"]?.array ?? [] {
                    let (unit, scale): (PricePlan.Unit?, Double) = switch rate["metric"]?.string {
                    case "minute_usage": (.audioHour, 60)
                    case "input_tokens": (.inputTokens, 1)
                    case "output_tokens": (.outputTokens, 1)
                    case "character_usage": (.characters, 1)
                    default: (nil, 1)
                    }
                    guard let unit else { continue }
                    for plan in ["build", "ship", "scale"] {
                        if let price = rate[plan]?.double { rates[plan, default: []].append(.init(model: id, unit: unit, price: price * scale)) }
                    }
                }
            }
        }
        guard !rates.isEmpty else { return nil }
        self.init(fetched: fetched, rates: rates)
    }

    /// Asks the docs server for the price list. It answers as a server-sent event holding a JSON-RPC result,
    /// whose text is the price list.
    static func download() async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_pricing_info","arguments":{"format":"json"}}}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try priceList(fromResponse: data)
    }

    /// The price list inside a docs server response, which is either plain JSON or server-sent events.
    static func priceList(fromResponse data: Data) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let body = text.hasPrefix("{") ? text : text.split(separator: "\n").filter { $0.hasPrefix("data:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }.joined()
        let reply = try JSONValue.parse(Data(body.utf8))
        guard let list = reply["result"]?["content"]?.array?.first?["text"]?.string else { throw URLError(.cannotParseResponse) }
        return Data(list.utf8)
    }
}

/// One line of a session's cost: what was used, the rate, and the cost (nil when the rate is unknown
/// or the usage is billed by another provider).
struct CostLine: Identifiable, Hashable, Sendable {
    enum Group: String, CaseIterable, Sendable { case infrastructure = "LiveKit Cloud", inference = "LiveKit Inference", observability = "Observability" }
    let group: Group
    let item: String
    let quantity: String
    let rate: String
    let cost: Double?
    var id: String { group.rawValue + item }
}

enum SessionCost {
    /// Usage of each model through LiveKit Inference, read from the session's traces and metrics.
    struct ModelUsage: Hashable { var amount: Double = 0; var requests = 0; var unknown = 0; var provider = "" }

    static func lines(plan: PricePlan, room: RoomUsage?, spans: [Span], metrics: [MetricPoint], logs: [LogRecord],
                      transcriptItems: Int, noiseCancellation: Bool) -> [CostLine] {
        var lines: [CostLine] = []
        func add(_ group: CostLine.Group, _ item: String, _ quantity: String, _ rate: String, _ cost: Double?) {
            lines.append(CostLine(group: group, item: item, quantity: quantity, rate: rate, cost: cost))
        }
        func minutes(_ seconds: Double) -> String { String(format: "%.1f min", seconds / 60) }
        func dollars(_ value: Double) -> String { Format.dollars(value) }

        if let room {
            // Only agents deployed to LiveKit Cloud bill agent session minutes; their telemetry carries the Cloud agent ID.
            let cloudAgent = spans.contains { !($0.attributes["lk.cloud_agent_id"]?.string ?? "").isEmpty }
                || logs.contains { !($0.attributes["lk.cloud_agent_id"]?.string ?? "").isEmpty }
            let agent = room.seconds(\.isAgent)
            if cloudAgent {
                add(.infrastructure, "Agent session", minutes(agent), "\(dollars(plan.agentMinute))/min", agent / 60 * plan.agentMinute)
            } else if agent > 0 {
                add(.infrastructure, "Agent session (self-hosted)", minutes(agent), "not billed", 0)
            }
            let webrtc = room.seconds { !$0.isEgress }
            add(.infrastructure, "WebRTC participants (\(room.participants.filter { !$0.isEgress }.count))", minutes(webrtc),
                "\(dollars(plan.participantMinute))/min", webrtc / 60 * plan.participantMinute)
            let gb = room.bytesOut / 1e9
            add(.infrastructure, "Downstream data", String(format: "%.1f MB", room.bytesOut / 1e6), "\(dollars(plan.downstreamGB))/GB", gb * plan.downstreamGB)
            let egress = room.seconds(\.isEgress)
            if egress > 0 {
                add(.infrastructure, "Egress transcode (audio)", minutes(egress), "\(dollars(plan.transcodeAudioMinute))/min", egress / 60 * plan.transcodeAudioMinute)
            }
            if noiseCancellation {
                let users = room.seconds { !$0.isAgent && !$0.isEgress }
                add(.infrastructure, "Noise cancellation", minutes(users), "\(dollars(plan.noiseCancellationMinute))/min", users / 60 * plan.noiseCancellationMinute)
            }
            if !spans.isEmpty || transcriptItems > 0 {
                add(.observability, "Session recording", minutes(agent), "\(dollars(plan.observabilityAudioMinute))/min", agent / 60 * plan.observabilityAudioMinute)
            }
        }
        let events = logs.count + spans.count + transcriptItems
        if events > 0 {
            add(.observability, "Logs, spans, and transcript items", "\(events.formatted())", "\(dollars(plan.observabilityEvent * 1000))/1,000",
                Double(events) * plan.observabilityEvent)
        }

        // LLM tokens, by model.
        var input: [String: ModelUsage] = [:], output: [String: ModelUsage] = [:]
        for span in spans where span.name == "llm_request" {
            let model = span.attributes["gen_ai.request.model"]?.string ?? span.attributes["gen_ai.response.model"]?.string ?? "unknown"
            let provider = span.attributes["gen_ai.provider.name"]?.string ?? ""
            input[model, default: ModelUsage(provider: provider)].amount += span.attributes["gen_ai.usage.input_tokens"]?.double ?? 0
            input[model]!.requests += 1
            output[model, default: ModelUsage(provider: provider)].amount += span.attributes["gen_ai.usage.output_tokens"]?.double ?? 0
        }
        for (model, usage) in input.sorted(by: { $0.key < $1.key }) {
            for (label, unit, amount) in [("input", PricePlan.Unit.inputTokens, usage.amount), ("output", .outputTokens, output[model]?.amount ?? 0)] {
                let quantity = "\(Int(amount).formatted()) tokens"
                if usage.provider != "livekit" {
                    add(.inference, "LLM \(model) \(label)", quantity, "billed by \(usage.provider.isEmpty ? "provider" : usage.provider)", nil)
                } else if let price = plan.rate(model: model, unit: unit) {
                    add(.inference, "LLM \(model) \(label)", quantity, "\(dollars(price))/M", amount / 1e6 * price)
                } else {
                    add(.inference, "LLM \(model) \(label)", quantity, "rate unknown", nil)
                }
            }
        }

        // Say so when the traces show no LLM at all (a scripted agent, say), rather than leave the line out.
        if input.isEmpty, !spans.isEmpty {
            add(.inference, "LLM", "none", "no LLM requests in the traces", 0)
        }

        // Speech-to-text audio, from the agent's usage metrics.
        var stt: [String: ModelUsage] = [:]
        for point in metrics where point.name == "lk.agents.usage.stt_audio_duration" {
            let model = point.attributes["model_name"]?.string ?? "unknown"
            stt[model, default: ModelUsage(provider: point.attributes["model_provider"]?.string ?? "")].amount += point.value ?? point.sum ?? 0
        }
        for (model, usage) in stt.sorted(by: { $0.key < $1.key }) {
            if usage.provider != "livekit" {
                add(.inference, "STT \(model)", minutes(usage.amount), "billed by \(usage.provider.isEmpty ? "provider" : usage.provider)", nil)
            } else if let price = plan.rate(model: model, unit: .audioHour) {
                add(.inference, "STT \(model)", minutes(usage.amount), "\(dollars(price))/hour", usage.amount / 3600 * price)
            } else {
                add(.inference, "STT \(model)", minutes(usage.amount), "rate unknown", nil)
            }
        }

        // Text-to-speech characters: the text of each request, unless PII redaction removed it.
        var tts: [String: ModelUsage] = [:]
        for span in spans where span.name == "tts_request" {
            let metadata = span.attributes["lk.tts_metrics"]?["metadata"]
            let model = metadata?["model_name"]?.string ?? "unknown"
            tts[model, default: ModelUsage(provider: metadata?["model_provider"]?.string ?? "")].requests += 1
            if let text = span.attributes["lk.pii.input_text"]?.string { tts[model]!.amount += Double(text.count) } else { tts[model]!.unknown += 1 }
        }
        for (model, usage) in tts.sorted(by: { $0.key < $1.key }) {
            var quantity = "\(Int(usage.amount).formatted()) chars"
            if usage.unknown > 0 { quantity += " (+\(usage.unknown) requests without text)" }
            if usage.provider != "livekit" {
                add(.inference, "TTS \(model)", quantity, "billed by \(usage.provider.isEmpty ? "provider" : usage.provider)", nil)
            } else if let price = plan.rate(model: model, unit: .characters) {
                add(.inference, "TTS \(model)", quantity, "\(dollars(price))/M chars", usage.amount / 1e6 * price)
            } else {
                add(.inference, "TTS \(model)", quantity, "rate unknown", nil)
            }
        }
        return lines
    }
}
