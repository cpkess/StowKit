import Foundation
import SwiftData

/// Filing rules are kept per Mac, as JSON in a checkpoint row, so they need no schema change.
/// They don't sync: an unknown record type would stall sync on a Mac running 1.2.0 or earlier.
extension ArchiveRepository {
    private static let rulesKey = "filing-rules-v1"

    func filingRules() throws -> [FilingRule] {
        let key = Self.rulesKey
        guard let row = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first,
              let data = row.value.data(using: .utf8), !data.isEmpty else { return [] }
        return try JSONDecoder().decode([FilingRule].self, from: data)
    }
    func saveFilingRules(_ rules: [FilingRule]) throws {
        let key = Self.rulesKey
        let value = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        do {
            if let row = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first { row.value = value }
            else { context.insert(Checkpoint(key, value: value)) }
            try save()
        } catch { context.rollback(); throw error }
    }
    func filingRuleInput(_ document: HouseholdDocument) throws -> FilingRuleInput {
        let id = document.id
        var text = ""
        let pages = FetchDescriptor<Page>(predicate: #Predicate { $0.documentID == id }, sortBy: [SortDescriptor(\.pageIndex)])
        for page in try context.fetch(pages) {
            text += page.text + "\n"
            if text.count >= FilingRuleInput.textLimit { break }
        }
        return FilingRuleInput(title: document.title, sender: document.correspondent, filename: document.originalFilename, text: text)
    }
    /// Called inside suggestion and bulk transactions; saving is the caller's job.
    func applyFilingRules(to document: HouseholdDocument, before: HouseholdDocument, protected: Set<String>) throws -> (HouseholdDocument, [String]) {
        let rules = try filingRules()
        guard !rules.isEmpty else { return (document, []) }
        return FilingRules.apply(rules, to: document, before: before, input: try filingRuleInput(document),
                                 protected: protected, collections: Set(try collections().map(\.name)))
    }
    /// Runs the rules over every document not in Trash. Only unprotected fields change, and a
    /// collection is only ever added here, never taken away.
    @discardableResult
    func applyFilingRulesToAll() throws -> Int {
        var changed = 0
        do {
            for record in try context.fetch(FetchDescriptor<Record>()) {
                let document = record.document
                guard document.trashedAt == nil else { continue }
                let protected = Set(try analysis(document.id)?.protectedFields ?? UnderstandingPolicy.fields)
                var (edited, applied) = try applyFilingRules(to: document, before: document, protected: protected)
                guard !applied.isEmpty, edited != document else { continue }
                edited.modifiedAt = Date()
                record.updateMetadata(from: edited)
                markSearchChanged(document.id)
                try journalDocument(edited)
                changed += 1
            }
            try save()
        } catch { context.rollback(); throw error }
        return changed
    }
}
