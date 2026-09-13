# Milestone 2 validation

Validated on September 13, 2026 with Xcode 26.3 / Swift 6.2.4 on Apple Silicon.

## Automated checks

The final run passed all 17 tests with zero failures. Run the shared StowKit scheme's XCTest target using the README command. Tests create and remove their own temporary archives; they do not import personal documents.

Coverage:

- PDF byte preservation, SHA-256, file size, and reopening a fresh SwiftData repository.
- Metadata, Favorites, tags, entities, collection membership, custom collections, and archive identity persistence.
- Case-insensitive collection uniqueness.
- Trash and restore persistence.
- Renamed duplicates and duplicates in Trash preserve edited metadata and store one original.
- Distinct contents with the same filename remain separate records.
- Concurrent identical imports commit one record.
- A multi-megabyte PNG crosses streaming-copy chunk boundaries without changing bytes.
- JPEG, PNG, and HEIC import and thumbnail generation; downsampled image preview.
- PDF thumbnail generation and editing a working copy without changing the archived original.
- Rejection of unsupported, empty, mismatched, and invalid inputs.
- Recovery before promotion, after promotion, and after metadata commit.
- A corrupted recovery receipt does not block valid pending imports.
- Missing originals do not cause a potentially needed duplicate recovery copy to be discarded.
- Incomplete copies without receipts are cleaned without touching their sources.
- Batches continue after failures and report duplicates separately.
- File-drop provider delivery for both native URL and data representations.
- Unsafe original paths are rejected.

## Native smoke test

Using only clearly marked, generated test fixtures:

1. Launched into an empty persistent library.
2. Opened the native file picker and imported a two-page PDF.
3. Verified PDF rendering, thumbnail, Inbox count, and second-page navigation.
4. Edited the title and correspondent in the inspector.
5. Reimported the PDF and verified an “Already in archive” report referencing the edited title.
6. Used ⌘N and imported a PNG; verified its image preview and thumbnail.
7. Quit and relaunched the application. Both documents, original previews, edited title, and correspondent survived.
8. Moved both fixtures to Trash, restored the receipt, and verified it returned to Recent.
9. Moved the receipt back to Trash, leaving the active library empty. Both clearly labeled test fixtures remain recoverable in Trash.

Finder mouse dragging was not separately exercised end-to-end; the drop-provider path is covered in XCTest. No OCR, AI, cloud synchronization, real iCloud placeholders, disk-full fault injection, or large-archive load benchmark is claimed. The macOS 14 deployment target compiles against the installed SDK; runtime testing on macOS 14 hardware remains outstanding.

## Toolchain notes

SwiftData and Observation compiler macros require Xcode execution outside this environment's restricted nested sandbox. Approved Xcode builds succeed. Hosted test builds can emit Xcode's standard signed-test-framework stripping notices; App Intents metadata extraction is skipped because this milestone has no App Intents integration.
