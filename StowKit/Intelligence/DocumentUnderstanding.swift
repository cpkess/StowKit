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
    /// Names of the filing rules that also applied. Optional so results saved before rules decode.
    var rules: [String]?
    /// "yyyy-MM-dd" days and an amount as written, each checked against the text by `validated`.
    /// Optional so results saved before 1.5 still decode.
    var issuedOn: String?
    var dueOn: String?
    var expiresOn: String?
    var amount: String?
    /// People, organizations, and things named in the document; each checked against the text.
    var entities: [String]?
}
protocol DocumentIntelligenceProvider: Sendable {
    func understand(_ input: UnderstandingInput) async throws -> DocumentUnderstanding
}

/// Confidence is a conservative filing heuristic, never a model's claimed probability.
enum UnderstandingPolicy {
    static let automaticThreshold = 0.90
    static let filingThreshold = 0.65
    static let fields = ["title", "summary", "correspondent", "collections", "tags", "review",
                         "documentDate", "documentType", "amount", "dueDate", "expiresAt", "entities"]
    static func validated(_ proposal: DocumentUnderstanding, input: UnderstandingInput) -> DocumentUnderstanding {
        var result = proposal
        result.title = String(result.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        result.summary = String(result.summary.prefix(600))
        result.correspondent = String(result.correspondent.prefix(120))
        result.tags = Array(Set(result.tags.map { String($0.prefix(40)) }.filter { !$0.isEmpty })).sorted().prefix(8).map { $0 }
        result.documentType = String(result.documentType.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let days = DocumentFacts.detectedDays(in: input.text)
        result.issuedOn = DocumentFacts.supportedDay(result.issuedOn, among: days)
        result.dueOn = DocumentFacts.supportedDay(result.dueOn, among: days)
        result.expiresOn = DocumentFacts.supportedDay(result.expiresOn, among: days)
        result.amount = DocumentFacts.supportedAmount(result.amount, in: input.text)
        let named = (result.entities ?? []).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
            .filter { DocumentFacts.named($0, in: input.text) }
        var seen = Set<String>()
        let unique = named.filter { seen.insert($0.lowercased()).inserted }.prefix(5)
        result.entities = unique.isEmpty ? nil : Array(unique)
        let text = TextNormalization.searchKey(input.text)
        if !result.correspondent.isEmpty && !text.contains(TextNormalization.searchKey(result.correspondent)) { result.correspondent = "" }
        if !input.collections.contains(result.collection) || !evidenceSupported(result.evidence, by: input.text) {
            result.collection = ""; result.confidence = 0
        }
        if !result.confidence.isFinite { result.confidence = 0 }
        result.confidence = min(1, max(0, result.confidence))
        if input.truncated { result.confidence = min(result.confidence, 0.64); result.note = "Based on the first pages only. Check the rest before filing." }
        return result
    }
    /// The model backs its collection with a quote. Measured on the owner's documents
    /// (2026-09-21), every quoted word was in the document, but the model reflows quotes: it
    /// changes spacing and punctuation and joins words from separate lines, so an exact character
    /// match rejected 3 of 4 correct collections. Words are compared instead: in order, or, for a
    /// quote of three or more words, all present. A word the document lacks still fails it.
    static func evidenceSupported(_ evidence: String, by text: String) -> Bool {
        func words(_ value: String) -> [String] { TextNormalization.searchKey(value).split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let quote = words(evidence)
        guard !quote.isEmpty, quote.joined().count >= 5 else { return false }
        let source = words(text)
        guard source.count >= quote.count else { return false }
        if (0...(source.count - quote.count)).contains(where: { source[$0..<($0 + quote.count)].elementsEqual(quote) }) { return true }
        let present = Set(source)
        return quote.count >= 3 && quote.allSatisfy(present.contains)
    }
    /// Filing automatically needs text worth trusting. Two lines off a scan, or a transcription a
    /// language model produced, can support a confident and wrong conclusion — a birth certificate
    /// read as "life insurance" — so those documents wait in Inbox for the owner instead.
    /// `scanned` matters: a PDF whose own text layer holds one line really is a one-line document,
    /// while a scan that produced one line was mostly missed.
    static func canFileAutomatically(text: String, readByModel: Bool, scanned: Bool) -> Bool {
        guard !readByModel else { return false }
        guard scanned else { return true }
        return !TextQuality.looksUnusable(text, minimumWords: TextQuality.scannedPageMinimumWords)
    }
    static func merge(_ result: DocumentUnderstanding, into document: HouseholdDocument, protected: Set<String>,
                      explicit: Bool = false, trustworthyText: Bool = true) -> HouseholdDocument {
        var edited = document
        // Dates and an amount were checked against the text in `validated`, so they are filled even
        // when filing is uncertain; the document stays in Inbox for review either way.
        if !protected.contains("amount"), let amount = result.amount { edited.amount = amount }
        if !protected.contains("dueDate"), let day = result.dueOn.flatMap(DocumentFacts.date) { edited.dueDate = day }
        if !protected.contains("expiresAt"), let day = result.expiresOn.flatMap(DocumentFacts.date) { edited.expiresAt = day }
        // Date edits weren't tracked before 1.5, so an automatic suggestion only replaces a date
        // that is still the import default (the import day). Accepting explicitly may replace any.
        if !protected.contains("documentDate"), let day = result.issuedOn.flatMap(DocumentFacts.date),
           explicit || Calendar.current.isDate(document.documentDate, inSameDayAs: document.importedAt) { edited.documentDate = day }
        guard explicit || (trustworthyText && result.confidence >= filingThreshold) else {
            if !protected.contains("review") { edited.needsReview = true }
            return edited
        }
        if !protected.contains("title") && !result.title.isEmpty { edited.title = result.title }
        if !protected.contains("summary") && !result.summary.isEmpty { edited.summary = result.summary }
        if !protected.contains("correspondent") && !result.correspondent.isEmpty { edited.correspondent = result.correspondent }
        if !protected.contains("collections") && !result.collection.isEmpty { edited.collections.insert(result.collection) }
        if !protected.contains("tags") && !result.tags.isEmpty { edited.tags = result.tags.joined(separator: ", ") }
        if !protected.contains("documentType") && !result.documentType.isEmpty { edited.documentType = result.documentType }
        if !protected.contains("entities"), let named = result.entities {
            var list = edited.entityList
            for name in named where !list.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { list.append(name) }
            edited.entities = list.joined(separator: ", ")
        }
        if !protected.contains("review") { edited.needsReview = explicit ? false : result.confidence < filingThreshold }

        return edited
    }
}
