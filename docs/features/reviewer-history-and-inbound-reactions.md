# Reviewer history and inbound reactions

```yaml
slice: reviewer-history-and-inbound-reactions
status: implemented-automated-validation-complete
affected_components:
  - chat.db message parsing
  - owner-only Fleet review history
  - staged and gated sync queues
  - inbound Tapback normalization
consumed_dependencies:
  - Message nexus review-history request wire
  - Message nexus staged-reaction and inbound-reaction wires
provided_interfaces:
  - review_history_pages_v1 capability
  - inbound_reactions_v1 capability
  - frozen 200-row owner-history pages
  - normalized add/remove reaction events
related_slices:
  - oidc-startup-gate
  - account-selection-and-fleet-liveness
acceptance_criteria:
  - only an authenticated app can read local history
  - history pages use one frozen mode-0600 SQLite snapshot
  - page cursors never skip the look-behind row
  - Tapbacks never upload as quoted message bodies
  - live and staged reactions carry the target message GUID
  - one bounded upgrade replay repairs legacy pseudo-messages
  - no outbound Tapback controls or delivery path exist
test_ownership:
  - MFSyncedTests/ChatDatabaseTests.swift
  - MFSyncedTests/CRMSyncStagedTests.swift
  - MFSyncedTests/SyncQueueDatabaseTests.swift
open_decisions: []
```

## Flow

The ordinary staged window remains the fast first render. When the owner asks
for older history, the nexus creates an opaque request for this Mac. Phone
Sync claims it, creates or reuses a local snapshot, returns at most 200
messages, and keeps the same snapshot identifier for the next cursor. The
snapshot expires locally after two hours.

`ChatDatabase` reads `associated_message_guid` with the existing Tapback type
and emoji fields. `CRMSyncService.stagedRows` emits either a message body or a
reaction event, never both. Classic add/remove Tapbacks normalize to six
stable reaction names. Unsupported custom reaction types are skipped rather
than misrepresented.

Live reaction events use a separate durable queue direction and the
`/reactions/inbound` endpoint. The server confirms a count; Phone Sync removes
the queued events only when the whole locally validated batch is accepted.
Mirror delivery remains best effort after the primary target succeeds.

## Upgrade repair

Older builds may have uploaded Apple's generated `Loved “…”` text as a normal
message. After a heartbeat confirms that the server supports this capability,
Phone Sync clears only its
staged cursors so the bounded newest-200 windows replay. It separately scans
the newest 200 rows of each currently gated chat. Queue GUID dedup makes a
crash retry safe. Reaction uploads include the event GUID, allowing the nexus
to soft-hide the exact legacy row without text matching. The nexus retains the
original as an audited tombstone instead of hard-deleting it.

The repair marker lives in `SyncQueueDatabase.kv_state`; the marker and cursor
reset commit in one SQLite transaction after the bounded chat scan succeeds.
An old server or a failed/locked scan therefore cannot repeatedly destroy
staging progress. The reset does not
delete live message queues, contact cursors, credentials, or unrelated state.

## Privacy and limits

- Authentication remains the outer gate for all local history access.
- Snapshot directories use mode `0700`; snapshot files use mode `0600`.
- A snapshot path, message body, and chat identifier are never logged.
- One page is capped at 200 messages.
- The one-time repair is capped at the newest 200 local rows per chat.
- The Mac does not implement outbound Tapbacks.

## Human validation

Build and install the development app against an isolated local/staging nexus.
Use synthetic contacts and message rows only. Confirm that the authenticated,
assigned owner can page beyond the staged preview; a different operator cannot
read the request; contact-only share does not start sync; conversation share
does; and a classic add/remove Tapback appears on its target message without a
quoted pseudo-message. Confirm there is no outbound Tapback control. Production
installation and rollout require separate human approval after the server
migrations are live.
