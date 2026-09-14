# Validation

## Local sync foundation

Validated September 14, 2026 with Xcode 26.3 / Swift 6.2.4 on macOS 15.7.3, Apple Silicon. The Debug suite passed **70 tests with zero failures**, including all prior 57 tests and 13 new sync tests. The Release build also succeeded.

New coverage includes persisted/coalesced snapshots across restart; exact-operation acknowledgments preserving newer edits; unchanged-edit suppression; stable collection IDs and explicit membership removals; journal failure rolling back metadata, manual protections, and search receipts; automatic versus explicitly accepted metadata; fake delivery with a lost acknowledgment and idempotent retry; bounded batches and partial acknowledgment; manual/automatic and same-field conflict policies; Trash/Restore and membership merge behavior; V4 migration preserving document metadata, protected fields, saved OCR progress/text, and search receipts without historical upload enqueueing; and missing/wrong-size original rejection without deleting bytes.

These are local tests with generated fixtures. The app does not instantiate the transport, contact CloudKit, upload documents, or evict originals. Fake transport tests establish receipt behavior, not CloudKit save semantics. Incoming remote application, durable conflict resolution, collection alias migration, download leases, live account sharing, and metadata-only CloudKit fetches remain unverified/unimplemented. No new interactive UI verification is claimed for this slice. The previously documented Core Data model-checksum and array-materialization diagnostics remain present; migration assertions and all tests pass.

## Milestone 6 architecture review

Reviewed September 14, 2026. This milestone changes documentation only. The [iCloud architecture note](ICLOUD_ARCHITECTURE.md) was checked against the current local schemas, explicit `cloudKitDatabase: .none` configuration, import recovery, incremental search journal, and manual-analysis protections. Apple's CloudKit documentation and the installed Xcode 26.3 SDK informed the API choices; the SDK's CKSyncEngine fetch options do not expose asset-field projection.

Checked documentation links to local files and whitespace with `git diff --check`. No application code, schema, entitlements, signing, or user data changed. Builds and tests were not rerun for this documentation-only milestone; the application validation below remains the last executable verification. CloudKit projection, two-account sharing, encrypted fields, transfers, and eviction are proposed and explicitly untested. The note defines the acceptance gates required before shipping them.

## Milestone 5

Validated on September 13, 2026 with Xcode 26.3 / Swift 6.2.4 on Apple Silicon.

## Automated checks

The final run passed all 57 tests with zero failures (17 archive, 13 processing, 12 search, and 15 intelligence tests). Run the shared StowKit scheme's XCTest target using the README command. Tests create and remove their own temporary archives; they do not import personal documents.

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

## Processing checks

- Migration from a real V1 SwiftData store preserves documents, archive identity, custom collections, and original hashes; queued jobs are backfilled.
- Imports and exact duplicates produce one durable processing job.
- Real PDFKit extraction uses embedded text without changing original bytes.
- Real Vision OCR recognizes generated images and scanned PDF pages.
- A mixed PDF uses embedded text on one page and OCR on another; both are saved and searchable.
- Failed extraction keeps completed text; Retry resumes at the failed page without repeating the earlier page.
- Reopening a repository after a simulated interruption resumes the committed checkpoint.
- Cancellation requeues without falsely advancing progress.
- Trash pauses and Restore resumes; an in-flight OCR failure cannot override the paused state.
- A locked PDF fails with an actionable message and does not block the next job.
- Blank images complete with zero text; unavailable originals fail without deleting metadata.
- Search combines metadata and normalized text across pages, including diacritics; a fresh read observes Extract Again resets and subsequent reprocessing.
- The older batch test waits for background search completion before deleting its temporary archive, avoiding test-teardown I/O races.

## Search checks

- Weighted ranking prioritizes title matches; snippets contain highlight spans.
- Prefixes, accents, case, exact phrases, unmatched quotes, and punctuation behave as documented.
- Literal SQL/FTS-looking input cannot broaden results or execute SQL.
- AND terms match different metadata fields and different extracted pages.
- Title edits remove old matches; Favorites, custom collections, Inbox failure state, Trash, and Restore update incrementally.
- Extract Again removes stale OCR matches without changing metadata.
- Pending receipts replay after reopening; repeated rebuilds remain idempotent.
- An index commit followed by an unacknowledged receipt and newer edit preserves the latest source state.
- A corrupt cache is recreated from saved metadata/text.
- An index-path write failure preserves browsing; fixing the path and rebuilding restores search.
- Fallback browsing respects collection and Trash filters.
- Three pages cover 123 records without duplicate IDs; LibraryStore initially holds only 50 and Load More expands to 100.
- Rapid query changes discard stale results; a duplicate-report selection can resolve outside the first page.
- A real V2 store migrates to V3 without losing metadata, completed jobs, or saved page text. V1 migration also exercises the production background recovery path.

## Intelligence checks

- High-confidence rule output files a document, updates search, and preserves source identity/path/date.
- Medium-confidence output files; unknown text keeps the document in Inbox. Uncertain reanalysis returns a previously auto-filed document to review.
- Manual edits, cleared summaries, collection choices, and review flags survive pending analysis.
- An edit made while a provider is running wins at commit time.
- Unknown collection names, absent evidence, fabricated issuers, and nonfinite confidence are rejected.
- Long input is bounded and cannot auto-file based only on its excerpt.
- Interrupted analysis requeues; accepting a displayed proposal persists through reopening.
- Cancellation requeues without applying metadata.
- OCR reset invalidates in-flight results; Trash pauses and Restore resumes analysis.
- A failed provider does not block the next job or existing OCR search.
- A real V3 archive migrates to V4 and retains protected metadata while receiving suggestions.
- The production provider falls back successfully on macOS 15.7.3.

The development Mac runs macOS 15.7.3. Foundation Models code builds against the installed macOS 26.2 SDK but its macOS 26 branch cannot execute here. Live Apple model generation, model refusal/context-overflow behavior, and output quality on an eligible macOS 26 Mac remain unverified. The provider test runs a synthetic Apple-model request when that API and model are available; on this host it exercised the production fallback instead. No generated output is claimed as tested Apple-model output.

## Milestone 4 synthetic index benchmark

Run from the repository root:

```sh
xcrun swiftc -O StowKit/Models/Document.swift StowKit/Models/Search.swift StowKit/Services/FullTextIndex.swift scripts/search-benchmark.swift -o /tmp/stowkit-search-benchmark
/tmp/stowkit-search-benchmark 50000
```

This compiles the app's actual index implementation. It creates a temporary SQLite cache with 50,000 synthetic records and approximately 4.8 KB of extracted text per record, then removes it. Six queries (prefix, title, common multiword, phrase, unique, and no match) run five times; each includes exact result counts and up to 50 snippets. The deliberately repeated text makes common queries match much of the archive. No personal documents are accessed.

Measured on the development Apple Silicon Mac. The final run overlapped the Release build, so these are development-machine observations rather than isolated performance guarantees:

| Operation | Time |
| --- | ---: |
| Index 50,000 synthetic documents | 16.325 s |
| Reopen existing index | 1.493 ms |
| Search median, 30 queries | 49.949 ms |
| Search 95th percentile | 332.204 ms |
| Slowest search | 336.069 ms |
| First 50 metadata IDs | 292.091 ms |
| Archive count/size statistics | 4.763 ms |

The cache was 447.3 MB, including stored text and FTS postings. These are optimized index timings, excluding the 150 ms UI debounce, SwiftData snapshot fetching, thumbnails, and view rendering. Index reopening is not total application launch. A full 50,000-record SwiftData migration, OCR run, peak-memory profile, and interactive large-archive test remain unmeasured. Timings depend on hardware, document lengths, and match frequency.

The benchmark caught an expensive SQLite count plan that repeated MATCH per document. The final query makes FTS drive the join and generates snippets only for the selected window.

## Native verification — September 14, 2026

Verified with generated, clearly marked fictional fixtures on the unlocked macOS 15.7.3 desktop. The main pass used the Milestone 5 Release build; the review-state fix was rechecked in the corrected Debug build that passed all 57 tests.

- Imported a two-page mixed PDF through the native picker. The inspector reported two pages, one OCR page; View Text displayed embedded text and OCR separately.
- Confirmed high-confidence filing into Insurance and a cleared Inbox; the PDF preview and page-navigation control worked.
- Searched an OCR-only word (`blueberry`) and visually verified its highlighted result snippet. Vision transcribed `bicycle` as `biccle`; the original remained intact. This is an observed OCR accuracy limitation, not an indexing failure.
- Exercised View Text and Copy All. The copy control was activated; clipboard contents were not independently inspected.
- Changed the title, ran Analyze Again, and confirmed the manual title survived.
- Verified ⌘N, global ⌘K, and scoped ⌘F through the native UI.
- Imported a PNG warranty scan. It rendered correctly, was filed under Warranties, and showed the medium-confidence Suggested filing label.
- Visually inspected the Suggestions sheet, including title, collection, tags, summary, evidence, and the explicit replacement explanation; applied the proposal.
- Found and fixed a review-state bug: accepting already-applied suggestions did not protect unchanged fields or clear Suggested filing. Acceptance now explicitly protects the review decision and nonempty suggested fields in the same metadata transaction. The corrected UI clears the row label; reanalysis preserves acceptance. A regression test verifies acceptance also survives later uncertain OCR results.
- Imported a password-protected PDF. It remained in Inbox, displayed an actionable error and Retry, and retained its archived metadata. Retrying safely returned the same locked-PDF error.
- Rebuilt the search index through Settings and successfully searched the image's OCR-only word `tangerine` afterward.
- Quit and relaunched the application; all three documents, edited title, extraction state, and filing results persisted.
- Moved the warranty to Trash and restored it; it returned to Recent with its reviewed state preserved.
- Finished by moving all three new fixtures to recoverable Trash. Recent and Inbox are empty; Trash contains these three plus the two prior QA fixtures. No personal documents were imported or edited.

Load More with a visually populated 50+ document list, Finder mouse dragging, in-flight quit/relaunch on a long OCR job, and a live Apple model remain outside this desktop smoke test. Pagination, interruption recovery, and drop-provider delivery are covered by the automated suite. Apple generation still requires an eligible macOS 26 installation.

The corrected Debug build and 57-test suite succeeded. The corrected Release build also succeeded after a temporary approval-service capacity error, and was launched successfully at the end of verification. It is left open with an empty active library and all QA fixtures recoverable in Trash.

## Prior Milestone 2 native smoke test

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

Finder mouse dragging was not separately exercised end-to-end; the drop-provider path is covered in XCTest. No AI, cloud synchronization, real iCloud placeholders, disk-full fault injection, or end-to-end large-archive UI benchmark is claimed. OCR was validated in the Milestone 3 automated tests above, not in this earlier UI smoke test. The macOS 14 deployment target compiles against the installed SDK; runtime testing on macOS 14 hardware remains outstanding.

## Toolchain notes

SwiftData and Observation compiler macros require Xcode execution outside this environment's restricted nested sandbox. Approved Xcode builds succeed. Hosted test builds can emit Xcode's standard signed-test-framework stripping notices; App Intents metadata extraction is skipped because this milestone has no App Intents integration.

During the test runs, Core Data emitted model-checksum and Array<String> materialization diagnostics while initializing/migrating versioned schemas. A fallback predicate on the frozen collection array caused a reproducible crash during development. That predicate was removed; the collection fallback now filters bounded value snapshots. The final migration, fallback, and reopened-data assertions passed. This diagnostic is recorded without assuming it is harmless or changing the frozen V1 schema to suppress it.
