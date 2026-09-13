# StowKit

A native, local-first macOS household document archive. **Milestone 2: a persistent manual document library.**

## Run

Open `StowKit.xcodeproj` in Xcode 26.3 or later, select **StowKit → My Mac**, and Run (⌘R). Minimum deployment target: macOS 14.0. No packages, account, server, or provisioning team are required for local development; the project uses ad-hoc signing.

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived build
```

## Use

1. Import PDF, JPEG, PNG, or HEIC files with **⌘N**, the toolbar, or drag/drop from Finder. Multiple files are processed sequentially in the background.
2. Imports appear in **Inbox**. Titles initially come from filenames and document dates initially use the import date; edit the metadata and choose **Mark Reviewed** when organized. There is no OCR or AI yet.
3. Edit titles, summaries, correspondents, dates, tags, entities, Favorites, and collection membership in the inspector. Changes and custom collections persist immediately.
4. Use **⌘K** to search the whole active library or **⌘F** to filter the current view. Search currently covers metadata, not text inside documents.
5. Use **Quick Look**, the inline PDF/image preview, or **⌘O** to open an editable copy in another app. The archived original remains unchanged. Multipage PDFs have page navigation; password-protected PDFs can be archived and opened as copies for unlocking.
6. **Move to Trash** from the toolbar, context menu, or Delete key while the document list has focus. Restore from StowKit's **Trash**. Trash is retained indefinitely and still consumes disk space; this version has no permanent-delete action.

Exact duplicates are detected across the entire archive, including Trash. The import report links to existing documents and identifies individual failures without stopping the remaining batch. A renamed duplicate does not overwrite edited metadata.

## Storage and privacy

The sandboxed app keeps its archive under its Application Support directory:

```text
~/Library/Containers/com.stowkit.app/Data/Library/Application Support/StowKit/
    Library.store          SwiftData metadata (plus SQLite sidecars)
    Originals/AB/UUID.pdf   Immutable, opaque-ID original files
    Staging/UUID/          Interrupted-import recovery receipts and copies
    Thumbnails/UUID.png    Regenerable local thumbnails
```

Settings displays the actual location. A non-sandboxed development runner may use a different Application Support location. Originals never use collection names as folder paths. Imports use security-scoped file access, coordinated reads, streaming SHA-256, and atomic staging/promotion. Originals are stored with read-only permissions. Opening a copy creates a separate file in the app's temporary directory; edits to it are not automatically reimported.

**This is a local archive, not a cloud backup.** iCloud/household synchronization, OCR, and AI are future milestones. Back up the complete archive directory while the app is closed, including database sidecars and originals. No telemetry, external AI, or network integration is included.

The first launch starts empty; the old fictional sample library is no longer loaded. Importing does not move or modify source files.

## Tests

Run **Product → Test (⌘U)** in Xcode or:

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived -destination 'platform=macOS' test
```

The XCTest target creates isolated temporary archives and generated fixtures. Coverage includes byte preservation across multiple copy chunks; supported formats; duplicate and concurrent imports; durable metadata and collections; Trash/Restore; URL/data drop providers; import recovery; malformed inputs; thumbnails; and safe external copies.

See [architecture and implementation notes](docs/ARCHITECTURE.md) and [validation](docs/VALIDATION.md).
