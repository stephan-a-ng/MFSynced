# KI-002: Phone-mirror P2 follow-ups

Status: captured 2026-08-31 from the pre-PR review of PR #32 (server-fed
phone mirror). Both were disclosed as deferred in the PR's review stamp and
merged knowingly; neither blocks the mainline mirror path shipped in
Phone Sync 1.6. Logged here because the Notion Tasks board was unreachable
at capture time (log-the-bug fallback).

## P2 #1: A mirror write failure is permanently dropped

Affected area:
`MFSynced/Sources/MFSynced/Views/ContentView.swift:80` (applier call site)
and `CRMSyncService.pullContactUpdates` (cursor advance).

Failure mode: `updatePhoneMirror`'s failure result is discarded and the
contact-updates cursor advances once the applier ran. A transient SQLite
failure (disk full, lock contention) in `upsertPhoneMirror` is logged via
`contactLog` but the batch is never re-fetched, so that contact's mirror
entry stays missing until some later name/photo/number event re-emits the
person. Fixing retry/no-advance semantics requires touching
`CRMSyncService.swift`, which the mirror slice deliberately kept untouched.

Remediation:
- Inspect the mirror-write result in the applier and only advance the
  contact-updates cursor when persistence succeeded, or queue failed
  upserts for retry on the next poll.

Acceptance:
- Unit test: a failing `upsertPhoneMirror` leaves the cursor unadvanced (or
  enqueues a retry) and the entry appears after the next poll.

## P2 #2: A nameless CNContact loses precedence to the mirror

Affected area:
`MFSynced/Sources/MFSynced/Services/ContactStore.swift:363` (root cause,
name guard in `buildPhoneMap()`) and `:385` (mirror fallback fires).

Failure mode: `buildPhoneMap()` excludes any CNContact with no
given/family/org name, so its numbers never enter the apple-side map. With
the PR #32 fallback, such a saved card's number resolves through the SERVER
mirror instead — violating the invariant "a real CNContact match wins" for
this narrow edge (a card with a phone but no name).

Remediation:
- Track apple-match existence independently of display-name derivation
  (populate a raw phone set from `cnContact.phoneNumbers` even when the
  name guard fails) and treat those numbers as mirror-exclusions in
  `resolvePhoneDisplay`.

Acceptance:
- Unit test: a nameless CNContact's number never resolves via the mirror.

## Related P3 (systemic, not scoped here)

`SyncQueueDatabase.swift:435` — the `sqlite3_step` loop does not verify the
terminal result is `SQLITE_DONE`, so a read error looks like an empty/partial
valid load. The same pattern exists at six pre-existing call sites
(`SyncQueueDatabase.swift:140,284`, `ChatDatabase.swift:285,368,413,462`);
sweep them together when fixing either P2.

## Current decision

Non-blocking backlog. Both P2s bite only on edge conditions; the
cursor-advance drop (P2 #1) is the one worth fixing first because it is the
only unrecoverable-without-luck path.
