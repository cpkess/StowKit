import Foundation
import SwiftData

/// Filing rules are kept per Mac, as JSON in a checkpoint row, so they need no schema change.
/// They don't sync: an unknown record type would stall sync on a Mac running 1.2.0 or earlier.
extension ArchiveRepository {
    private static let rulesKey = "filing-rules-v1"

    func filingRules() throws -> [FilingRule] { try storedJSON(Self.rulesKey) ?? [] }
    func saveFilingRules(_ rules: [FilingRule]) throws { try storeJSON(rules, Self.rulesKey) }
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
    func savedViews() throws -> [SavedView] { try storedJSON(Self.savedViewsKey) ?? [] }
    func saveSavedViews(_ views: [SavedView]) throws { try storeJSON(views, Self.savedViewsKey) }

    // MARK: Entity kinds, stored the same way (lowercased name → kind)

    private static let entityKindsKey = "entity-kinds-v1"
    func entityKinds() throws -> [String: EntityKind] { try storedJSON(Self.entityKindsKey) ?? [:] }
    func saveEntityKinds(_ kinds: [String: EntityKind]) throws { try storeJSON(kinds, Self.entityKindsKey) }

    // MARK: Reminders already added from this Mac ("<document id>:<due|expires>" → reminder id)

    private static let remindersKey = "reminders-v1"
    func addedReminders() throws -> [String: String] { try storedJSON(Self.remindersKey) ?? [:] }
    func saveAddedReminders(_ reminders: [String: String]) throws { try storeJSON(reminders, Self.remindersKey) }

    /// Per-Mac settings kept as JSON in a checkpoint row: no schema change, not synced.
    private func storedJSON<T: Decodable>(_ key: String) throws -> T? {
        guard let row = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first,
              let data = row.value.data(using: .utf8), !data.isEmpty else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func storeJSON<T: Encodable>(_ value: T, _ key: String) throws {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        do {
            if let row = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first { row.value = text }
            else { context.insert(Checkpoint(key, value: text)) }
            try save()
        } catch { context.rollback(); throw error }
    }

    // MARK: Tags across the archive

    /// Renames a tag on every document outside Trash ("" removes it), matching without case. It is
    /// the owner's edit, so it goes through `update`: protected from suggestions and synced.
    @discardableResult
    func renameTag(_ old: String, to new: String) throws -> Int {
        try renameListItem(old, to: new, in: \.tagList) { $0.tags = $1 }
    }
    /// The same for a person or thing in "People & things".
    @discardableResult
    func renameEntity(_ old: String, to new: String) throws -> Int {
        try renameListItem(old, to: new, in: \.entityList) { $0.entities = $1 }
    }
    private func renameListItem(_ old: String, to new: String, in list: KeyPath<HouseholdDocument, [String]>,
                                write: (inout HouseholdDocument, String) -> Void) throws -> Int {
        let key = old.trimmingCharacters(in: .whitespaces).lowercased()
        let replacement = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ";", with: " ")
        guard !key.isEmpty else { return 0 }
        var changed = 0
        for record in try context.fetch(FetchDescriptor<Record>()) {
            var document = record.document
            guard document.trashedAt == nil, document[keyPath: list].contains(where: { $0.lowercased() == key }) else { continue }
            var items: [String] = []
            for item in document[keyPath: list] {
                let value = item.lowercased() == key ? replacement : item
                if !value.isEmpty, !items.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { items.append(value) }
            }
            write(&document, items.joined(separator: ", "))
            document.modifiedAt = Date()
            try update(document)
            changed += 1
        }
        return changed
    }
}
