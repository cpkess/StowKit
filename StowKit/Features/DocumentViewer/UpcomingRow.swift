import SwiftUI

struct ReminderActions {
    let has: (ReminderDraft.Kind) -> Bool
    let add: (ReminderDraft.Kind) -> Void
}

/// "Due Oct 8 · Add Reminder": a suggestion only; nothing is added until the owner clicks.
struct UpcomingRow: View {
    let document: HouseholdDocument
    let actions: ReminderActions
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let due = document.dueDate { row(.due, "Due", due) }
            if let expires = document.expiresAt { row(.expires, "Expires", expires) }
        }
    }
    private func row(_ kind: ReminderDraft.Kind, _ label: String, _ date: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").foregroundStyle(date < Calendar.current.startOfDay(for: Date()) ? .red : .orange)
            Text("\(label) \(date, format: .dateTime.month(.abbreviated).day().year())").font(.subheadline)
            if actions.has(kind) {
                Label("Reminder added", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Add Reminder") { actions.add(kind) }.buttonStyle(.link)
                    .help("Adds a reminder to Apple Reminders for 9 AM that day")
            }
        }
    }
}
