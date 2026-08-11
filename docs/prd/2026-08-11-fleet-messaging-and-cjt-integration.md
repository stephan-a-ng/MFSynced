# PRD — MFSynced Fleet Messaging & Customer-Journey-Tool Integration

**Status:** DRAFT for refinement — this document is the input to a scoping
conversation, not an approved plan. Open questions are collected in §8; the
expectation is that Stephan refines the asks (with Claude or otherwise) and
hands back an answered version before any implementation starts.

**Author:** Claude (assessment + drafting), from Stephan's feature ask, 2026-08-11
**Repo:** `github.com/stephan-a-ng/MFSynced`

---

## 1. What MFSynced is today (as-built assessment, 2026-08-11)

Two things bolted together:

1. **A native macOS SwiftUI app** that reads `~/Library/Messages/chat.db`
   read-only, sends via AppleScript to Messages.app, and syncs opted-in
   contacts to a cloud backend over HTTP polling (push inbound / pull
   outbound commands / on-demand history sync), with a local SQLite retry
   queue. Faithful to the original 2026-03-27 design spec.
2. **An organically-grown "team inbox" web product** (FastAPI + Postgres +
   React on Cloud Run, staging + production) that was never in the design
   docs: forward-a-thread-to-teammates with FYI/Action modes, recipient
   inboxes, replies (queued as outbound commands the owning Mac sends via
   AppleScript), reactions, uploads.

### 1.1 Facts that shape this PRD

| Fact | Where | Consequence |
|---|---|---|
| Schema is already multi-agent: `agents.user_id → users` (no uniqueness), conversations/messages keyed `(phone, agent_id)` | `migrations/001_initial.sql` | Fleet support is a product/UX/routing problem, not a schema rewrite |
| No product surface for multi-Mac: no agent picker, registration UI, rename, or key revocation | frontend | The "one interface" must be designed from scratch |
| The Mac app's self-declared `agent_id` UUID is vestigial — server identity comes solely from the hashed bearer API key | `app/api/agent.py:46-49`, `CRMSyncService.swift:91` | Agent identity model needs an explicit redesign |
| "Mirror" = one Mac firing every sync at a *second backend deployment* (staging+prod), config'd by hand, failures swallowed | `CRMSyncService.swift:118-127` | Mirror is an environment workaround, **not** a fleet mechanism; expect to retire it |
| Auth is bespoke: server-side Google OAuth code exchange → self-signed HS256 JWT (30-day, `JWT_SECRET` env), domain-gated to `moonfive.tech` | `app/api/auth.py`, `app/api/deps.py` | Migrating to user-access OIDC is a real workstream, not a config change |
| Password-less dev-login endpoints (leroy/stephan/marco) are live on staging, gated only by `APP_ENV` | `auth.py:88-159` | Security debt to close as part of the auth work |
| Any authenticated user can list all users; visibility = "conversations from agents I own" + "threads forwarded to me"; no claiming, no per-contact ownership | `users.py`, `conversations.py`, `inbox.py` | The claiming/visibility model in this PRD is entirely new |
| Phone numbers are unvalidated free text (`"34913"` appears in tests); no E.164 normalization, no cross-agent contact merge | schema + e2e | Same human synced by two Macs = two unrelated conversations today |
| No backend tests; no backend deploy IaC in-repo; `.env` files committed; agent ingest endpoints unthrottled; uploads on local disk | repo-wide | Baseline hardening rides along with this program |
| Repo last touched 2026-04-06; single branch `main`; no open PRs or worktrees (pre-flight check ran clean) | git | Nothing in-flight to build on or collide with |

---

## 2. Problem statement

Moon Five runs (or will run) **multiple Mac minis, each with its own
Messages.app identity**, syncing iMessage conversations with customers.
Today each MFSynced install is effectively its own silo: the web app shows
you only the conversations of Macs *you* registered, sharing happens by
manually forwarding threads, and no other Moon Five system can see any of
it.

Meanwhile the customer's journey is tracked in other tools — the CRM, the
discovery/prospecting tool, and deploy (collectively **CJTs, customer
journey tools**) — which have no way to answer "what have we said to this
person over iMessage, and what did they say to us?"

Three gaps:

1. **No fleet console.** There is one interface per Mac-owner, not one
   interface over the whole fleet of MFSynced agents.
2. **No programmatic lookup.** CJTs cannot query messages/threads for a
   specific customer (lookup / query / get by person).
3. **No ownership or consent model.** Messages synced from a shared Mac
   mini belong to nobody; there is no notion of a Moon Five person
   *claiming* a conversation, and no control over what a claimer shares
   with the rest of the team / the CJTs.

## 3. Goals

- **G1 — One console, many Macs:** a single "messenger" web interface that
  can see and operate every registered MFSynced agent in the fleet.
- **G2 — Send to individuals:** from that console, compose and send an
  iMessage to a specific person, routed through the appropriate Mac.
- **G3 — CJT read API:** CRM, discovery, and deploy can look up the
  messages and recover the threads associated with a specific person
  (query/get), subject to the sharing rules.
- **G4 — Claiming:** a person logged in with a `moonfive.tech` identity can
  claim messages/conversations, becoming their owner of record.
- **G5 — Sharing modes:** per claimed conversation (or per claimer — see
  OQ-5), two modes selectable in messenger settings: **Share All**
  (default: everything visible to team/CJTs) and **Selective** (claimer
  explicitly picks which messages are shared).
- **G6 — user-access OIDC:** the messenger web app and the CJT API are
  secured by the house user-access OIDC stack (PKCE + JWKS), replacing the
  bespoke Google-OAuth-plus-HS256-JWT scheme.

### Non-goals (this program)

- Replacing iMessage/AppleScript as the transport, or supporting
  SMS-gateway/WhatsApp/etc.
- Building write-access for CJTs (sending messages *from* the CRM is a
  plausible follow-on, but this PRD scopes CJT access as read/lookup —
  see OQ-9).
- Contact dedup/identity-resolution beyond basic phone normalization
  (full customer-identity graph belongs to the CJT side).
- Retiring the Mac app's native chat UI.

## 4. Users

| User | Needs |
|---|---|
| **Moon Five operator** (sales/support/founder) | See fleet-wide conversations, claim theirs, send messages, control sharing |
| **CJT service** (crm, prospect/discovery, deploy) | Machine-to-machine lookup: "messages + threads for customer X" |
| **Fleet admin** (Stephan) | Register/name/revoke Mac agents, see fleet health (last-seen, queue depth), assign send-routing |
| **Mac mini agent** (MFSynced install) | Keep syncing reliably; gain a server-assigned identity |

## 5. Feature requirements

### F1 — Agent fleet management (foundation for G1)

- F1.1 Server-issued agent identity: registration produces a server-side
  agent record (name, owning user or *shared/fleet* flag, created-by,
  key). Retire the client-generated vestigial UUID.
- F1.2 Admin UI: list agents with health (last_seen_at, pending queue
  counts, app version), rename, revoke/rotate API key.
- F1.3 An agent can be marked **shared** (a fleet Mac mini nobody "owns")
  vs **personal** (today's model). Shared agents' conversations enter the
  claiming pool (F4); personal agents keep current behavior.
- F1.4 Retire the client-side mirror feature once fleet + environments are
  handled properly (agents point at exactly one backend per environment).

### F2 — Fleet console ("messenger" web interface, G1)

- F2.1 A fleet-wide conversation list: all conversations across all agents
  the viewer is allowed to see (own + claimed + shared-with-them +
  unclaimed-pool, filterable by agent).
- F2.2 Conversation view shows which agent (Mac) the thread lives on.
- F2.3 Existing inbox/forward features keep working; forwarding becomes a
  special case of sharing (see OQ-6).

### F3 — Outbound send routing (G2)

- F3.1 Compose-to-individual from the console: pick a person (phone /
  contact), type a message, send.
- F3.2 Routing rule decides which Mac sends it. Default: the agent that
  already holds the conversation with that phone number; for a brand-new
  contact, an explicit agent picker (or a configured default per team /
  per use-case — OQ-4).
- F3.3 Delivery lifecycle surfaced in the console (pending → sent →
  delivered/failed), building on the existing `outbound_commands` +
  ack flow.
- F3.4 Guardrail: two agents must never both send to the same contact from
  one command (exactly-one-agent delivery, idempotent ack).

### F4 — Claiming (G4)

- F4.1 Any `moonfive.tech`-authenticated user can **claim** an unclaimed
  conversation (from a shared agent). Claim = ownership of record:
  claimer controls sharing (F5), receives replies in their inbox, is the
  default sender for that thread.
- F4.2 Claims are visible (who claimed what, when) and transferable
  (release / reassign; admin can override).
- F4.3 Claim granularity is the **conversation** (person/phone), not the
  individual message — individual-message granularity appears only inside
  Selective sharing (F5). *(Assumption — confirm in OQ-3.)*
- F4.4 Unclaimed conversations: visible in a shared "unclaimed" pool to
  all operators (so nothing rots invisibly), but NOT exposed to CJTs
  until claimed *(assumption — OQ-7)*.

### F5 — Sharing modes (G5)

- F5.1 Messenger settings expose two modes for claimed conversations:
  - **Share All (default):** every message in the claimed conversation,
    past and future, is visible to the team console and CJT lookups.
  - **Selective:** nothing is shared by default; the claimer picks which
    messages (or message ranges / date ranges) are shared.
- F5.2 The mode is set per claimer as their default, overridable per
  conversation *(assumption — OQ-5)*.
- F5.3 Sharing state is enforced server-side in every read path (console
  fleet views AND the CJT API) — not filtered client-side.
- F5.4 Audit: changes to sharing mode/selection are logged (who, what,
  when).

### F6 — CJT lookup API (G3)

- F6.1 A machine-facing read API: given a customer identifier (phone
  E.164; optionally email or a CJT-side customer ID once a mapping
  exists — OQ-8), return: matching conversations (with claimer, agent,
  sharing mode) and their shared messages/threads.
- F6.2 Consumers: crm, discovery (prospect), deploy — authenticated as
  OIDC m2m clients via user-access (client-credentials, per-service
  client IDs), same pattern as the existing `deploy-ops-prod-m2m`
  service account.
- F6.3 The API returns only what F5 sharing rules allow; a claimed-but-
  selective conversation returns its shared subset plus an indicator that
  more exists ("contact the claimer").
- F6.4 Phone normalization to E.164 at ingest + lookup so CJT queries
  match regardless of formatting (fixes the `"34913"`-style free-text
  debt for new data; backfill strategy in OQ-10).

### F7 — user-access OIDC migration (G6)

- F7.1 Web login: replace bespoke Google-code-exchange + HS256 JWT with
  user-access OIDC (PKCE, JWKS verification), `moonfive.tech` accounts.
- F7.2 M2M: CJT services and (optionally — OQ-11) Mac agents authenticate
  via user-access client-credentials; at minimum, agent API keys get
  scoping, expiry, and revocation (F1.2).
- F7.3 Remove dev-login backdoor endpoints from deployed environments
  (keep an equivalent only in local `development`, never staging/prod).
- F7.4 Register the messenger app + CJT API as apps in user-access
  (per-env, per the user-access URLs runbook).

### F8 — Hardening ride-alongs (baseline debt, done with, not after)

- F8.1 Backend test suite (pytest + house MockDatabaseManager pattern) —
  currently zero backend tests; the sharing/claiming rules (F5.3) are
  exactly the kind of pure logic that must be TDD'd.
- F8.2 Remove committed `.env` files; secrets via Secret Manager.
- F8.3 Rate-limit agent ingest endpoints; move uploads off local disk
  (GCS) or explicitly accept ephemerality.
- F8.4 Commit backend deploy IaC (cloudbuild) so staging/prod deploys are
  reproducible from the repo.

## 6. Proposed phasing (feature-sliced, each slice = own tests + own PR)

| Phase | Scope | Unlocks |
|---|---|---|
| 0 | F8.1 test harness + F8.2 secrets hygiene | Safe iteration |
| 1 | F7 user-access OIDC (web + m2m) + F7.3 backdoor removal | Security baseline for everything after |
| 2 | F1 agent fleet mgmt + F6.4 phone normalization | Fleet foundation |
| 3 | F4 claiming + F5 sharing modes (server-enforced) | Ownership/consent model |
| 4 | F2 fleet console + F3 send routing | The "one interface" |
| 5 | F6 CJT lookup API + first consumer integration (crm) | CJT value |

Rationale: OIDC first because every later surface (console, CJT API) must
be born secured; claiming/sharing before the fleet console so the console
never ships a "everyone sees everything" interim state that then has to be
walked back.

## 7. Success criteria

- One browser tab shows conversations from ≥2 physically distinct Mac
  minis; a message composed there is delivered by the correct Mac.
- A CRM lookup for a known customer phone returns their shared thread(s)
  in <1s, and returns nothing for an unclaimed or unshared conversation.
- A claim + Selective-mode selection round-trips: unshared messages are
  absent from both the team console and the CJT API response.
- All auth flows (human + m2m) verify against user-access JWKS; no HS256
  self-signed tokens or dev-login endpoints remain in staging/prod.
- Backend logic (claiming, sharing, routing) is unit-tested; e2e specs no
  longer hardcode real team members.

## 8. Open questions — ANSWER THESE BEFORE IMPLEMENTATION

*This is the section to refine. Each OQ notes the assumption the PRD
currently makes, so an unanswered question still has a default.*

- **OQ-1 — Fleet topology.** How many Mac minis, near-term and eventual?
  One Apple ID per Mac, or shared Apple IDs? Does each Mac have its own
  phone number? *(Assumed: each Mac = distinct Messages identity; ~2-5
  units near-term.)*
- **OQ-2 — Who are the customers on these Macs?** Residents? Site
  contacts? Prospects? This drives which CJT is the primary consumer and
  what identifier (phone/email/site) lookups key on. *(Assumed: mixed;
  phone is the join key.)*
- **OQ-3 — Claim granularity.** Conversation-level claim with
  message-level *sharing* only (current draft), or true message-level
  claiming? Can two people claim/split one conversation over time?
  *(Assumed: one claimer per conversation at a time.)*
- **OQ-4 — Send routing for new contacts.** Explicit agent picker, a
  per-team default agent, round-robin, or "the shared fleet Mac always
  sends"? *(Assumed: picker with a configurable default.)*
- **OQ-5 — Sharing-mode scope.** Is Share-All-vs-Selective a per-claimer
  account default, a per-conversation setting, or both? Who can see the
  fact that something is withheld? *(Assumed: account default +
  per-conversation override; withholding is visible as a count-only
  indicator.)*
- **OQ-6 — Fate of the existing forward/inbox feature.** Does
  forward-to-team survive as-is alongside claiming, get reframed as
  "share with specific people," or get retired? *(Assumed: reframed.)*
- **OQ-7 — Unclaimed-conversation visibility.** Fully visible to all
  operators? Metadata-only? And are unclaimed conversations exposed to
  CJTs? *(Assumed: visible to operators, hidden from CJTs.)*
- **OQ-8 — Customer identity mapping.** Do CJTs query purely by phone, or
  do we build a customer-ID ↔ phone mapping table (and who owns it — the
  CJT or MFSynced)? *(Assumed: phone-only in v1.)*
- **OQ-9 — CJT write access.** Should the CRM be able to *send* (queue an
  outbound message) in v1, or read-only? *(Assumed: read-only v1.)*
- **OQ-10 — History backfill.** Do existing synced conversations get
  phone-normalized and enter the claiming pool, or does the model apply
  only to newly-synced data? *(Assumed: backfill + normalize.)*
- **OQ-11 — Agent auth depth.** Are Mac agents full OIDC m2m clients
  (device-flow or client-credentials), or do improved scoped/rotatable
  API keys suffice for v1? *(Assumed: improved API keys v1; OIDC for
  humans and CJT services first.)*
- **OQ-12 — Mirror retirement.** Anything currently depending on the
  staging+prod mirror from one Mac that needs a replacement before it's
  removed? *(Assumed: replace with proper per-env deploys; mirror
  removed in Phase 2.)*
- **OQ-13 — Compliance/consent.** Any recording/consent constraints on
  syncing customer iMessages into shared visibility and CRM systems
  (California customers)? *(Not assumed — needs an explicit answer.)*

## 9. Risks

- **AppleScript send fragility at fleet scale** — one wedged Messages.app
  silently stalls a whole slice of outbound; F1.2 health surfacing and
  F3.3 delivery lifecycle are the mitigations.
- **user-access migration breaks existing sessions/keys** — plan a
  cutover with dual-accept window for agent keys.
- **Selective sharing leaks via secondary paths** (uploads/static files,
  forwarded threads created pre-claim, reactions) — every read path must
  go through the same policy check (F5.3); tests must cover the odd
  paths, not just `GET /messages`.
- **Two sources of truth for "customer"** — without OQ-8 answered, CRM
  and MFSynced can drift on identity; keep v1 join dumb (E.164) and
  explicit.
