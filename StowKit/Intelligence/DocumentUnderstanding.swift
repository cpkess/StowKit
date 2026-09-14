import Foundation

struct UnderstandingInput: Sendable {
    let document: HouseholdDocument
    let text: String
    let collections: [String]
    let truncated: Bool
}
struct DocumentUnderstanding: Codable, Sendable, Equatable {
    var title = ""
    var documentType = ""
    var collection = ""
    var correspondent = ""
    var tags: [String] = []
    var summary = ""
    var evidence = ""
    var confidence = 0.0
    var provider = "Local rules"
    var note = ""
}
protocol DocumentIntelligenceProvider: Sendable {
    func understand(_ input: UnderstandingInput) async throws -> DocumentUnderstanding
}

/// Confidence is a conservative filing heuristic, never a model's claimed probability.
enum UnderstandingPolicy {
    static let automaticThreshold = 0.90
    static let filingThreshold = 0.65
    static let fields = ["title", "summary", "correspondent", "collections", "tags", "review"]
    static func validated(_ proposal: DocumentUnderstanding, input: UnderstandingInput) -> DocumentUnderstanding {
        var result = proposal
        result.title = String(result.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        result.summary = String(result.summary.prefix(600))
        result.correspondent = String(result.correspondent.prefix(120))
        result.tags = Array(Set(result.tags.map { String($0.prefix(40)) }.filter { !$0.isEmpty })).sorted().prefix(8).map { $0 }
        let text = TextNormalization.searchKey(input.text)
        if !result.correspondent.isEmpty && !text.contains(TextNormalization.searchKey(result.correspondent)) { result.correspondent = "" }
        let evidence = TextNormalization.searchKey(result.evidence).trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.collections.contains(result.collection) || evidence.count < 5 || !text.contains(evidence) {
            result.collection = ""; result.confidence = 0
        }
        if !result.confidence.isFinite { result.confidence = 0 }
        result.confidence = min(1, max(0, result.confidence))
        if input.truncated { result.confidence = min(result.confidence, 0.64); result.note = "Only an excerpt was analyzed. Review the full document before filing." }
        return result
    }
    static func merge(_ result: DocumentUnderstanding, into document: HouseholdDocument, protected: Set<String>, explicit: Bool = false) -> HouseholdDocument {
        var edited = document
        guard explicit || result.confidence >= filingThreshold else {
            if !protected.contains("review") { edited.needsReview = true }
            return edited
        }
        if !protected.contains("title") && !result.title.isEmpty { edited.title = result.title }
        if !protected.contains("summary") && !result.summary.isEmpty { edited.summary = result.summary }
        if !protected.contains("correspondent") && !result.correspondent.isEmpty { edited.correspondent = result.correspondent }
        if !protected.contains("collections") && !result.collection.isEmpty { edited.collections.insert(result.collection) }
        if !protected.contains("tags") && !result.tags.isEmpty { edited.tags = result.tags.joined(separator: ", ") }
        if !protected.contains("review") { edited.needsReview = explicit ? false : result.confidence < filingThreshold }
        return edited
    }
}
