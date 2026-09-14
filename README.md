# StowKit

A native, local-first macOS household document archive. **Milestone 4: ranked local full-text search with incremental indexing.**

## Run

Open `StowKit.xcodeproj` in Xcode 26.3 or later, select **StowKit → My Mac**, and Run (⌘R). Minimum deployment target: macOS 14.0. No packages, account, server, or provisioning team are required for local development; the project uses ad-hoc signing.

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived build
```

## Use

1. Import PDF, JPEG, PNG, or HEIC files with **⌘N**, the toolbar, or drag/drop from Finder. Multiple files are processed sequentially in the background.
2. Imports appear in **Inbox** and automatically enter the background text-extraction queue. StowKit prefers usable PDF text and uses Apple Vision OCR for scanned pages and images. The inspector shows progress, **View Text**, and **Retry** when needed. Titles initially come from filenames and document dates initially use the import date; metadata classification is still manual.
3. Choose **Mark Reviewed** when organized. OCR failure never removes a document; you can still preview and edit it. Failed extraction is surfaced in Inbox even for an otherwise reviewed document.
4. Edit titles, summaries, correspondents, dates, tags, entities, Favorites, and collection membership in the inspector. Changes and custom collections persist immediately.
5. Use **⌘K** to search the whole active library or **⌘F** to filter the current view. Search ranks titles, correspondents, metadata, and extracted text together, including words found on different pages. Type word prefixes such as `refrig warranty`, or use quotes for an exact phrase such as `"renewal date"`. Matches ignore case and accents and appear in highlighted snippets. Results load 50 at a time; use **Load More** to continue. Search results use relevance order; the Sort menu controls browsing without a query.
6. Use **Quick Look**, the inline PDF/image preview, or **⌘O** to open an editable copy in another app. The archived original remains unchanged. Multipage PDFs have page navigation; password-protected PDFs can be archived and opened as copies for unlocking.
7. **Move to Trash** from the toolbar, context menu, or Delete key while the document list has focus. Restore from StowKit's **Trash**. Trash is retained indefinitely and still consumes disk space; this version has no permanent-delete action.

Exact duplicates are detected across the entire archive, including Trash. The import report links to existing documents and identifies individual failures without stopping the remaining batch. A renamed duplicate does not overwrite edited metadata.

## Processing and recovery

Text is saved one page at a time with its processing checkpoint. If StowKit quits during extraction, it resumes after the last saved page on the next launch. **Retry** keeps completed pages; **Extract Again** in the text-extraction menu discards derived text and starts over without touching the original. Moving a document to Trash pauses unfinished extraction; Restore resumes it.

Existing Milestone 2 archives migrate automatically and receive processing jobs. The original document schema and original files are preserved. Password-protected PDFs remain archived but require an unlocked copy to be imported before OCR can run. Blank documents complete with “No text found.” OCR can make mistakes, so the original remains the source of truth.

The search index updates incrementally after imports, edits, and processing. Existing archives build their index from saved metadata and page text in the background; originals are not re-read. **Settings → Rebuild Search Index** regenerates the cache without resetting OCR or changing documents. If an index write fails, ordinary library browsing remains available and search shows an error.

## Storage and privacy

The sandboxed app keeps its archive under its Application Support directory:

```text
~/Library/Containers/com.stowkit.app/Data/Library/Application Support/StowKit/
    Library.store          Metadata, page text, and jobs (plus SQLite sidecars)
    Originals/AB/UUID.pdf   Immutable, opaque-ID original files
    Staging/UUID/          Interrupted-import recovery receipts and copies
    Thumbnails/UUID.png    Regenerable local thumbnails
    Search/Search.sqlite  Rebuildable full-text index (plus SQLite sidecars)
```

Settings displays the actual location. A non-sandboxed development runner may use a different Application Support location. Originals never use collection names as folder paths. Imports use security-scoped file access, coordinated reads, streaming SHA-256, and atomic staging/promotion. Originals are stored with read-only permissions. Opening a copy creates a separate file in the app's temporary directory; edits to it are not automatically reimported.

**This is a local archive, not a cloud backup.** iCloud/household synchronization and AI classification are future milestones. PDF parsing and Vision OCR run locally, with no external AI service. Back up the complete archive directory while the app is closed, including database sidecars and originals. No telemetry, external AI, or network integration is included.

The first launch starts empty; the old fictional sample library is no longer loaded. Importing does not move or modify source files.

## Tests

Run **Product → Test (⌘U)** in Xcode or:

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived -destination 'platform=macOS' test
```

The XCTest target creates isolated temporary archives and generated fixtures. The tests cover archive integrity, migration from V1 and V2, real PDF/Vision OCR, checkpoint recovery, search ranking and snippets, prefix/phrase matching, metadata updates, pagination, journal replay, and cache failure/rebuilding. A standalone synthetic 50,000-document index benchmark is included; see validation for results and limits.

See [architecture and implementation notes](docs/ARCHITECTURE.md) and [validation](docs/VALIDATION.md).
