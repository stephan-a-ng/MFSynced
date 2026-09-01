# MFSynced (Phone Sync) — project instructions

The Mac agent that mirrors iMessage chats/contacts into the Moon Five
message nexus. Swift Package Manager app; package root is `MFSynced/`
(tests: `cd MFSynced && swift test`).

## MANDATORY — releasing / publishing / distributing the app

Full runbook: `docs/release-packaging.md`. The hard rules, verbatim:

- **REL-1 — version source of truth is the portal catalog.** The next
  version number comes from `app/catalog.ts` in the apps-portal repo
  (`/Users/stephan/MoonFive/apps`): read the currently published Phone
  Sync version there and bump it. NEVER pick a version from memory, old
  zips in `dist/`, or fleet notes — they go stale (a 1.2 was once built
  while the portal already served 1.5).
- **REL-2 — build only via `VERSION=<v> ./build-release.sh`** (from
  `MFSynced/`, needs the gitignored `.notary.env`). The build must end
  notarized: `accepted, source=Notarized Developer ID`.
- **REL-3 — artifact location is exact:**
  `gs://moonfive-app-releases/phonesync/releases/<v>/PhoneSync.zip` —
  the object is named `PhoneSync.zip` (unversioned) inside a versioned
  folder.
- **REL-4 — a release is not published until the portal ships it:** bump
  `app/catalog.ts` (version + downloadUrl) and the pins in
  `tests/rendered-html.test.mjs` in the apps repo, then
  `./deploy.sh staging` THEN `./deploy.sh production`. Staging always
  first. Distributing a zip by hand (Slack, drive, bare bucket link)
  is not a release.
- **REL-5 — verify:** unauthenticated
  `curl -sI https://storage.googleapis.com/moonfive-app-releases/phonesync/releases/<v>/PhoneSync.zip`
  returns 200 with the full size, and apps.moonfive.tech lists `<v>`.

The apps-portal repo is LOCAL-ONLY (no git remote); its release commits
land directly on its `main` (background sessions: use a linked worktree).
This repo (MFSynced) changes via branch + PR as normal.

## Code conventions

- One concern per test file (`Tests/MFSyncedTests/<Concern>Tests.swift`).
- Contact-update handling: Apple Contacts (CNContact) matches always take
  precedence over the server phone mirror; phone numbers are NEVER
  written into CNContactStore (owner decision 2026-08-31).
- Deferred review findings go to `docs/known-issues/KI-<nnn>-*.md`.
