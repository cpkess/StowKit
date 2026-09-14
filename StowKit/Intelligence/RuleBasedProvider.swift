import Foundation

struct RuleBasedProvider: DocumentIntelligenceProvider {
    private let rules: [(String, String, [String])] = [
        ("Property Tax Bill", "Taxes", ["property tax", "tax bill", "parcel number"]),
        ("Insurance Policy", "Insurance", ["insurance policy", "policy number", "coverage period"]),
        ("Product Warranty", "Warranties", ["limited warranty", "warranty period", "proof of purchase"]),
        ("School Tuition Statement", "Kids", ["tuition statement", "student name", "school year"]),
        ("Vehicle Registration", "Vehicles", ["vehicle registration", "vehicle identification number", "license plate"]),
        ("Purchase Receipt", "Receipts", ["sales receipt", "total paid", "payment method"]),
        ("Bank Statement", "Financial", ["account statement", "beginning balance", "ending balance"])
    ]
    func understand(_ input: UnderstandingInput) async throws -> DocumentUnderstanding {
        try Task.checkCancellation()
        let text = TextNormalization.searchKey(input.text)
        let matches = rules.compactMap { title, collection, cues -> (String, String, [String])? in
            let hits = cues.filter { text.contains($0) }
            return hits.isEmpty ? nil : (title, collection, hits)
        }.sorted { $0.2.count > $1.2.count }
        guard let best = matches.first else {
            return DocumentUnderstanding(note: "No reliable document type was recognized. Manual organization is available.")
        }
        let ambiguous = matches.dropFirst().contains { $0.2.count >= best.2.count }
        let score = ambiguous ? 0.4 : (best.2.count >= 2 ? 0.92 : 0.70)
        return UnderstandingPolicy.validated(DocumentUnderstanding(title: best.0, documentType: best.0,
            collection: best.1, tags: [best.0.lowercased().replacingOccurrences(of: " ", with: "-")],
            summary: "Recognized document: \(best.0.lowercased()).", evidence: best.2[0], confidence: score,
            note: ambiguous ? "More than one document type matched. Review the suggested collection." : "Matched \(best.2.count) document-type cue(s)."), input: input)
    }
}
