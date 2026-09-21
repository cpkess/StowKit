import SwiftUI

struct FilingRulesView: View {
    @Bindable var library: LibraryStore
    @State private var editing: FilingRule?
    @State private var selection: FilingRule.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rules file documents automatically once their text is read. They run after Apple Intelligence and win over its suggestions, but never change a field you edited yourself.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(library.filingRules) { rule in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { enabled in
                            var changed = rule; changed.enabled = enabled; library.saveRule(changed)
                        })).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? "Untitled Rule" : rule.name).font(.headline)
                            Text(Self.summary(rule)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2).tag(rule.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = rule }
                    .contextMenu {
                        Button("Edit…") { editing = rule }
                        Button("Delete", role: .destructive) { library.deleteRule(rule.id) }
                    }
                }
                .onMove { library.moveRules(from: $0, to: $1) }
            }
            .frame(minHeight: 220)
            .overlay {
                if library.filingRules.isEmpty {
                    ContentUnavailableView("No Rules", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Add a rule such as “sender contains NovoCare → Medical”."))
                }
            }
            HStack {
                Button { editing = FilingRule() } label: { Image(systemName: "plus") }.help("Add Rule")
                Button { if let id = selection { library.deleteRule(id) } } label: { Image(systemName: "minus") }
                    .help("Delete Rule").disabled(selection == nil)
                Button("Edit…") { editing = library.filingRules.first { $0.id == selection } }.disabled(selection == nil)
                Spacer()
                Button("Apply to Existing Documents") { library.applyRulesToAll() }
                    .disabled(library.filingRules.allSatisfy { !$0.enabled } || !library.isReady)
            }
            if !library.rulesMessage.isEmpty { Text(library.rulesMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(20)
        .sheet(item: $editing) { rule in
            FilingRuleEditor(rule: rule, collections: library.collections.map(\.name)) { library.saveRule($0) }
        }
    }

    static func summary(_ rule: FilingRule) -> String {
        var actions: [String] = []
        if !rule.collection.isEmpty { actions.append("file in \(rule.collection)") }
        if !rule.tagList.isEmpty { actions.append("tag \(rule.tagList.joined(separator: ", "))") }
        if !rule.sender.isEmpty { actions.append("sender \(rule.sender)") }
        if rule.markReviewed { actions.append("mark reviewed") }
        let condition = "\(rule.field.label) \(rule.algorithm.label) “\(rule.terms)”"
        return actions.isEmpty ? condition : "\(condition) → \(actions.joined(separator: ", "))"
    }
}

private struct FilingRuleEditor: View {
    @State var rule: FilingRule
    let collections: [String]
    let save: (FilingRule) -> Void
    @Environment(\.dismiss) private var dismiss

    private var patternError: String? {
        guard rule.algorithm == .pattern, !rule.terms.isEmpty else { return nil }
        return (try? NSRegularExpression(pattern: rule.terms)) == nil ? "This isn’t a valid regular expression." : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(rule.name.isEmpty ? "New Rule" : rule.name).font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $rule.name, prompt: Text("NovoCare forms"))
                Section("When") {
                    Picker("Look in", selection: $rule.field) {
                        ForEach(FilingRule.Field.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Match", selection: $rule.algorithm) {
                        ForEach(FilingRule.Algorithm.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Words", text: $rule.terms, prompt: Text(rule.algorithm == .pattern ? "invoice\\s+#\\d+" : "novocare novo nordisk"))
                    if let patternError { Text(patternError).font(.caption).foregroundStyle(.orange) }
                    Text("Matching ignores case and accents. Words match whole words only.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Then") {
                    Picker("Add to collection", selection: $rule.collection) {
                        Text("None").tag("")
                        ForEach(collections, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Add tags", text: $rule.tags, prompt: Text("insurance, medical"))
                    TextField("Set sender", text: $rule.sender, prompt: Text("Novo Nordisk"))
                    Toggle("Mark reviewed, so it leaves Inbox", isOn: $rule.markReviewed)
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(rule); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(rule.terms.trimmingCharacters(in: .whitespaces).isEmpty || !rule.hasAction || patternError != nil)
            }
        }.padding(20).frame(width: 520, height: 560)
    }
}
