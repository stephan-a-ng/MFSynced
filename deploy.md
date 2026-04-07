# Deployment Guide

## Mac App

The Mac app is built with `swift build` (no Xcode required) via the build script.

```bash
cd MFSynced
bash build-app.sh
```

This compiles the app, assembles the `.app` bundle, and ad-hoc code-signs it.

**Install and launch:**
```bash
cp -r MFSynced.app /Applications/
open /Applications/MFSynced.app
```

**After every rebuild:** The ad-hoc re-signing revokes Full Disk Access.
Go to **System Settings → Privacy & Security → Full Disk Access** and re-enable MFSynced.

---

## Backend API (staging + production)

Build and push image via Cloud Build, then deploy to Cloud Run.

```bash
# Staging
gcloud builds submit web/backend \
  --tag gcr.io/moonfive-crm/mfsynced-api-staging \
  --region=us-central1

gcloud run deploy mfsynced-api-staging \
  --image gcr.io/moonfive-crm/mfsynced-api-staging \
  --region us-central1

# Production
gcloud builds submit web/backend \
  --tag gcr.io/moonfive-crm/mfsynced-api-production \
  --region=us-central1

gcloud run deploy mfsynced-api-production \
  --image gcr.io/moonfive-crm/mfsynced-api-production \
  --region us-central1
```

---

## Frontend Dashboard (staging + production)

Requires `VITE_GOOGLE_CLIENT_ID` as a build arg.

```bash
VITE_GOOGLE_CLIENT_ID="329274314764-8t91qgbto6e8q1r2obair6nvagdat451.apps.googleusercontent.com"

# Staging
gcloud builds submit web/frontend \
  --config web/frontend/cloudbuild.yaml \
  --substitutions "_IMAGE=gcr.io/moonfive-crm/mfsynced-dashboard-staging,_VITE_GOOGLE_CLIENT_ID=$VITE_GOOGLE_CLIENT_ID" \
  --region=us-central1

gcloud run deploy mfsynced-dashboard-staging \
  --image gcr.io/moonfive-crm/mfsynced-dashboard-staging \
  --region us-central1

# Production
gcloud builds submit web/frontend \
  --config web/frontend/cloudbuild.yaml \
  --substitutions "_IMAGE=gcr.io/moonfive-crm/mfsynced-dashboard-production,_VITE_GOOGLE_CLIENT_ID=$VITE_GOOGLE_CLIENT_ID" \
  --region=us-central1

gcloud run deploy mfsynced-dashboard-production \
  --image gcr.io/moonfive-crm/mfsynced-dashboard-production \
  --region us-central1
```

---

## Service URLs

| Service | URL |
|---|---|
| API (production) | https://mfsynced-api-production-329274314764.us-central1.run.app |
| API (staging) | https://mfsynced-api-staging-329274314764.us-central1.run.app |
| Dashboard (production) | https://mfsynced-dashboard-production-329274314764.us-central1.run.app |
| Dashboard (staging) | https://mfsynced-dashboard-staging-329274314764.us-central1.run.app |
