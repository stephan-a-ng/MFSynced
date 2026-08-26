# Account selection and Fleet liveness

Phone Sync now treats explicit sign-in and Fleet presence as independent,
bounded workflows.

## Explicit sign-in

Every authorization-code request includes `prompt=select_account`. User Access
therefore shows an account choice even if the browser still has a valid IdP
cookie from a previous user. PKCE, loopback state validation, and token storage
are unchanged.

## Fleet heartbeat

Fleet liveness no longer runs inside the main sync poll. Starting CRM sync
starts one serial heartbeat task that:

- sends immediately, then every 15 seconds;
- never overlaps attempts;
- bounds the complete attempt to 10 seconds, including any token refresh;
- uses 8-second heartbeat and token-refresh request timeouts; and
- is cancelled on stop; a restart waits for the retiring loop before sending.

This keeps a running Mac visible to `message.moonfive.tech` even while catalog,
history, or staging work takes longer than the normal poll interval.
The optional Messages send-handle database scan is refreshed on the ordinary
sync poll and the heartbeat reads only its cached value, keeping synchronous
sqlite work outside the liveness deadline.

## Staged-message workload

Each staging pass retains the 200-row wire cap and adds a 40-query database
cap. Unfinished backfills retain catalog order (most recently active first).
When both tiers exist, incremental work keeps up to five query slots; those
probes execute before row-heavy backfills so a full 200-row backfill cannot
suppress them. Quiet incremental chats are sorted by stable `chatIdentifier`
and rotate after the last chat whose fetched rows fully fit the wire budget,
regardless of POST success. A truncated chat is first again on the next pass.
Consequently, a 1,500-chat quiet catalog is fully checked in at most 38 passes
without depending on catalog order.

Cursor advancement remains confirmation-gated: message row cursors move only
for GUIDs confirmed by the server. The rotation cursor records query fairness,
not delivery success, and is kept in memory per agent.

Tapback rows now consume the same bounded row/query budget but travel as
reaction events, not message bodies. See
[`reviewer-history-and-inbound-reactions.md`](reviewer-history-and-inbound-reactions.md).
