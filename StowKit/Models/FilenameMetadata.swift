import Foundation

/// What a filename can honestly say: a readable title, and the document's own date when it is
/// written year-first. Scanner and export names embed timestamps that make poor titles, e.g.
/// `NovoCare_Patient_Authorization_FORM_2026-09-17T00_18_36Z`.
struct FilenameMetadata: Equatable {
    let title: String
    let date: Date?

    // Year-first only: 03-04-2026 is ambiguous between US and European order, so it is left alone.
    private static let datePattern = try! NSRegularExpression(pattern:
        #"(?<!\d)((?:19|20)\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?:[T_ -]?[0-2]\d[-_.:]?[0-5]\d(?:[-_.:]?[0-5]\d)?Z?)?(?!\d)"#)

    init(filename: String, calendar: Calendar = .current, now: Date = Date()) {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let source = stem as NSString
        var found: Date?
        var remainder = stem
        for match in Self.datePattern.matches(in: stem, range: NSRange(location: 0, length: source.length)).reversed() {
            let parts = (1...3).compactMap { Int(source.substring(with: match.range(at: $0))) }
            if parts.count == 3, let date = Self.date(year: parts[0], month: parts[1], day: parts[2], calendar: calendar, now: now) {
                found = date   // reversed, so the earliest date in the name wins
            }
            remainder = (remainder as NSString).replacingCharacters(in: match.range, with: " ")
        }
        let readable = remainder.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        let fallback = stem.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        title = readable.isEmpty ? (fallback.isEmpty ? stem : fallback) : readable
        date = found
    }

    private static func date(year: Int, month: Int, day: Int, calendar: Calendar, now: Date) -> Date? {
        guard year <= calendar.component(.year, from: now) + 1,
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day else { return nil }   // rejects 2026-02-30
        return date
    }
}
