import SwiftUI

struct UnderstandingInspector: View {
    let snapshot: AnalysisSnapshot?
    let isTrashed: Bool
    let retry: () -> Void
    let apply: () -> Void
    @State private var showSuggestions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if snapshot?.state == "analyzing" { ProgressView().controlSize(.small) }
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                if snapshot?.result != nil { Button("Review Suggestions") { showSuggestions = true } }
                if ["complete", "failed", "remote"].contains(snapshot?.state) {
                    Button("Suggest Again", action: retry).disabled(isTrashed)
                }
            }
            if let result = snapshot?.result {
                Text("\(Self.source(result.provider)) · \(Self.certainty(result.confidence))")
                    .font(.caption).foregroundStyle(.secondary)
                if !result.note.isEmpty { Text(result.note).font(.caption).foregroundStyle(.secondary) }
                if let rules = result.rules, !rules.isEmpty {
                    Label("Filed by \(rules.count == 1 ? "rule" : "rules") \(rules.map { "“\($0)”" }.joined(separator: ", "))", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = snapshot?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.sheet(isPresented: $showSuggestions) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Suggested Details").font(.title2.weight(.semibold))
                if let result = snapshot?.result {
                    LabeledContent("Title", value: result.title.isEmpty ? "No suggestion" : result.title)
                    LabeledContent("Collection", value: result.collection.isEmpty ? "No suggestion" : result.collection)
                    LabeledContent("From", value: result.correspondent.isEmpty ? "No suggestion" : result.correspondent)
                    LabeledContent("Tags", value: result.tags.isEmpty ? "No suggestion" : result.tags.joined(separator: ", "))
                    LabeledContent("Type", value: result.documentType.isEmpty ? "No suggestion" : result.documentType)
                    LabeledContent("Date", value: result.issuedOn ?? "No suggestion")
                    LabeledContent("Amount", value: result.amount ?? "No suggestion")
                    if let due = result.dueOn { LabeledContent("Due", value: due) }
                    if let expires = result.expiresOn { LabeledContent("Expires", value: expires) }
                    Text(result.summary).textSelection(.enabled)
                    if !result.evidence.isEmpty { Text("Based on: “\(result.evidence)”").font(.caption).textSelection(.enabled) }
                    Text("Using these fills in each suggested field, adds the collection, and marks the document reviewed. It replaces the title, summary, sender, tags, type, date, and amount, including any you typed.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { showSuggestions = false }
                        Spacer()
                        Button("Use Suggestions") { apply(); showSuggestions = false }.disabled(isTrashed || result.title.isEmpty)
                    }
                }
            }.padding(24).frame(width: 520)
        }
    }

    /// Provider names are stored identifiers ("Apple on-device model", "Local rules"); these are
    /// only how they read to the owner.
    static func source(_ provider: String) -> String {
        provider == "Apple on-device model" ? "Suggested by Apple Intelligence" : "Suggested by StowKit's built-in rules"
    }
    static func certainty(_ confidence: Double) -> String {
        confidence >= UnderstandingPolicy.automaticThreshold ? "Confident"
            : confidence >= UnderstandingPolicy.filingThreshold ? "Fairly sure" : "Not sure — please check"
    }
    private var label: String {
        switch snapshot?.state {
        case "analyzing": "Reading the document for suggestions…"
        case "complete": "Suggestions"
        case "failed": "Couldn't make suggestions"
        case "paused": "Suggestions paused in Trash"
        case "queued": "Waiting to make suggestions"
        case "remote": "Details came from iCloud"
        default: "Suggestions come after the text is read"
        }
    }
}
