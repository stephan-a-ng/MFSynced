# Releasing the Mac app (Phone Sync.app)

`MFSynced/build-release.sh` produces a Developer-ID-signed, notarized,
stapled `Phone Sync.app` plus a distributable zip in `MFSynced/dist/`.
The result runs on any Mac (macOS 14+, Apple Silicon or Intel) with no
Gatekeeper warnings — no Xcode or source checkout needed on the target.

```bash
cd MFSynced
./build-release.sh                  # build + sign + notarize + staple
./build-release.sh --skip-notarize  # local test build (signed, not notarized)
VERSION=1.1 ./build-release.sh      # stamp a version
```

## One-time setup (build Mac)

1. **Developer ID Application certificate** in the login keychain.
   Only the Apple Developer **Account Holder** can create it:
   Xcode → Settings → Accounts → Manage Certificates → **+** →
   *Developer ID Application*. (The App Store Connect API refuses this
   operation for non-Account-Holder keys — verified 2026-08-19.)
2. **Notary credentials** in `MFSynced/.notary.env` (gitignored):

   ```bash
   ASC_KEY_ID=XXXXXXXXXX
   ASC_ISSUER_ID=<issuer uuid>
   ASC_KEY_FILEPATH=~/.appstoreconnect/AuthKey_XXXXXXXXXX.p8
   ```

   Any App Store Connect API key with the Developer role works for
   notarization.

## Installing on a target Mac

1. Unzip `PhoneSync-<version>.zip`, drag `Phone Sync.app` to `/Applications`.
2. **Full Disk Access**: System Settings → Privacy & Security → Full Disk
   Access → add Phone Sync. Required — the app reads the Messages database
   (`~/Library/Messages/chat.db`). No packaging can bypass this; it is a
   per-machine grant.
3. **Contacts** and **Automation → Messages**: approve the prompts on first
   run (contact names/photos, and sending iMessages via Messages.app).
4. Point the app at the nexus in its setup screen (API endpoint is
   user-configured, not baked into the build).

Because the app is Developer-ID signed (stable signing identity), TCC
grants like Full Disk Access survive app updates — unlike the old ad-hoc
`build-app.sh` builds, where every rebuild changed the signature.

`build-app.sh` (ad-hoc, debug) remains the fast local dev loop; it is not
for distribution.

## Publishing to apps.moonfive.tech (distribution)

A built zip is not a release until the Moon Five app portal serves it.
The portal repo is `/Users/stephan/MoonFive/apps` (LOCAL-ONLY git, no
remote — its release commits land directly on its `main`; background
sessions edit via a linked worktree).

Rules (cited as REL-1 … REL-5; also inlined in this repo's CLAUDE.md):

1. **REL-1 — version source of truth.** Read the currently published
   version from `app/catalog.ts` in the apps repo and bump it. Never
   trust memory, fleet notes, or old zips in `dist/` — the portal
   catalog is the only authority (a 1.2 was once built while the portal
   already served 1.5; it had to be rebuilt as 1.6).
2. **REL-2 — build.** `cd MFSynced && VERSION=<v> ./build-release.sh`
   (see the setup sections above). Confirm notarization: `accepted,
   source=Notarized Developer ID`.
3. **REL-3 — upload.**
   `gsutil cp MFSynced/dist/PhoneSync-<v>.zip gs://moonfive-app-releases/phonesync/releases/<v>/PhoneSync.zip`
   — note the object is named `PhoneSync.zip` (unversioned) inside the
   versioned folder. Bucket objects are public.
4. **REL-4 — portal pins + deploy.** In the apps repo bump
   `app/catalog.ts` (both `version:` and `downloadUrl:`) and the pins in
   `tests/rendered-html.test.mjs`. A coupling test there asserts the
   downloadUrl embeds the same version as `version:` — so a missed pin
   fails `npm test` (and the deploy, which runs the tests). Then
   `./deploy.sh staging`, verify, `./deploy.sh production`. Staging
   always first.
5. **REL-5 — verify.** Unauthenticated
   `curl -sI https://storage.googleapis.com/moonfive-app-releases/phonesync/releases/<v>/PhoneSync.zip`
   → 200 with the full byte size, and apps.moonfive.tech lists `<v>`
   with a working "Download for Mac OS".

Installing on a target Mac (drag to /Applications + TCC grants) is
unchanged — see "Installing on a target Mac" above.
