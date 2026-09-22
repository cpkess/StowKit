import Foundation

/// Dates and amounts a suggestion may use. The model proposes them; nothing is accepted unless the
/// document's own text supports it, the same principle as `evidenceSupported` for collections.
enum DocumentFacts {
    /// Every calendar day macOS's date detector finds in the text, as "yyyy-MM-dd".
    static func detectedDays(in text: String) -> Set<String> {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        var days = Set<String>()
        detector.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            if let date = match?.date { days.insert(dayString(date)) }
        }
        return days
    }
    /// A proposed "yyyy-MM-dd" is kept only if it is a real day the detector also found in the text.
    static func supportedDay(_ proposed: String?, among days: Set<String>) -> String? {
        guard let proposed = proposed?.trimmingCharacters(in: .whitespaces), date(proposed) != nil, days.contains(proposed) else { return nil }
        return proposed
    }
    /// An amount is kept only if it has digits and those digits, ignoring thousands separators,
    /// appear in the text: "$3,972.96" needs "3972.96" there.
    static func supportedAmount(_ proposed: String?, in text: String) -> String? {
        guard let proposed = proposed?.trimmingCharacters(in: .whitespaces), proposed.count <= 40 else { return nil }
        let figure = proposed.filter { $0.isNumber || $0 == "." }
        guard figure.contains(where: \.isNumber), figure.filter(\.isNumber).count >= 1 else { return nil }
        let haystack = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        return haystack.contains(figure) ? proposed : nil
    }
    /// For the built-in rules: a date that directly follows a label such as "Date:" or
    /// "Invoice date", the only place a date reliably is the document's own.
    static func labeledDay(in text: String) -> String? {
        let labels = #"(?i)\b(statement date|invoice date|issue date|date issued|bill date|date of service|date)\s*[:\-]?\s*"#
        guard let regex = try? NSRegularExpression(pattern: labels),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let source = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let start = match.range.location + match.range.length
            let window = NSRange(location: start, length: min(40, source.length - start))
            if let found = detector.firstMatch(in: text, range: window), found.range.location <= start + 2, let date = found.date {
                return dayString(date)
            }
        }
        return nil
    }
    /// A name is kept only if its words appear together, in order, in the text (case and accents
    /// ignored). Short names are allowed, unlike collection evidence, but nothing invented is.
    static func named(_ name: String, in text: String) -> Bool {
        func words(_ value: String) -> [String] { TextNormalization.searchKey(value).split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let wanted = words(name), source = words(text)
        guard !wanted.isEmpty, wanted.joined().count >= 2, source.count >= wanted.count else { return false }
        return (0...(source.count - wanted.count)).contains { source[$0..<($0 + wanted.count)].elementsEqual(wanted) }
    }
    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...2200).contains(parts[0]) else { return nil }
        var components = DateComponents(); components.year = parts[0]; components.month = parts[1]; components.day = parts[2]; components.hour = 12
        guard let date = Calendar.current.date(from: components), dayString(date) == day else { return nil }
        return date
    }
    static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
