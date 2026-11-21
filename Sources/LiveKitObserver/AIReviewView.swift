import ObserverCore
import SwiftUI

struct AIReviewView: View {
    let detail: SessionDetail
    let project: ProjectRef
    var captureEvidence: [AIEvidence] = []
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var evidence: [AIEvidence] = []
    @State private var prompt = ""
    @State private var settings = AISettings()
    @State private var review: AIReviewResult?
    @State private var message: String?
    @State private var working = false
    @State private var request: Task<Void, Never>?
    private var inputRate: Double? { app.plan.rate(model: settings.model, unit: .inputTokens) }
    private var outputRate: Double? { app.plan.rate(model: settings.model, unit: .outputTokens) }
    private var estimate: Double? {
        guard let inputRate, let outputRate, let pricing = app.pricing, Date().timeIntervalSince(pricing.fetched) <= PricingCatalog.maximumAge else { return nil }
        // UTF-8 bytes plus instruction/format overhead is deliberately conservative.
        return Double(prompt.utf8.count + AIReviewResult.systemPrompt.utf8.count + 1024) / 1e6 * inputRate + 4096 / 1e6 * outputRate
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("AI session review").font(.title2.bold()); Spacer(); Button("Close") { request?.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }
            Text("\(project.name) · \(settings.model)").font(.headline)
            if !settings.enabled {
                Text("AI is off for this project. Enable it in Settings → AI to send a review request.").foregroundStyle(.secondary)
            }
            Text("Sends only the evidence shown below through LiveKit Inference to the selected model's provider. This may include caller speech and personal data. Review it before continuing.").font(.callout)
            DisclosureGroup("Evidence to send (\(evidence.count) selected records)") {
                ScrollView { Text(prompt).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 190)
            }
            HStack {
                Text(estimate.map { String(format: "Conservative estimate: up to $%.4f", $0) } ?? "Price unavailable. Refresh prices in Settings before running AI.").font(.caption)
                Spacer()
                if working { ProgressView().controlSize(.small); Button("Cancel request") { request?.cancel() } }
                else { Button("Diagnose and suggest flags") { start() }.disabled(!settings.enabled || app.inferenceModels[settings.model]?.isRetired() == true || estimate == nil || evidence.isEmpty) }
            }
            Text("The estimate is reserved against this Mac's monthly limit. Interrupted requests without usage keep that reservation because the provider may have charged for them.").font(.caption2).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let review {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("AI-generated · \(review.createdAt.formatted())", systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
                        Text(review.summary).textSelection(.enabled)
                        ForEach(review.findings) { finding in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(finding.explanation).textSelection(.enabled)
                                    HStack {
                                        ForEach(finding.evidenceIDs, id: \.self) { id in
                                            if let item = review.evidence.first(where: { $0.id == id }), let date = item.date {
                                                Button(Format.offset(date, from: detail.row.startedAt)) { if let offset = app.player.offset(for: date) { app.player.seek(to: offset) } }.help(item.text)
                                            }
                                        }
                                        Spacer()
                                        if let decision = finding.decision { Text(decision.capitalized).font(.caption).foregroundStyle(.secondary) }
                                        else {
                                            Button("Dismiss") { decide(finding.id, accepted: false) }
                                            Button("Accept flag") { decide(finding.id, accepted: true) }
                                                .disabled(!finding.evidenceIDs.contains { id in review.evidence.contains { $0.id == id && $0.date != nil } })
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Text(String(format: "Review cost: $%.4f%@ · Request: %@", review.cost, review.usageKnown ? "" : " (reserved estimate)", review.requestID.isEmpty ? "not supplied" : review.requestID)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.frame(minHeight: 160, maxHeight: 360)
            }
        }.padding(24).frame(width: 760)
        .task {
            settings = AISettings.load(project: project.id)
            evidence = captureEvidence + Self.evidence(detail)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            while ((try? encoder.encode(evidence).count) ?? 0) > 128 * 1024 {
                evidence = evidence.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
            }
            prompt = String(decoding: (try? encoder.encode(evidence)) ?? Data(), as: UTF8.self)
            review = try? await AIReviewStore.shared.load(project: project.id, session: detail.row.id)
            detail.aiReview = review
        }
        .onDisappear { request?.cancel() }
        .onChange(of: app.projectIdentity) { _, new in if new != project.id { request?.cancel(); dismiss() } }
    }

    @MainActor static func evidence(_ detail: SessionDetail) -> [AIEvidence] {
        var values: [AIEvidence] = []
        let count = detail.transcript.count
        let step = max(1, Int(ceil(Double(count) / 150)))
        for index in stride(from: 0, to: count, by: step) {
            let item = detail.transcript[index]
            values.append(AIEvidence(id: "turn-\(index)", kind: "\(item.role.rawValue) \(item.kind)", text: redacted(String(item.text.prefix(1500))), date: item.start))
        }
        for (index, log) in detail.logs.enumerated().filter({ $0.element.level >= .warn }).prefix(40) {
            values.append(AIEvidence(id: "log-\(index)", kind: log.level.label, text: redacted(String(log.message.prefix(1000))), date: log.timestamp))
        }
        for (index, flag) in detail.flags.prefix(40).enumerated() {
            values.append(AIEvidence(id: "flag-\(index)", kind: "Reviewer flag", text: redacted(String(flag.note.prefix(1500))), date: flag.start))
        }
        for (index, span) in detail.spans.enumerated().filter({ $0.element.failed || $0.element.name.localizedCaseInsensitiveContains("tool") }).prefix(40) {
            // Only known tool evidence fields; unrelated trace attributes can include secrets.
            let keys = ["gen_ai.tool.name", "gen_ai.tool.call.arguments", "gen_ai.tool.call.result", "tool_name", "tool_result"]
            let attributes = keys.compactMap { key in span.attributes[key].map { key + ": " + String($0.description.prefix(1000)) } }.joined(separator: "\n")
            values.append(AIEvidence(id: "span-\(index)", kind: "Trace evidence", text: redacted(String((span.name + "\n" + span.statusMessage + "\n" + attributes).prefix(3000))), date: span.start))
        }
        // This preview is bounded independently of session size. Selection is explicitly described.
        return values
    }
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)((?:api[_-]?key|api[_-]?secret|password|authorization|token)["']?\s*[:=]\s*)("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')"#, with: "$1\"[REDACTED]\"", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)((?:api[_-]?key|api[_-]?secret|password|authorization|token)\s*[:=]\s*)[^\s,;]+"#, with: "$1[REDACTED]", options: .regularExpression)
    }
    private func start() {
        guard app.inferenceModels[settings.model]?.isRetired() != true, let cli = app.cli, let estimate, let inputRate, let outputRate, app.projectIdentity == project.id,
              AISettings.load(project: project.id).enabled, !working else { return }
        working = true; message = nil
        request = Task {
            defer { working = false }
            do {
                let charge = try await AIReviewStore.shared.reserve(project: project.id, amount: estimate, limit: AISettings.load(project: project.id).monthlyLimit, session: detail.row.id, feature: "Session diagnosis")
                let reply = try await InferenceClient.shared.complete(cli: cli, projectURL: project.url, settings: settings, prompt: prompt)
                let known = reply.inputTokens != nil && reply.outputTokens != nil
                let cost = known ? Double(reply.inputTokens!) / 1e6 * inputRate + Double(reply.outputTokens!) / 1e6 * outputRate : estimate
                try await AIReviewStore.shared.settle(charge, cost: cost, estimated: !known)
                let (summary, findings) = try AIReviewResult.findings(from: reply.text, evidence: evidence)
                try Task.checkCancellation()
                let value = AIReviewResult(project: project.id, session: detail.row.id, model: settings.model, requestID: reply.requestID,
                                           createdAt: .now, summary: summary, evidence: evidence, findings: findings, cost: cost, usageKnown: known, quota: reply.quota)
                try await AIReviewStore.shared.save(value); review = value; detail.aiReview = value; detail.aiChargeRevision += 1
            } catch is CancellationError { message = "Request cancelled. Any unreported usage remains reserved against the limit." }
            catch { message = error.localizedDescription }
        }
    }
    private func decide(_ id: UUID, accepted: Bool) {
        guard var review, let index = review.findings.firstIndex(where: { $0.id == id }), review.findings[index].decision == nil else { return }
        let finding = review.findings[index]
        if accepted {
            let dates = review.evidence.filter { finding.evidenceIDs.contains($0.id) }.compactMap(\.date).sorted()
            guard let start = dates.first, let end = dates.last else { return }
            if !detail.flags.contains(where: { $0.id == id }) {
                var flag = Flag(id: id, start: start, end: max(end, start.addingTimeInterval(1)), note: finding.explanation)
                flag.aiModel = review.model; flag.aiRequestID = review.requestID
                detail.flags.append(flag); detail.saveFlags()
            }
        }
        review.findings[index].decision = accepted ? "accepted" : "dismissed"
        self.review = review; detail.aiReview = review
        Task { do { try await AIReviewStore.shared.save(review) } catch { message = error.localizedDescription } }
    }
}

struct AISettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var settings = AISettings()
    @State private var consent = false
    @State private var message: String?
    @State private var spent: Double?
    @State private var testing = false
    @State private var quota: [String: String] = [:]
    var body: some View {
        Form {
            Section("AI for \(app.selectedProject?.name ?? "this project")") {
                Toggle("Enable LiveKit Inference", isOn: Binding(get: { settings.enabled }, set: { if $0 { consent = true } else { settings.enabled = false; save() } }))
                Text("Off by default. Each action shows its evidence and estimated cost before sending. Requests are billed to this project and share rate limits with live agents. Transcripts and audio may contain personal data.").font(.caption).foregroundStyle(.secondary)
                Picker("Text model", selection: $settings.model) {
                    ForEach(Array(Set(app.availableModels(unit: .inputTokens) + [settings.model])).sorted(), id: \.self) { Text(app.modelLabel($0)).tag($0) }
                }
                if let info = app.inferenceModels[settings.model], info.deprecated || info.isRetired() { Text(info.detail).font(.caption).foregroundStyle(.orange) }
                LabeledContent("Monthly limit on this Mac ($)") { TextField("Limit", value: $settings.monthlyLimit, format: .number).frame(width: 100) }
                Toggle("Use low inference priority", isOn: $settings.lowPriority)
                Text(spent.map { String(format: "This month: $%.4f (includes pending reservations)", $0) } ?? "Spending not loaded").font(.caption)
                Text(["RPM", "TPM", "Credits"].map { "\($0): \(quota[$0 + "-Used"] ?? "?") / \(quota[$0 + "-Limit"] ?? "?")" }.joined(separator: " · ")).font(.caption)
                HStack {
                    Button("Save settings") { save() }
                    Button("Test connection") { test() }.disabled(!settings.enabled || testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
            Section {
                Text("AI features are experimental. Review suggestions against the original evidence. A connection test sends no session content.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(height: 570)
        .task(id: app.projectIdentity) { settings = AISettings.load(project: app.projectIdentity); spent = try? await AIReviewStore.shared.spent(project: app.projectIdentity); quota = await InferenceClient.shared.quota(project: app.cli?.project ?? "") }
        .alert("Enable AI for \(app.selectedProject?.name ?? "this project")?", isPresented: $consent) {
            Button("Cancel", role: .cancel) {}
            Button("Enable AI") { settings.enabled = true; save() }
        } message: { Text("Your selected evidence will be sent through LiveKit Inference to the model provider only when you start an action. The project pays for requests. This Mac's spending guard is an estimate, not a billing cap across other devices or agents.") }
    }
    private func save() {
        guard settings.monthlyLimit.isFinite, settings.monthlyLimit > 0 else { message = "Enter a positive monthly limit."; return }
        settings.save(project: app.projectIdentity); message = "Settings saved."
    }
    private func test() {
        guard let cli = app.cli, let project = app.selectedProject else { return }; testing = true
        Task {
            defer { testing = false }
            do { let models = try await InferenceClient.shared.test(cli: cli, projectURL: project.url); message = "Connected. \(models.count) models available." }
            catch { message = error.localizedDescription }
        }
    }
}
