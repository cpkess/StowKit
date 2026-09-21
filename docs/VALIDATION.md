# Validation

## Vision cold-start cost measured

September 20, 2026: the first `VNRecognizeTextRequest` in a process costs **46.5 s**;
subsequent requests in that process cost **0.08 s**. Measured with a 90 KB standalone Swift
tool containing no StowKit code, so this is a property of Vision on this machine, not of the
app. macOS 27.0 (26A428), Apple M2 Max.

```text
iteration 1: 46.494 s   iteration 2: 0.081 s   iteration 3: 0.085 s   iteration 4: 0.088 s
```

The warm state is **shared between processes and expires**. A second process started
immediately after paid only 0.173 s, and a third 0.178 s; but a fresh process roughly twenty
minutes later paid the full 46.3 s again. The cost therefore recurs after idle rather than
being a one-time, first-launch charge. The `e5rt` fallback messages recorded below appear on
every cold run and remain non-fatal — recognized text is correct in all cases.

Consequence for the UI: text extraction already shows a spinner, a `· 1 of N` label, and a
determinate bar, so the window is **not** a frozen-looking app — but the first page can sit
at `1 of N` for roughly a minute with no stated reason. `ProcessingInspector` now adds a
caption after six seconds on an uncompleted first page. The extraction pipeline is unchanged;
the delay is Apple's and is not worked around.

**Not established.** The exact idle threshold at which the warm state is discarded (observed
lost somewhere between 2 and 20 minutes), whether it is tied to memory pressure, and whether
other Macs or macOS versions behave the same. The caption's six-second threshold is a
judgement call, not a measured optimum, and it was not verified on screen — triggering it
requires an import into a real archive.

## macOS 27 OCR regression — not reproducible in the shipping build

September 20, 2026 (later run, Claude Code): the OCR failure recorded under "Latest regression
status after provisioning" **does not reproduce in the default ad-hoc build**. The full Debug
suite ran **95 tests with zero failures** on macOS 27.0 (26A428), Apple M2 Max, including both
previously failing tests. `ProcessingTests` alone ran 13 tests with zero failures. Evidence:
`/tmp/claude-501/.../full-suite.log`, re-runnable with the standard test command in `README.md`.

The recorded root cause was wrong in one specific way, and the correction matters for anyone
re-investigating. The `e5rt` messages name **system** resources, not anything StowKit generates:

```text
[e5rt] Unable to find a valid E5 in provided path
/System/Library/PrivateFrameworks/TextRecognition.framework/Resources/cr_td_model_v3_e5.mlmodelc.bundle/.
Found bundles : { }. Expected : { H14G.N301.bundle H14C.bundle ... universal.bundle jit.bundle }
```

Those directories exist but hold a flat compiled CoreML model (`coremldata.bin`, `model.mil`,
`weights`) instead of the per-hardware sub-bundles the E5 runtime expects, so e5rt declines the
ANE path and Vision falls back. No `com.apple.e5rt.e5bundlecache` exists under StowKit's
container or `~/Library/Caches` at all, so there is no "StowKit generated E5 cache" to repair —
the earlier attempt to preserve/rename one was operating on a directory that does not exist.
The fallback is a logged warning, not a failure: the assertions on recognized text pass.

Cold-start cost is real and worth knowing: the first Vision call in a fresh process took
**46.2 seconds**; the same test warm took **0.5 seconds**. A user's first scanned import can
therefore appear to hang for roughly a minute.

**The provisioned configuration was then tested and also passes.** After the Apple account was
re-authenticated, `ProcessingTests` ran **13 tests with zero failures** against a test host
signed with the real Development iCloud entitlements (`iCloud.com.stowkit.app`), hardened by the
App Sandbox, and verified with `codesign -d --entitlements`. `testVisionReadsImageAndScannedPDF`
passed in 0.528 s; the cold ~25 s Vision warm-up simply landed on whichever test ran first. The
same `e5rt` messages appear and remain non-fatal. Signing, entitlements, and the sandbox
container therefore do **not** reproduce the failure, and no OCR code was changed.

Running the hosted tests in that configuration needs `Config/iCloud.tests.xcconfig`.
`iCloud.local.xcconfig` applies `CODE_SIGN_ENTITLEMENTS` and `INFOPLIST_FILE` to every target,
so `StowKitTests` requests iCloud entitlements that `com.stowkit.tests` is not registered for
and profile creation fails before compiling. The tests config scopes both settings to the app
target through `$(TARGET_NAME)`.

**Still not established.** Why the September 20 post-provisioning run failed. Both plausible
remaining explanations — a transient Vision/ANE state that has since cleared, or an
interaction with that specific run's environment — are unproven, and the original failing
state no longer exists to inspect. If OCR fails again, capture the full `e5rt`/`e5rtError`
output and the exact build configuration before rebuilding anything.

## Developer ID and Production CloudKit verification

September 20, 2026: deployed the four StowKit record types from Development to Production in `iCloud.com.stowkit.app` under Gamergrams. Created a Developer ID provisioning profile for the existing Gamergrams certificate; it has `ProvisionsAllDevices = true` and Production iCloud entitlements.

Version 0.6.0 build 3 was archived and exported with Developer ID, hardened runtime, arm64 and x86_64, no debugging entitlement, and no device restriction. The distribution script now derives an xcconfig to force Production in both the app settings and signed entitlements; command-line overrides alone left the local xcconfig's Development value in the app. The corrected export passed all checks in `scripts/build-distribution.sh`. Apple accepted notarization for both the app (`a115f374-8fa7-4263-84cc-5fcadeae6831`) and DMG (`0cc52cbb-6067-4416-b6ac-8d145b221746`). Both tickets were stapled and validated, and both passed Gatekeeper assessment as Notarized Developer ID. The final DMG was mounted read-only; the contained app passed strict signature, staple, Gatekeeper, architecture, version, and Production configuration checks. The Applications link and final SHA-256 sidecar were verified. DMG SHA-256: `490987f592ee459f853597cad60f5fcfbde708090d1da22e917a31d5b3a9519f`. This does not establish execution on a second physical Mac or resolve the acceptance limitations below.

An explicitly compiled Production runner used an isolated archive and fictional generated data. The first run failed with “Moving downloaded asset failed” during original transfer. A retry with diagnostic reporting passed zone creation, multi-chunk upload, independent hash verification, searchable metadata/text catch-up without materializing the original, byte-identical explicit download, and an edit converging between two local stores. Evidence: `/tmp/stowkit-production-live-retry.log`. This remains a same-Mac, same-account smoke test; two-Mac/two-account sharing and the other acceptance checks below remain unverified. Generated test zones were retained, and no existing user documents were uploaded.

## v0.6.0-alpha.1 packaging

Built version 0.6.0 (build 2) in Release with Gamergrams development provisioning. The compressed DMG passed `hdiutil verify`; it was mounted read-only and the contained app passed `codesign --verify --deep --strict`. Verified both arm64 and x86_64 architectures, expected version and CloudKit Development bundle settings, and the Applications installation link. The embedded development profile includes one Mac and expires September 19, 2027. This is an unnotarized development prerelease, not general public distribution. Packaging does not resolve the OCR and household acceptance limitations below.

## Latest regression status after provisioning

> **Superseded in part.** The OCR diagnosis below misattributes the `e5rt` messages to a
> StowKit-generated cache; no such cache exists. See "macOS 27 OCR regression — not
> reproducible in the shipping build" above. The rest of this entry stands.

The normal signed Release build succeeds and passes strict code-signature verification. A local copy is available at `build/iCloud-development/StowKit.app` (ignored by Git); it includes the expected container, Development environment, and sharing bundle flag. The cloud test runner is excluded from that build.

The post-provisioning full suite ran 95 tests: all cloud tests passed, but two OCR tests failed with six assertions/errors. Vision reported a missing `main_ane/model.anehash` in StowKit's generated E5 cache and `e5rtError` code 13. A supported per-stage CPU retry experiment still failed the real image/scanned-PDF test and was removed; no OCR code change is shipped. An attempt to preserve/rename only the app's generated cache was denied by macOS (`Operation not permitted`), leaving it unchanged. A final targeted rerun of the original OCR implementation completed 13 processing tests with one remaining image/scanned-PDF runtime failure (`/tmp/stowkit-ocr-cache-recovery.log`). The earlier 95-test pass below remains historical evidence, not the latest all-green status. Current OCR runtime recovery requires further verification; original bytes and saved text are retained.

## Live private CloudKit smoke test

September 19, 2026: provisioning succeeded with Gamergrams LLC, bundle `com.stowkit.app`, container `iCloud.com.stowkit.app`, Development environment. The app's signed entitlements and embedded profile were inspected. An unrestricted signing-identity check found valid Apple Development and Gamergrams Developer ID identities; the earlier sandboxed check could not see them. The previously expired Xcode authentication was restored by the user.

The first signed launch exposed missing custom Info.plist keys. The cloud configuration now supplies an explicit Info.plist; a fresh derived-data build includes the container, environment, and `CKSharingSupported`. An explicitly compiled validation runner then used only fictional generated bytes in an isolated archive. It passed live zone creation, upload of an 8 MiB + 137-byte original through multiple CKAssets, independent download/hash verification before metadata publication, metadata/text catch-up into a second local store without an original file, full-text search, explicit byte-identical download, and a second-store metadata edit converging back through CloudKit. Output: `/tmp/stowkit-live-configured.log`. Successful test zone: `StowKit-35BE7271-4B46-43EC-8698-1EDB9987F4D1` (Development).

The two stores ran on one Mac using one account. This does **not** verify a second physical Mac, invitation acceptance, shared-database permissions, revocation, original-owner offline behavior, quota errors, interrupted transfers, or actual network-byte exclusion. No household invitations were sent and no existing user documents were uploaded. Generated test zones are retained for inspection. The normal build excludes the manual runner; see [setup](ICLOUD_SETUP.md) for explicit invocation.

## CloudKit implementation on macOS 27

September 19, 2026: **95 tests passed with zero failures** on macOS 27.0 (26A428), Xcode 27.0 (27A266a), Apple Silicon. The optimized Release build also succeeded. The full suite includes 13 CloudArchiveTests covering searchable remote text without original downloads, thumbnail behavior, concurrent duplicate imports, conditional-save conflicts, exact acknowledgments, account binding, transactional invalid-page rejection, V7→V8 text-queue migration, multiple text batches past blocked extraction, read-only participants, corrupt-original rejection, and expired-token recovery. Apple Foundation Models reported available; the existing on-device inference test passed.

The first full run found a SQLite lock in the raw legacy migration fixture. Releasing the fixture container in an autorelease pool and setting a bounded SQLite busy timeout fixed fixture construction; the subsequent complete run passed. The V8 migration retains the old property mapping to avoid the macOS 27 inherited `hash` accessor collision. Framework logs still include autoShortcut connection failures, SwiftData diagnostics, and Vision model-resource messages; their presence did not fail the assertions.

Native UI smoke verification: the app opened the existing six-document archive on macOS 27, showed its existing list and Trash count, and opened Settings. Settings correctly displayed iCloud off and the requirement for a configured signed build. Before launch, the SQLite database and originals were backed up to `/tmp/StowKit-pre-V8-backup`; all six original SHA-256 values remained identical afterward. This temporary backup is verification evidence, not a durable user backup. No document contents were changed for this smoke check.

**Historical provisioning blocker, resolved by the live smoke test above:** Xcode now launches, but Apple Accounts reports expired authentication; `security find-identity -v -p codesigning` reports zero valid identities. No live container, private/shared sync, invitation, permission revocation, network asset projection, or quota test has passed yet. No document uploads or invitations were sent. See [setup and live acceptance](ICLOUD_SETUP.md). The sections below are historical checkpoints, not descriptions of the current implementation.

## Local sync recovery

September 14, 2026: the expanded Debug suite passes **82 tests with zero failures**, including 12 new recovery tests. The Release build also succeeded. These cover bounded backfill across restart, edits during backfill, rollback without advancing the checkpoint, conservative legacy protections, independent-field merges and search indexing, persisted baselines/cursors, conflict history and resolution, newer local edits invalidating stale resolutions, later remote edits retaining the local alternative, all-or-nothing invalid-page rejection, stale page rejection, unsupported versions/archive identities/memberships, fake fetch retry, and V5 migration preserving a pending operation UUID.

The receiver handles existing local documents and known collection identities only. Backfill, incoming feeds, and conflict resolution are repository/test APIs, not enabled UI features. No iCloud transport, account binding, new remote originals, or eviction is present. The outgoing fake protocol does not yet implement conditional server saves. The prior Core Data diagnostics remain present; all migration assertions pass. No new interactive UI verification is claimed.

## Local sync foundation (earlier slice)

Validated September 14, 2026 with Xcode 26.3 / Swift 6.2.4 on macOS 15.7.3, Apple Silicon. The Debug suite passed **70 tests with zero failures**, including all prior 57 tests and 13 new sync tests. The Release build also succeeded.

New coverage includes persisted/coalesced snapshots across restart; exact-operation acknowledgments preserving newer edits; unchanged-edit suppression; stable collection IDs and explicit membership removals; journal failure rolling back metadata, manual protections, and search receipts; automatic versus explicitly accepted metadata; fake delivery with a lost acknowledgment and idempotent retry; bounded batches and partial acknowledgment; manual/automatic and same-field conflict policies; Trash/Restore and membership merge behavior; V4 migration preserving document metadata, protected fields, saved OCR progress/text, and search receipts without historical upload enqueueing; and missing/wrong-size original rejection without deleting bytes.

These are local tests with generated fixtures. The app does not instantiate the transport, contact CloudKit, upload documents, or evict originals. Fake transport tests establish receipt behavior, not CloudKit save semantics. At that checkpoint, incoming application and conflict persistence were still pending; the recovery section above records their subsequent local implementation. Collection alias migration, download leases, live account sharing, and metadata-only CloudKit fetches remain unverified/unimplemented. No new interactive UI verification is claimed for this slice. The previously documented Core Data model-checksum and array-materialization diagnostics remain present; migration assertions and all tests pass.

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
