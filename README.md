# StowKit

A native, local-first macOS household document archive. The local archive — importing, text reading, suggestions, search, and filing — is complete. Opt-in iCloud sync for your own Macs passed live tests. **Household sharing between different iCloud accounts is experimental and has not been tested with two accounts.** The default build is local only.

## Run

Open `StowKit.xcodeproj` in Xcode 27 on macOS 27 (or a compatible Xcode 26 installation on earlier macOS), select **StowKit → My Mac**, and Run (⌘R). Minimum deployment target: macOS 14.0. No packages, account, server, or provisioning team are required for local development; the project uses ad-hoc signing.

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived build
```

## Use

1. Import PDF, JPEG, PNG, or HEIC files with **⌘N**, the toolbar, or drag/drop from Finder. Multiple files are processed sequentially in the background.
2. Imports appear in **Inbox** and StowKit reads their text in the background, using the PDF's own text where it exists and Apple Vision for scanned pages and images. The details pane shows progress, **View Text**, and **Retry** when needed. Titles start as a cleaned-up filename (underscores and embedded timestamps removed), and the date comes from a year-first date in the filename, such as `2026-09-17` or `20260917`, falling back to the import date. Once the text is read, StowKit suggests a title, type, collection, sender, tags, and summary.
3. Confident suggestions are filed automatically; fairly sure ones are filed and marked **Filed automatically** in the list; uncertain ones stay in Inbox marked **Needs review**. **Review Suggestions** shows what was suggested and why. Choose **Mark Reviewed** when a document is organized. A document whose text can't be read is never removed; you can still preview and edit it, and it stays in Inbox until the text problem is resolved.
4. Edit the title, date, sender, collections (**Add to Collection**), tags, and summary at the top of the details pane; people and things, file details, text, and storage are under **More Details**. Changes and custom collections are saved immediately.
5. Use **⌘K** to search the whole active library or **⌘F** to filter the current view. Search ranks titles, senders, metadata, and document text together, including words found on different pages. Type word prefixes such as `refrig warranty`, or use quotes for an exact phrase such as `"renewal date"`. Matches ignore case and accents and appear in highlighted snippets. Results load 50 at a time; use **Load More** to continue. Search results use relevance order; the Sort menu controls browsing without a query.
6. Use **Quick Look**, the inline PDF/image preview, or **⌘O** to open an editable copy in another app. The archived original remains unchanged. Multipage PDFs have page navigation; password-protected PDFs can be archived and opened as copies for unlocking. The inline preview is a rendered image, so to copy text use **View Text** or open a copy.
7. **Move to Trash** from the toolbar, context menu, or Delete key while the document list has focus. Restore from StowKit's **Trash**. In Trash, **Delete Permanently…** and **Empty Trash…** remove documents for good: from this Mac, and, when the archive is in iCloud, from iCloud and every Mac that uses it. Both ask first and cannot be undone.
8. StowKit keeps **one archive**, in your iCloud account, with copies on this Mac. On launch it reconnects to that archive, or creates it; an archive that already holds documents asks before its first upload, and **Pause iCloud** in Settings is remembered. The sidebar's bottom-left button shows sync status. Documents behave like iCloud Drive files: a cloud badge marks ones not on this Mac, **Download Now** fetches them, and **Remove Download** frees the local copy while keeping it in iCloud. Without an iCloud-signed build, the archive stays on this Mac.
9. **Inbox folder** (Settings): choose a folder, ideally in iCloud Drive, and StowKit imports every PDF or image added to it, then moves the file to the Trash. On an iPhone, scan or save into that folder from the Files app; any Mac running StowKit takes it in.
10. **Filing rules** (Settings → Rules): for example, "any text contains the words *novocare* → add to Medical, tag *insurance*, mark reviewed". Rules run once a document's text is read, after Apple Intelligence, and win over its suggestions, but never change a field you edited yourself. **Apply to Existing Documents** runs them over your archive. Rules are kept on each Mac and don't sync yet.

Exact duplicates are detected across the entire archive, including Trash. The import report links to existing documents and identifies individual failures without stopping the remaining batch. A renamed duplicate does not overwrite edited metadata.

## Processing and recovery

Text is saved one page at a time with its processing checkpoint. If StowKit quits during extraction, it resumes after the last saved page on the next launch. **Retry** keeps completed pages; **Read Text Again** in the text menu discards the saved text and starts over without touching the original. Moving a document to Trash pauses unfinished extraction; Restore resumes it.

Existing Milestone 2 archives migrate automatically and receive processing jobs. The original document schema and original files are preserved. Password-protected PDFs remain archived but require an unlocked copy to be imported before OCR can run. Blank documents complete with “No text found.” OCR can make mistakes, so the original remains the source of truth.

The search index updates incrementally after imports, edits, and processing. Existing archives build their index from saved metadata and page text in the background; originals are not re-read. **Settings → Rebuild Search Index** regenerates the cache without resetting OCR or changing documents. If an index write fails, ordinary library browsing remains available and search shows an error.

## Document understanding

On macOS 26 or later, StowKit uses Apple Intelligence's on-device model when it is available. Apple's default safety filter refuses many ordinary household records — any medical form, for example — so when it declines a document, StowKit asks again with Apple's permissive setting for transforming your own text, and validates the answer the same way. On older systems, unsupported Macs, or other model errors, built-in rules recognize a small set of household document types. The details pane says which one made each suggestion. Apple Intelligence is never required for importing, reading text, search, or manual organization.

Suggestions cannot automatically replace fields you have edited, including fields you cleared. Archives from previous versions receive suggestions without automatic metadata changes. **Use Suggestions** explicitly accepts the displayed proposal; **Suggest Again** retries against the saved text. It does not re-read the document or alter originals. Analysis resumes after interruption, pauses in Trash, and discards stale results if extraction is reset.

Filing confidence is a conservative heuristic, not a calibrated probability. Conflicting/unknown types and long documents analyzed only as excerpts remain in Inbox. The first implementation uses at most 4,000 UTF-8 bytes from the first eight pages; it does not claim whole-document understanding for longer records. Dates are read only from year-first filenames, not from document text; amounts, entities, reminders, and related-document links remain manual or future work.

## Storage and privacy

The sandboxed app keeps its archive under its Application Support directory:

```text
~/Library/Containers/com.stowkit.app/Data/Library/Application Support/StowKit/
    Library.store          Metadata, page text, jobs, and analysis (plus SQLite sidecars)
    Originals/AB/UUID.pdf   Immutable, opaque-ID original files
    Staging/UUID/          Interrupted-import recovery receipts and copies
    Thumbnails/UUID.png    Regenerable local thumbnails
    Search/Search.sqlite  Rebuildable full-text index (plus SQLite sidecars)
```

Settings displays the actual location. A non-sandboxed development runner may use a different Application Support location. Originals never use collection names as folder paths. Imports use security-scoped file access, coordinated reads, streaming SHA-256, and atomic staging/promotion. Originals are stored with read-only permissions. Opening a copy creates a separate file in the app's temporary directory; edits to it are not automatically reimported.

**The default build is a local archive, not a cloud backup.** A provisioned build can opt into iCloud in Settings; see the [iCloud setup and acceptance guide](docs/ICLOUD_SETUP.md). PDF parsing, Vision OCR, document understanding, and classification run locally, with no external AI service. Back up the complete archive directory while the app is closed, including database sidecars and originals. No telemetry or external AI is included. Opting into iCloud uploads originals, metadata, and extracted text through CloudKit.

The first launch starts empty; the old fictional sample library is no longer loaded. Importing does not move or modify source files.

## Tests

Run **Product → Test (⌘U)** in Xcode or:

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived -destination 'platform=macOS' test
```

The XCTest target creates isolated temporary archives and generated fixtures. The tests cover archive integrity, migrations through V8, real PDF/Vision OCR, checkpoint recovery, search ranking and snippets, metadata updates, pagination, journal replay, and cache failure/rebuilding. Sync tests cover coalesced change receipts, stale acknowledgments, fake-transport retry, resumable backfill, atomic incoming pages, persisted conflict resolution, remote document creation, searchable text without original downloads, duplicate imports, read-only access, corrupt downloads, and expired change tokens. A standalone synthetic 50,000-document index benchmark is included; see validation for results and limits.

See [architecture and implementation notes](docs/ARCHITECTURE.md), the [iCloud architecture](docs/ICLOUD_ARCHITECTURE.md), the [optimized storage architecture](docs/STORAGE_ARCHITECTURE.md), [setup and live acceptance steps](docs/ICLOUD_SETUP.md), and [validation](docs/VALIDATION.md). Fake transport tests do not establish live CloudKit behavior. The Production schema is deployed and the isolated private-cloud smoke test passes. Two-account household acceptance, automatic local-file eviction, and cloud thumbnails remain unfinished. Optimized storage is designed but not implemented; originals are never evicted today.

## Releases

[v1.3.0](https://github.com/cpkess/StowKit/releases/tag/v1.3.0) is a Gamergrams Developer ID signed and Apple-notarized DMG for macOS 14 or later, with Apple Silicon and Intel binaries, using Production CloudKit. It is the first version that updates itself (Sparkle, from these GitHub releases). Read the [release notes](docs/releases/v1.3.0.md) first: it has been tested on one Mac only, the updater has not yet installed an update end to end, and household sharing is experimental and untested across accounts. Earlier releases: [v1.2.0](docs/releases/v1.2.0.md), [v1.1.0](docs/releases/v1.1.0.md), [v1.0.0](docs/releases/v1.0.0.md), [v0.6.0-alpha.2](docs/releases/v0.6.0-alpha.2.md), and a device-restricted alpha.1.

To package an already signed build without changing its signature:

```sh
scripts/package-dmg.sh /path/to/StowKit.app 1.3.0 build/releases
```

The script creates a compressed DMG with an Applications link and a SHA-256 sidecar, and verifies the image. It does not perform signing, notarization, or CloudKit Production deployment.

For Developer ID signing, Production configuration, and notarization, see the [distribution workflow](docs/DISTRIBUTION.md).
