# OIDC startup gate

```yaml
slice: oidc-startup-gate
status: complete
affected_components:
  - macOS startup lifecycle
  - OIDC token validation and loopback callback
  - macOS Keychain persistence and sign-out cleanup
  - main and Settings window privacy gates
  - CRM authorization resolution
  - synthetic ChatDatabase unit-test fixture
consumed_dependencies:
  - Moon Five User Access OIDC
  - macOS Keychain
  - macOS loopback networking and system browser
provided_interfaces:
  - AuthenticationController state machine
  - authenticated-only content policy
related_slices:
  - oidc-login
  - signin-listener-bind
acceptance_criteria:
  - startup validates or refreshes stored credentials before revealing application content
  - unauthenticated, checking, failed, cancelled, and authenticating states expose no cached history or sync records
  - legacy diagnostic exports containing conversation identifiers or message bodies are removed while locked and no longer generated
  - normal polling and user navigation start only after authentication succeeds
  - login is explicit and cancellation, timeout, invalid callback, and exchange failures are clear
  - browser success is sent only after token exchange and persistence complete
  - Developer ID builds read tokens from the legacy-keychain fallback and sign-out removes both keychain variants
  - sign-out closes the privacy gate before Keychain cleanup and stale concurrent validations cannot reopen it
  - authenticated status remains visible throughout normal application use
  - production call sites must explicitly supply OIDC authentication and never fall back to legacy API keys while signed out
test_ownership:
  - MFSyncedTests/AuthenticationControllerTests.swift
  - MFSyncedTests/AuthServiceTests.swift
  - MFSyncedTests/ChatDatabaseTests.swift
open_decisions: []
```

## Human validation

Prerequisites: a Developer ID-signed build, a Moon Five account authorized for
the Phone Sync OIDC client, and an existing `/Applications/Phone Sync.app`
installation whose Full Disk Access grant can be retained through the stable
Developer ID signature.

Validate that launch initially shows only the authentication gate; no
conversation, message, cached sync-contact, or Settings content may flash.
Exercise sign-in cancellation and a failed/invalid callback, then complete a
real browser sign-in. The callback page must not claim success before token
persistence, the main UI must appear only after success, and its authenticated
banner must remain visible. Sign out and confirm the sensitive UI disappears
immediately and polling stops.

Known limitation: the loopback socket and system-browser interaction require
manual validation on macOS; unit tests cover the callback parser, auth state
policy, token exchange/persistence ordering, and failure presentation.

ChatDatabase unit tests use a minimal synthetic SQLite database in a unique
temporary directory. They never open `~/Library/Messages/chat.db`, inspect real
message history, or require Full Disk Access, keeping automated validation
deterministic and free of user message data.

The locked startup path also removes the prior `mfsynced_messages.txt`,
`mfsynced_conversations.txt`, and `mfsynced_crm.log` diagnostic exports. The
app no longer creates message-body or conversation-list dumps.

## Validation record (2026-08-25)

- Focused OIDC, startup-gate, Keychain, privacy, and synthetic-database suite: 65 tests
  passed with zero failures.
- Full Swift suite: 209 tests passed with zero failures.
- Release-mode universal Swift build: passed with zero compiler warnings.
- `git diff --check`: passed.
- `detect-secrets` on every changed/new file: findings were limited to the
  published RFC 7636 PKCE test vector and literal `"test"` values in synthetic
  legacy-compatibility fixtures; no credential material was found.
- The repository has no system-map generator or Swift lint configuration. Its
  configured frontend ESLint and Python Ruff checks currently fail in untouched
  web files; no web files are part of this slice.

- The universal release build passed for arm64 and x86_64. The local validation
  artifact is Developer-ID signed with Team ID `22JUPH2P34`, bundle ID
  `tech.moonfive.MFSynced`, and version `1.3`. The `PhoneSync-1.3.zip` SHA-256
  is `6ca8dc1c05db1957bdeada212c2fed65ed60fb9767540c2db0a45b74b8dd739a`
  and its size is 1,770,393 bytes.
- The previously installed 1.3 validation app was closed and preserved at
  `/Users/stephan/Library/Application Support/Moon Five/Phone Sync Backups/Phone Sync 1.3 pre-opus-final (2026-08-25).app`.
  The installed validation build is `/Applications/Phone Sync.app`.
- The first live sign-in exposed a Developer-ID keychain routing defect: token
  persistence fell back to the legacy login keychain, while the next read saw
  `errSecItemNotFound` in the preferred data-protection keychain and incorrectly
  reported signed out. `KeychainTokenStore` now checks the legacy keychain after
  a preferred-keychain miss and clears both variants during sign-out.
- After rebuilding and reinstalling, the persisted session restored correctly,
  the authenticated indicator and normal application shell appeared, sign-out
  immediately replaced the entire sensitive tree with the authentication-only
  gate, and the OIDC keychain item was absent. A fresh explicit browser sign-in
  then completed and restored authenticated application access.
- A final concurrency review found and fixed a sign-out race: a validation
  suspended before sign-out could previously publish stale success afterward.
  Authentication operations are now versioned, the gate closes before
  credential cleanup begins, cleanup errors remain privacy-closed and visible,
  and deterministic tests cover both delayed revalidation and blocked cleanup.
- Independent Claude Opus review then found a lower-level credential race:
  an in-flight refresh or code exchange could finish after sign-out and write
  tokens back. AuthService now versions credential operations, cancels refresh
  work, checks the epoch before and after persistence, and protects a newer
  session from a late old 401. The same pass centralized cross-window sign-in
  cancellation, canceled poll/control/delivery tasks on lock, main-actor
  isolated local-data providers, made diagnostics privacy-aware and purgeable,
  and added five deterministic dual-Keychain routing/error tests.
- Cancellation, timeout, denial, invalid-state callback, exchange failure, and
  persistence-before-browser-success ordering remain covered by deterministic
  tests. The existing browser session completed live authorization too quickly
  to exercise the on-screen cancel button manually.
- Five independent Claude Opus passes used the repository's saved pre-PR
  criteria. Every P2/P3 finding was fixed and re-reviewed; the terminal pass
  reported no actionable findings and declared the complete diff clean for PR.
- Final installed-app validation targeted the exact
  `/Applications/Phone Sync.app`: startup restored a validated session and
  showed the persistent authenticated indicator; sign-out replaced the full
  conversation shell with the authentication-only gate, hid all history, and
  removed the OIDC Keychain item; a fresh browser authorization then displayed
  its success page only after secure session persistence and restored the
  authenticated conversation shell without an auth failure.

The documented notarized release and `apps.moonfive.tech` publication remain
blocked because `MFSynced/.notary.env` is absent, the required App Store Connect
environment variables are unset, and no `AuthKey_*.p8` file is present on this
Mac. The Developer ID signing identity is available. The installed validation
build intentionally used the documented `--skip-notarize` path; no artifact was
published or represented as notarized.
