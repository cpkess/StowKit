import Foundation

/// Narrows the current view, alongside the sidebar destination and the search text. Every part
/// is optional; an empty filter changes nothing. Date bounds are computed when a query runs, so a
/// saved "this year" stays this year.
struct LibraryFilter: Codable, Equatable, Hashable, Sendable {
    enum Period: Codable, Hashable, Sendable {
        case last30Days, thisYear, lastYear, year(Int)
        var label: String {
            switch self {
            case .last30Days: "Last 30 days"
            case .thisYear: "This year"
            case .lastYear: "Last year"
            case .year(let year): String(year)
            }
        }
        func bounds(now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
            let year = calendar.component(.year, from: now)
            func start(_ y: Int) -> Date { calendar.date(from: DateComponents(year: y, month: 1, day: 1))! }
            switch self {
            case .last30Days: return (calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))!, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!)
            case .thisYear: return (start(year), start(year + 1))
            case .lastYear: return (start(year - 1), start(year))
            case .year(let y): return (start(y), start(y + 1))
            }
        }
    }
    enum Upcoming: String, Codable, Hashable, Sendable, CaseIterable {
        case overdue, dueSoon, expiringSoon
        var label: String {
            switch self {
            case .overdue: "Overdue"
            case .dueSoon: "Due in the next 30 days"
            case .expiringSoon: "Expiring in the next 90 days"
            }
        }
    }
    var tag: String?
    var sender: String?
    var type: String?
    var period: Period?
    var upcoming: Upcoming?
    var noCollection = false

    var isEmpty: Bool { self == LibraryFilter() }
    /// Human-readable parts, each with a way to remove it, for the filter bar.
    var parts: [(label: String, remove: (inout LibraryFilter) -> Void)] {
        var result: [(String, (inout LibraryFilter) -> Void)] = []
        if let tag { result.append(("Tag: \(tag)", { $0.tag = nil })) }
        if let sender { result.append(("From: \(sender)", { $0.sender = nil })) }
        if let type { result.append(("Type: \(type)", { $0.type = nil })) }
        if let period { result.append((period.label, { $0.period = nil })) }
        if let upcoming { result.append((upcoming.label, { $0.upcoming = nil })) }
        if noCollection { result.append(("Not in a collection", { $0.noCollection = false })) }
        return result
    }
}

/// A named search: destination, search text, and filter, kept per Mac like filing rules.
struct SavedView: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var destination: LibraryDestination
    var query: String
    var filter: LibraryFilter
}

/// The choices the filter menus offer, most used first.
struct LibraryFacets: Equatable, Sendable {
    var tags: [(name: String, count: Int)] = []
    var senders: [(name: String, count: Int)] = []
    var types: [(name: String, count: Int)] = []
    var years: [Int] = []
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tags.map(\.name) == rhs.tags.map(\.name) && lhs.tags.map(\.count) == rhs.tags.map(\.count)
            && lhs.senders.map(\.name) == rhs.senders.map(\.name) && lhs.types.map(\.name) == rhs.types.map(\.name) && lhs.years == rhs.years
    }
}

extension HouseholdDocument {
    /// Tags as a list, trimmed, without empties. Storage and sync keep the comma-separated text.
    var tagList: [String] { tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}
