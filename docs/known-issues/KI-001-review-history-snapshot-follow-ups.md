# KI-001: Review-history snapshot follow-ups

Status: accepted for follow-up on 2026-08-25. The release owner set the merge
gate to P0 only. Independent Claude Opus review found no P0. These P1-P3 items
are therefore documented and do not block the current feature PR.

## P1: Snapshot copies the full Messages database

Affected area:
`MFSynced/Sources/MFSynced/Services/ReviewHistorySnapshotStore.swift` and
`ChatDatabase.swift`.

An owner-history page creates a WAL-consistent copy of the entire `chat.db`
inside the app-support snapshot directory, even though the request targets one
conversation. Mode `0600` and directory mode `0700` prevent cross-user reads,
but another process running as the same macOS user could read unrelated
conversations during the snapshot lifetime.

Recommended follow-up: materialize only the requested canonical conversation
into a compact temporary SQLite database, encrypt the temporary artifact where
practical, and add a test proving unrelated chat rows are absent.

## P1: History claim lacks a local allowlist re-check

Affected area: `MFSynced/Sources/MFSynced/Services/CRMSyncService.swift`.

The authenticated nexus can request a history page for a chat identifier
without the Mac re-checking its local configured sync-number set. The server
still enforces assigned-owner authorization, but the Mac acts as a broader
history oracle if that server boundary is compromised or misconfigured.

Recommended follow-up: require the requested chat to exist in a locally
approved review catalog or explicit owner-review grant, and reject all other
identifiers before opening the snapshot.

## P2: Local snapshot expiry is activity-triggered

Affected area:
`MFSynced/Sources/MFSynced/Services/ReviewHistorySnapshotStore.swift`.

Expired snapshots are removed during store initialization and later page
calls. If the app remains open and no more pages are requested, a snapshot can
outlive its two-hour TTL until the next launch or access.

Recommended follow-up: add an independent cleanup timer tied to application
lifecycle and verify expiry while the app remains idle.

## P3: Only the first claimed request is served per poll

Affected area: `MFSynced/Sources/MFSynced/Services/CRMSyncService.swift`.

The polling path selects `requests.first`. Remaining requests wait for later
poll cycles even though the server may return more than one claim. This is
bounded latency, not data loss, under the current one-in-flight-per-cursor and
polling behavior.

Recommended follow-up: process the returned batch serially with a per-cycle
budget, or change the server contract to return exactly one request.
