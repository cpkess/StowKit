import Foundation
import EventKit

/// Adds a reminder for a document's due or expiry date, only when the owner asks (the product
/// brief: suggest, never create on its own). The wording is pure so it can be tested; EventKit is
/// touched only on an explicit click, which is also when macOS asks for Reminders access.
struct ReminderDraft: Equatable, Sendable {
    let title: String
    let notes: String
    let due: DateComponents

    enum Kind: String, Codable, Sendable { case due, expires }

    static func make(for document: HouseholdDocument, kind: Kind, calendar: Calendar = .current) -> ReminderDraft? {
        guard let date = kind == .due ? document.dueDate : document.expiresAt else { return nil }
        let name = document.title.isEmpty ? document.originalFilename : document.title
        let title = kind == .due ? "Due: \(name)" : "Renew or replace: \(name)"
        var notes = "From StowKit"
        if !document.correspondent.isEmpty { notes += " · \(document.correspondent)" }
        if !document.amount.isEmpty { notes += " · \(document.amount)" }
        var due = calendar.dateComponents([.year, .month, .day], from: date)
        due.hour = 9
        return ReminderDraft(title: title, notes: notes, due: due)
    }
}

enum ReminderService {
    enum Failure: LocalizedError {
        case denied, noList
        var errorDescription: String? {
            switch self {
            case .denied: "StowKit doesn’t have access to Reminders. Allow it in System Settings → Privacy & Security → Reminders."
            case .noList: "Reminders has no default list to add to."
            }
        }
    }
    /// Returns the new reminder's identifier.
    static func add(_ draft: ReminderDraft) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw Failure.denied }
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noList }
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = list
        reminder.dueDateComponents = draft.due
        if let date = Calendar.current.date(from: draft.due) { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }
}
