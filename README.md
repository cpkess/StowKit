# StowKit

A native, local-first macOS household document archive. **Local archive features and an opt-in CloudKit implementation are present.** Private iCloud passed a live smoke test; household sharing still requires two-account acceptance testing. The default build remains local.

## Run

Open `StowKit.xcodeproj` in Xcode 27 on macOS 27 (or a compatible Xcode 26 installation on earlier macOS), select **StowKit → My Mac**, and Run (⌘R). Minimum deployment target: macOS 14.0. No packages, account, server, or provisioning team are required for local development; the project uses ad-hoc signing.

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived build
```

## Use

1. Import PDF, JPEG, PNG, or HEIC files with **⌘N**, the toolbar, or drag/drop from Finder. Multiple files are processed sequentially in the background.
2. Imports appear in **Inbox** and automatically enter the background text-extraction queue. StowKit prefers usable PDF text and uses Apple Vision OCR for scanned pages and images. The inspector shows progress, **View Text**, and **Retry** when needed. Titles initially come from filenames and document dates initially use the import date. After OCR, a separate background stage suggests a title, document type, collection, correspondent, tags, and summary.
3. High-confidence documents are filed automatically. Medium-confidence documents are filed with a **Suggested filing** label in Recent; uncertain results remain in Inbox. Inspect **Suggestions** to review the evidence or apply suggestions yourself. Choose **Mark Reviewed** when organized. OCR failure never removes a document; you can still preview and edit it. Failed extraction is surfaced in Inbox even for an otherwise reviewed document.
4. Edit titles, summaries, correspondents, dates, tags, entities, Favorites, and collection membership in the inspector. Changes and custom collections persist immediately.
5. Use **⌘K** to search the whole active library or **⌘F** to filter the current view. Search ranks titles, correspondents, metadata, and extracted text together, including words found on different pages. Type word prefixes such as `refrig warranty`, or use quotes for an exact phrase such as `"renewal date"`. Matches ignore case and accents and appear in highlighted snippets. Results load 50 at a time; use **Load More** to continue. Search results use relevance order; the Sort menu controls browsing without a query.
6. Use **Quick Look**, the inline PDF/image preview, or **⌘O** to open an editable copy in another app. The archived original remains unchanged. Multipage PDFs have page navigation; password-protected PDFs can be archived and opened as copies for unlocking.
7. **Move to Trash** from the toolbar, context menu, or Delete key while the document list has focus. Restore from StowKit's **Trash**. Trash is retained indefinitely and still consumes disk space; this version has no permanent-delete action.

Exact duplicates are detected across the entire archive, including Trash. The import report links to existing documents and identifies individual failures without stopping the remaining batch. A renamed duplicate does not overwrite edited metadata.

## Processing and recovery

Text is saved one page at a time with its processing checkpoint. If StowKit quits during extraction, it resumes after the last saved page on the next launch. **Retry** keeps completed pages; **Extract Again** in the text-extraction menu discards derived text and starts over without touching the original. Moving a document to Trash pauses unfinished extraction; Restore resumes it.

Existing Milestone 2 archives migrate automatically and receive processing jobs. The original document schema and original files are preserved. Password-protected PDFs remain archived but require an unlocked copy to be imported before OCR can run. Blank documents complete with “No text found.” OCR can make mistakes, so the original remains the source of truth.

The search index updates incrementally after imports, edits, and processing. Existing archives build their index from saved metadata and page text in the background; originals are not re-read. **Settings → Rebuild Search Index** regenerates the cache without resetting OCR or changing documents. If an index write fails, ordinary library browsing remains available and search shows an error.

## Document understanding

On macOS 26 or later, StowKit uses Apple's on-device Foundation Models model when it is available. On older systems, unsupported Macs, or model errors, deterministic local rules recognize a small set of household document types. The inspector identifies the provider used. Apple Intelligence is never required for importing, OCR, search, or manual organization.

Suggestions cannot automatically replace fields you have edited, including fields you cleared. Archives from previous versions receive suggestions without automatic metadata changes. **Apply Suggestions** explicitly accepts the displayed proposal; **Analyze Again** retries against the saved extracted text. It does not rerun OCR or alter originals. Analysis resumes after interruption, pauses in Trash, and discards stale results if extraction is reset.

Filing confidence is a conservative heuristic, not a calibrated probability. Conflicting/unknown types and long documents analyzed only as excerpts remain in Inbox. The first implementation uses at most 4,000 UTF-8 bytes from the first eight pages; it does not claim whole-document understanding for longer records. Dates, amounts, entities, reminders, and related-document links remain manual or future work.

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

See [architecture and implementation notes](docs/ARCHITECTURE.md), the [iCloud architecture](docs/ICLOUD_ARCHITECTURE.md), [setup and live acceptance steps](docs/ICLOUD_SETUP.md), and [validation](docs/VALIDATION.md). Fake transport tests do not establish live CloudKit behavior. Automatic local-file eviction, cloud thumbnails, and production deployment remain unfinished.
