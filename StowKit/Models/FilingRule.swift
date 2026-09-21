import Foundation

/// An owner-written rule, like paperless-ngx's matching: when a document's text matches, file it.
/// Rules are deterministic, so unlike Apple Intelligence they give the same answer every time, and
/// they win over its suggestions for the fields they set. Manually edited fields still win over both.
struct FilingRule: Codable, Identifiable, Equatable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable {
        case anything, title, sender, filename, text
        var label: String {
            switch self {
            case .anything: "Any of these"
            case .title: "Title"
            case .sender: "Sender"
            case .filename: "File name"
            case .text: "Document text"
            }
        }
    }
    enum Algorithm: String, Codable, CaseIterable, Sendable {
        case anyWord, allWords, phrase, pattern
        var label: String {
            switch self {
            case .anyWord: "contains any of the words"
            case .allWords: "contains all of the words"
            case .phrase: "contains the phrase"
            case .pattern: "matches the regular expression"
            }
        }
    }
    var id = UUID()
    var name = ""
    var enabled = true
    var field = Field.anything
    var algorithm = Algorithm.anyWord
    var terms = ""
    var collection = ""
    var tags = ""
    var sender = ""
    var markReviewed = true

    var hasAction: Bool { !collection.isEmpty || !tagList.isEmpty || !sender.isEmpty || markReviewed }
    var tagList: [String] { FilingRules.split(tags) }
}

/// What a rule is matched against. Text is capped so a regular expression can't run away on a
/// very long document.
struct FilingRuleInput: Sendable {
    static let textLimit = 100_000
    var title: String
    var sender: String
    var filename: String
    var text: String
}

enum FilingRules {
    static func matches(_ rule: FilingRule, _ input: FilingRuleInput) -> Bool {
        guard rule.enabled else { return false }
        let terms = rule.terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return false }
        let haystacks: [String] = switch rule.field {
        case .anything: [input.title, input.sender, input.filename, input.text]
        case .title: [input.title]
        case .sender: [input.sender]
        case .filename: [input.filename]
        case .text: [input.text]
        }
        let text = haystacks.map { String($0.prefix(FilingRuleInput.textLimit)) }.joined(separator: "\n")
        switch rule.algorithm {
        case .anyWord, .allWords:
            let present = Set(words(text))
            let wanted = words(terms)
            return rule.algorithm == .anyWord ? wanted.contains(where: present.contains) : wanted.allSatisfy(present.contains)
        case .phrase:
            return normalized(text).contains(normalized(terms))
        case .pattern:
            guard let regex = try? NSRegularExpression(pattern: terms, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// Applies every matching rule, in order, to the fields the owner hasn't protected.
    /// `before` is the document as it was before this round of suggestions, so a rule's collection
    /// replaces the one Apple Intelligence chose rather than filing the document twice.
    static func apply(_ rules: [FilingRule], to document: HouseholdDocument, before: HouseholdDocument,
                      input: FilingRuleInput, protected: Set<String>, collections: Set<String>) -> (HouseholdDocument, [String]) {
        var edited = document
        var applied: [String] = []
        var ruleCollections: Set<String> = []
        for rule in rules where rule.hasAction && matches(rule, input) {
            applied.append(rule.name.isEmpty ? rule.terms : rule.name)
            if !rule.collection.isEmpty, collections.contains(rule.collection) { ruleCollections.insert(rule.collection) }
            if !protected.contains("tags"), !rule.tagList.isEmpty {
                var tags = split(edited.tags)
                for tag in rule.tagList where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
                edited.tags = tags.joined(separator: ", ")
            }
            if !protected.contains("correspondent"), !rule.sender.isEmpty { edited.correspondent = rule.sender }
            if !protected.contains("review"), rule.markReviewed { edited.needsReview = false }
        }
        if !protected.contains("collections"), !ruleCollections.isEmpty { edited.collections = before.collections.union(ruleCollections) }
        return (edited, applied)
    }

    static func split(_ list: String) -> [String] {
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private static func normalized(_ text: String) -> String {
        TextNormalization.searchKey(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func words(_ text: String) -> [String] {
        TextNormalization.searchKey(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
