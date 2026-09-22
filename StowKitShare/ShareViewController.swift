import AppKit
import UniformTypeIdentifiers

/// "Share → StowKit": copies shared PDFs and images into the shared inbox, and saves a shared web
/// page as a PDF. StowKit imports them into Inbox, now if it's running or on its next launch.
final class ShareViewController: NSViewController {
    private let label = NSTextField(wrappingLabelWithString: "Adding to StowKit…")
    private let spinner = NSProgressIndicator()
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private static let archivable: [UTType] = [.pdf, .jpeg, .png, .heic]

    override func loadView() {
        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        done.target = self; done.action = #selector(close); done.isHidden = true; done.keyEquivalent = "\r"
        let row = NSStackView(views: [spinner, label]); row.spacing = 8
        let stack = NSStackView(views: [row, done]); stack.orientation = .vertical; stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        view = stack
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        Task { @MainActor in await share() }
    }

    @MainActor private func share() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var added: [String] = [], skipped = 0, failure: String?
        for provider in providers {
            do {
                if let name = try await addFile(provider) { added.append(name) }
                else if let name = try await addWebPage(provider) { added.append(name) }
                else { skipped += 1 }
            } catch { failure = error.localizedDescription }
        }
        if !added.isEmpty { ShareDropbox.notifyApp() }
        if failure == nil && skipped == 0 && !added.isEmpty {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        spinner.stopAnimation(nil); spinner.isHidden = true; done.isHidden = false
        var lines: [String] = []
        if !added.isEmpty { lines.append("Added \(added.count == 1 ? "“\(added[0])”" : "\(added.count) items") to StowKit’s Inbox.") }
        if skipped > 0 { lines.append("StowKit keeps PDFs, images (JPEG, PNG, HEIC), and web pages; \(skipped == 1 ? "one item was" : "\(skipped) items were") something else.") }
        if let failure { lines.append("Something couldn’t be added: \(failure)") }
        label.stringValue = lines.joined(separator: "\n")
    }

    /// A shared file (from Finder, Preview, Mail…). File URLs are checked before plain URLs,
    /// because a file URL is also a URL.
    @MainActor private func addFile(_ provider: NSItemProvider) async throws -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url, let type = UTType(filenameExtension: url.pathExtension),
                  Self.archivable.contains(where: type.conforms(to:)) else { return nil }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            _ = try ShareDropbox.place({ try FileManager.default.copyItem(at: url, to: $0) }, named: url.lastPathComponent)
            return url.deletingPathExtension().lastPathComponent
        }
        for type in Self.archivable where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let name = (provider.suggestedName ?? "Shared Document") + "." + (type.preferredFilenameExtension ?? "pdf")
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
            _ = try ShareDropbox.place({ try data.write(to: $0) }, named: name)
            return provider.suggestedName ?? "Shared Document"
        }
        return nil
    }

    /// A shared web address (from Safari and others): saved as a paginated PDF of the page.
    @MainActor private func addWebPage(_ provider: NSItemProvider) async throws -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        label.stringValue = "Saving \(url.host() ?? "the page") as a PDF…"
        let page = try await WebPagePDF().render(url)
        let title = ShareDropbox.filename(fromTitle: page.title)
        _ = try ShareDropbox.place({ try page.data.write(to: $0) }, named: title + ".pdf")
        return title
    }

    @objc private func close() { extensionContext?.completeRequest(returningItems: nil) }
}
