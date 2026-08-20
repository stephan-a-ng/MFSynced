# Releasing the Mac app (MFSynced.app)

`MFSynced/build-release.sh` produces a Developer-ID-signed, notarized,
stapled `MFSynced.app` plus a distributable zip in `MFSynced/dist/`.
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

1. Unzip `MFSynced-<version>.zip`, drag `MFSynced.app` to `/Applications`.
2. **Full Disk Access**: System Settings → Privacy & Security → Full Disk
   Access → add MFSynced. Required — the app reads the Messages database
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
