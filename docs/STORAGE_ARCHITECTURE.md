# Optimized storage architecture

Design note for product brief §21–§22. Written before implementation, in the same spirit as
[the iCloud architecture note](ICLOUD_ARCHITECTURE.md): decide the model, then build against
acceptance gates. Nothing described here is implemented yet.

When this note was written, every original StowKit had ever held stayed on every Mac forever:
Trash had no permanent delete (added 2026-09-21), and `CloudSyncCoordinator` never evicts. A synced
household archive therefore grows without bound on each member's disk, which is the opposite
of the brief's promise that StowKit "intelligently manages local disk usage".

## Decision

**Storage state is derived, never stored.** The brief names three states — Cloud Only,
Optimized, Available Offline. Persisting them would create a state machine that can disagree
with the filesystem, and the filesystem is the truth. Compute instead from facts that already
exist:

| Derived state | Condition |
| --- | --- |
| Available offline | The original file exists at `relativePath` |
| Optimized | No original file, but a cached thumbnail and page text exist, and a verified cloud copy exists (see invariant 1) |
| Cloud only | No original file and no cached thumbnail — today only a `remote` document never downloaded |

`ArchiveSchemaV7.OriginalState` already carries `cloudVerified`, `remote`, and **`pinned`**.
`pinned` is declared but never read or written anywhere in the app, so pins need no migration.

**Eviction is a cache operation, not a deletion.** It removes a local copy of bytes that are
immutable and verified in CloudKit. `relativePath` is unchanged, and
`DocumentStorageManager.localOriginal` already re-downloads on demand, shares concurrent
requests, and atomically promotes a verified read-only original. That method's existing
comment — "Future downloads/leases belong here" — marks the intended insertion point. No part
of this design modifies an original, so the brief's "preserve source documents exactly" holds.

## Safety invariants

These are the design. A candidate must satisfy **all** of them, and the check belongs in one
place in `DocumentStorageManager` rather than spread across callers.

1. **A verified cloud copy exists.** Two distinct cases, and conflating them would break the
   most important one:
   - *This Mac uploaded it.* `CloudSyncCoordinator` sets `OriginalState.cloudVerified` only
     after `uploadOriginal` followed by `verifyCloudOriginal` — an independent download checked
     against the manifest. Never treat "upload finished" as sufficient; the existing code
     already does not.
   - *This Mac downloaded it.* `cloudVerified` is **not** set for these: the upload path skips
     documents where `remote == true`. But the only way a remote document's original exists
     locally is `DocumentStorageManager.download`, which validates chunk and whole-file
     SHA-256 and byte count before atomically promoting it. So for a `remote` document, a
     present local original is itself the evidence.

   Requiring `cloudVerified` alone would make eviction a no-op for every document that arrived
   from another household member — which on a second Mac is most of them, and is the entire
   reason this feature exists. The precondition is therefore `cloudVerified == true` **or**
   `remote == true`, and it must be a single named predicate rather than a condition repeated
   at call sites.
2. **Not pinned.**
3. **A cached thumbnail exists.** `ThumbnailService.thumbnail(for:)` renders from
   `cachedOriginal`, which is local-only by design and never triggers a download. Evicting an
   original before its thumbnail is cached makes the document unrenderable until cloud
   thumbnails exist, so the thumbnail must be generated first, and eviction must fail closed
   if it cannot be.
4. **Text extraction is complete and not active.** OCR reads the original. Never evict a
   document whose processing job is queued, running, paused in Trash with work outstanding, or
   failed and retryable.
5. **No in-flight download or open working copy** for that document.
6. **Sync is enabled, bound, and not suspended.** If the transport is off, the local copy is
   the only copy.
7. **The archive is one this account owns.** A read-only participant's access can be revoked,
   which would strand an evicted document. Owner archives only in the first slice.

Invariant 1 plus invariant 6 together give the property that matters: **StowKit never removes
the last copy of anything.**

## What eviction reclaims

Only `Originals/`. Page text, search index, thumbnails, and metadata stay — that is what makes
the Optimized state useful, and what lets full-text search keep working with zero original
downloads, as the iCloud note already requires.

Trashed documents are the best first candidates: they are invisible in normal browsing, they
are the largest unmanaged growth today, and Restore already works through the same download
path. Restoring an evicted document downloads it on demand.

## Accounting

Settings shows one figure labelled "Originals", from `LibraryStatistics.bytes`. That is
`sum(bytes)` over the **search index**, so it is the recorded logical size of every document —
including trashed documents, and including remote documents whose originals were never
downloaded — while ignoring the database, the search index itself, thumbnails, and staging. It
can therefore overstate and understate real disk use at the same time, and it is not a
measurement of disk at all. A budget cannot be built on it, so honest accounting comes first.

Sum the recorded `fileSize` of documents whose original exists locally. That value is
authoritative: it is verified at import and again on download, and reading it from the store
avoids walking `Originals/` on every render. Reconcile against a real directory walk in the
background, on activation and after large imports, and treat a mismatch as a reason to
re-scan rather than as a fault. Report originals, thumbnails, and the store separately;
they have very different growth curves and only one of them is evictable.

## Policy

Off by default. A local archive that never enabled iCloud must behave exactly as it does now.

When enabled, the brief's two controls are enough: keep documents from the last *N* months
downloaded, and a maximum archive size. Evict only when over budget, in this order:

1. Trashed documents, oldest first.
2. Documents outside the keep window, least recently opened first.
3. Largest first as a tiebreak, because it reaches the budget in the fewest evictions.

"Least recently opened" needs a timestamp that does not exist. `modifiedAt` tracks metadata
edits and `importedAt` never changes, so neither is a proxy for use. This requires a **V9**
`lastAccessedAt` on `OriginalState`, written when `localOriginal` serves a document for
preview, Quick Look, or Open Copy. Until V9 exists, ship manual eviction only — a per-document
"Remove Download" — rather than guessing at a policy with the wrong signal.

Every automatic eviction should be reversible by one explicit action and should never be the
user's first surprise: the first time StowKit would evict anything, say so.

## Interface

Per the brief's §29, the mechanism stays invisible until it matters. In the inspector: the
derived state, a pin toggle, and — when Optimized — the existing Download affordance. In
Settings: the usage breakdown, the two controls, and nothing else. No eviction log, no manual
cache browser, no per-collection rules.

## Implementation sequence and acceptance gates

1. **Accounting only.** Usage breakdown in Settings, reconciliation, no eviction anywhere.
   Verify the reported total against `du` on a real archive, including after imports, Trash,
   and a rebuild of the search index.
   *Implemented 2026-09-20* as `DocumentStorageManager.usage()` and `ArchiveUsageView`,
   measured on demand rather than cached. Reconciliation is **not** built: there is no
   recorded-size fast path yet, so every measurement is a full walk. See
   [validation](VALIDATION.md).
2. **Pins and manual eviction.** Wire the existing `pinned` field; add "Remove Download" and
   the derived state. Gate on every invariant above. Verify: an evicted document still
   appears, still searches, still shows its thumbnail; explicit download returns
   byte-identical bytes; a pinned document is never evictable; eviction is refused when
   unverified, when sync is off, when processing is outstanding, and when no thumbnail exists.
   *Implemented 2026-09-20* as `DocumentStorageManager.evictOriginal`, the single decision
   point, with `EvictionFacts` gathered by `ArchiveRepository.evictionFacts` and typed
   `EvictionRefusal` cases. Covered against the fake transport only; nothing has been evicted
   in the running app or against live CloudKit. See [validation](VALIDATION.md).
3. **V9 `lastAccessedAt` and automatic policy.** Only after 1 and 2 hold.

Acceptance, on top of the iCloud checklist's storage items — full-text search with zero
original downloads, multi-chunk recovery, corruption rejection, disk-full recovery, and no
eviction of the last unverified copy:

- Evict, go offline, and confirm the document still browses, searches, and previews from its
  thumbnail, and that requesting the original fails with a clear, recoverable error.
- Evict during an interrupted download and confirm retained chunks are not corrupted by it.
- Fill the disk during a download of an evicted original and confirm the local archive is
  still consistent afterwards.
- Confirm a local-only archive with iCloud never enabled evicts nothing, ever.

## Out of scope

Cloud thumbnails, eviction in shared archives this account does not own, per-collection
storage rules, and eviction enabled by default. Permanent deletion was built separately on
2026-09-21 with tombstones; see `docs/ARCHITECTURE.md` and `docs/VALIDATION.md`.
