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

    // MARK: Saved views, stored the same way

    private static let savedViewsKey = "saved-views-v1"
    func savedViews() throws -> [SavedView] {
        let key = Self.savedViewsKey
        guard let row = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first,
              let data = row.value.data(using: .utf8), !data.isEmpty else { return [] }
        return try JSONDecoder().decode([SavedView].self, from: data)
    }
    func saveSavedViews(_ views: [SavedView]) throws {
        let key = Self.savedViewsKey
        let value = String(decoding: try JSONEncoder().encode(views), as: UTF8.self)
        do {
            if let row = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first { row.value = value }
            else { context.insert(Checkpoint(key, value: value)) }
            try save()
        } catch { context.rollback(); throw error }
    }

    // MARK: Tags across the archive

    /// Renames a tag on every document outside Trash ("" removes it), matching without case. It is
    /// the owner's edit, so it goes through `update`: protected from suggestions and synced.
    @discardableResult
    func renameTag(_ old: String, to new: String) throws -> Int {
        let key = old.trimmingCharacters(in: .whitespaces).lowercased()
        let replacement = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: " ")
        guard !key.isEmpty else { return 0 }
        var changed = 0
        for record in try context.fetch(FetchDescriptor<Record>()) {
            var document = record.document
            guard document.trashedAt == nil, document.tagList.contains(where: { $0.lowercased() == key }) else { continue }
            var tags: [String] = []
            for tag in document.tagList {
                let value = tag.lowercased() == key ? replacement : tag
                if !value.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { tags.append(value) }
            }
            document.tags = tags.joined(separator: ", ")
            document.modifiedAt = Date()
            try update(document)
            changed += 1
        }
        return changed
    }
}
