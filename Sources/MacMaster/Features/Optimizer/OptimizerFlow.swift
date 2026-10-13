import SwiftUI
import Observation

enum OptimizerStage: Equatable {
    case idle, analyzing, review, running, done
}

/// View-level state machine for the Optimize tab: analyze, review, run, result.
@MainActor
@Observable
final class OptimizerFlow {
    var stage: OptimizerStage = .idle
    var selection: Set<String> = []
    var notice: String?
    var isFreeingMemory = false
    var forceMessage: String?

    @ObservationIgnored private let engine = OptimizerEngine.shared

    var selectedRecs: [OptimizerRecommendation] {
        engine.recommendations.filter { selection.contains($0.id) && $0.isActionable }
    }

    var needsConfirmation: Bool {
        selectedRecs.contains { $0.quitsApps || $0.irreversible || $0.requiresAdmin }
    }

    /// Plain-language list of what is about to happen.
    var confirmationText: String {
        let recs = selectedRecs
        var lines: [String] = []
        let quits = recs.filter(\.quitsApps)
        if !quits.isEmpty { lines.append("Quits: " + quits.map(\.title).joined(separator: ", ") + ". Unsaved work may prompt you to save.") }
        if recs.contains(where: \.irreversible) { lines.append("Permanent: " + recs.filter(\.irreversible).map(\.title).joined(separator: ", ") + " cannot be undone.") }
        let admin = recs.filter(\.requiresAdmin)
        if !admin.isEmpty { lines.append("\(admin.count) task\(admin.count == 1 ? "" : "s") will ask for your administrator password.") }
        return lines.joined(separator: "\n")
    }

    func begin() async {
        guard stage == .idle || stage == .done || stage == .review else { return }
        stage = .analyzing
        while engine.isAnalyzing { try? await Task.sleep(for: .milliseconds(250)) }
        await engine.analyze()
        selection = Set(engine.recommendations.filter { $0.isSafe && $0.isActionable }.map(\.id))
        stage = .review
    }

    func applySelected() async {
        let ids = selection
        guard !ids.isEmpty else { return }
        stage = .running
        await engine.apply(ids)
        stage = .done
    }

    func reset() { stage = .idle; selection = []; notice = nil }

    func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func setAll(_ recs: [OptimizerRecommendation], on: Bool) {
        for r in recs where r.isActionable { if on { selection.insert(r.id) } else { selection.remove(r.id) } }
    }

    func force(_ rec: OptimizerRecommendation) async {
        guard let f = rec.force else { return }
        let outcome = await f.run()
        forceMessage = outcome.message
        if outcome.ok {
            selection.remove(rec.id)
            engine.dismiss(rec.id)
        }
    }

    func freeMemory() async {
        isFreeingMemory = true
        notice = await engine.freeMemory()
        isFreeingMemory = false
    }
}
