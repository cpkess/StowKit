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
struct LibraryStatistics: Sendable {
    var documents = 0
    var inbox = 0
    var trash = 0
    var bytes: Int64 = 0
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
