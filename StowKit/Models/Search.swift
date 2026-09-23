import Foundation

struct SearchHit: Sendable {
    let document: HouseholdDocument
    let snippet: String
}
struct SearchPage: Sendable {
    var hits: [SearchHit]
    let total: Int
    let statistics: LibraryStatistics
}
struct LibraryStatistics: Equatable, Sendable {
    var documents = 0
    var inbox = 0
    var trash = 0
    var bytes: Int64 = 0
}

/// A name with how many documents carry it, for the home page's collections.
struct NamedCount: Identifiable, Equatable, Sendable {
    let name: String
    let count: Int
    var id: String { name }
}

/// What the home page shows at a glance. Every count comes from the same filters the sidebar and
/// filter bar use, so a number always matches the documents behind it.
struct HomeOverview: Equatable, Sendable {
    var statistics = LibraryStatistics()
    var overdue = 0
    var dueSoon = 0
    var expiringSoon = 0
    var unfiled = 0
    var collections: [NamedCount] = []
    /// Documents outside Trash: what the library shows.
    var active: Int { max(statistics.documents - statistics.trash, 0) }
    var needsAttention: Bool { statistics.inbox > 0 || overdue > 0 || dueSoon > 0 || expiringSoon > 0 || unfiled > 0 }
}

/// Treat all user input as literal words. Quoted groups are phrases; unquoted words are prefixes.
/// SQL and FTS operators are never accepted from user input.
enum SearchQuery {
    static func expression(_ input: String) -> String? {
        var clauses: [String] = []
        var phrase = false
        for part in input.components(separatedBy: "\"") {
            let words = part.components(separatedBy: CharacterSet.alphanumerics.union(.nonBaseCharacters).inverted).filter { !$0.isEmpty }
            if phrase, !words.isEmpty { clauses.append("\"" + words.joined(separator: " ") + "\"") }
            else { clauses += words.map { "\"" + $0 + "\"*" } }
            phrase.toggle()
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
    }
}
