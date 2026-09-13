# StowKit

A native macOS household document archive. **Milestone 1: interactive sample-library shell.**

## Run

Open `StowKit.xcodeproj` in Xcode 26.3 or later, select the **StowKit** scheme and **My Mac**, then Run (⌘R). The deployment target is macOS 14.0. No packages, account, or provisioning team are required for local development; the project uses ad-hoc signing.

Command-line build:

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived build
```

## Included

- Native, resizable three-pane SwiftUI navigation with Inbox, Recent, Favorites, and twelve default collections.
- Eight fictional household records, including generated PDF fixtures and a PNG receipt.
- PDFKit preview, image preview, Quick Look, and opening samples with the default application.
- Search across sample titles, summaries, correspondents, tags, entities, collection names, and dates. All query terms must match. Date-added and title sorting.
- Editable titles, summaries, correspondents, dates, tags, entities, and collection memberships.
- Favorite toggles, review completion, context menus, and session-only custom collections.
- Empty states, preview error reporting, and a minimal Settings window explaining the demo.
- ⌘K searches the entire sample library; ⌘F focuses the current filter; ⌘O opens the selected sample; ⌘N explains the upcoming importer; ⌘, opens Settings.

**All edits are in memory and reset on relaunch.** Import is an explicitly labeled milestone placeholder. Samples are generated in the app's temporary directory and never read from personal files. No persistence, OCR, AI, syncing, telemetry, or networking is implemented.

See [architecture and handoff](docs/ARCHITECTURE.md).
