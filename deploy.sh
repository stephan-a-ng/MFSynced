#!/bin/bash
set -euo pipefail

# =============================================================================
# Unified deploy script for MFSynced (backend + frontend) on Cloud Run.
# Mirrors the deploy/crm house pattern: pre-deploy gate -> gcloud run deploy
# --source (backend) / cloudbuild.yaml + gcloud run deploy --image (frontend)
# -> smoke checks. staging and production are the SAME GCP project
# (moonfive-crm), separated by service name + Cloud SQL DB + Secret Manager
# secret + env vars — not by project.
#
# Usage:
#   ./deploy.sh <staging|production> [backend|frontend|all]
#
# IMPORTANT: This is the ONLY supported way to deploy. Do NOT run raw
# `gcloud run deploy --source .` / `gcloud builds submit` by hand — this
# script computes CORS_ORIGINS, wires the user-access OIDC env vars, and
# preserves BACKEND_URL/BACKEND_HOST on the frontend (server-side proxy).
# Skipping it risks shipping a backend that 401s the frontend's own origin,
# or a frontend nginx proxy pointed at nothing.
#
# NEVER --set-env-vars: it replaces the ENTIRE env var list on the service,
# silently wiping anything set out-of-band (e.g. by a one-off `gcloud run
# services update`). Always --update-env-vars.
# =============================================================================

ENV="${1:-}"
SERVICE="${2:-all}"

if [[ "$ENV" != "staging" && "$ENV" != "production" ]]; then
  echo "Usage: ./deploy.sh <staging|production> [backend|frontend|all]" >&2
  exit 1
fi
if [[ "$SERVICE" != "backend" && "$SERVICE" != "frontend" && "$SERVICE" != "all" ]]; then
  echo "Usage: ./deploy.sh <staging|production> [backend|frontend|all]" >&2
  exit 1
fi

PROJECT="moonfive-crm"
REGION="us-central1"
SQL_INSTANCE="moonfive-crm:us-central1:crm-db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script is expected to live at the repo root (alongside web/). If you
# copied it somewhere else, REPO_ROOT will be wrong — fix the assumption
# below rather than hardcoding a path.
REPO_ROOT="$SCRIPT_DIR"
BACKEND_DIR="$REPO_ROOT/web/backend"
FRONTEND_DIR="$REPO_ROOT/web/frontend"

BACKEND_SVC="mfsynced-api-${ENV}"
FRONTEND_SVC="mfsynced-dashboard-${ENV}"

# Cloud Run's canonical URL form for these services (confirmed via
# `gcloud run services describe` on both dashboard services 2026-08-11):
# <svc>-329274314764.us-central1.run.app. Used for CORS + the frontend's
# BACKEND_URL/BACKEND_HOST proxy target.
PROJECT_NUMBER="329274314764"
BACKEND_URL="https://${BACKEND_SVC}-${PROJECT_NUMBER}.${REGION}.run.app"
BACKEND_HOST="${BACKEND_SVC}-${PROJECT_NUMBER}.${REGION}.run.app"
FRONTEND_URL="https://${FRONTEND_SVC}-${PROJECT_NUMBER}.${REGION}.run.app"

# ---------------------------------------------------------------------------
# user-access OIDC wiring (PR #2 cutover). Values per the confirmed pattern:
# issuer = the user-access-api Cloud Run URL for this env, jwks = issuer +
# /.well-known/jwks.json, audience = message-<env> (the mfsynced OIDC client
# id in user-access — NOT the service name; "message" is mfsynced's
# registered client_id prefix). If user-access ever gets a custom domain,
# this issuer must switch with it (see deploy/deploy.sh's UA_ISSUER handling
# for the pattern) or tokens will fail iss/aud validation.
# ---------------------------------------------------------------------------
# 537479330777 = the user-access GCP project (distinct from moonfive-crm's
# 329274314764) — confirmed against user-access/docs/INTEGRATION.md's per-env
# base-URL table, which lists these exact issuer URLs.
USER_ACCESS_ISSUER="https://user-access-api-${ENV}-537479330777.us-central1.run.app"
USER_ACCESS_JWKS_URL="${USER_ACCESS_ISSUER}/.well-known/jwks.json"
USER_ACCESS_AUDIENCE="message-${ENV}"

# ---------------------------------------------------------------------------
# CORS_ORIGINS — computed per env, NOT hand-set (a manual console edit does
# not survive the next deploy; this is the one place it's derived).
#   staging:    the two staging dashboard Cloud Run URLs (run.app has no
#               staging custom domain yet, so both browsing surfaces get
#               listed for safety even though today they're the same host —
#               keeps this block stable if a staging alias ever appears).
#   production: https://message.moonfive.tech (future custom domain — listed
#               NOW so CORS doesn't need a follow-up deploy the day DNS/domain
#               mapping goes live) + the prod dashboard Cloud Run URL.
# ---------------------------------------------------------------------------
case "$ENV" in
  staging)
    # No staging custom domain exists yet, so this is just the one dashboard
    # URL today. Kept as a case arm (not a bare default) so adding a staging
    # alias later is a one-line change here, mirroring the production arm.
    CORS_ORIGINS="${FRONTEND_URL}"
    ;;
  production)
    CORS_ORIGINS="https://message.moonfive.tech,${FRONTEND_URL}"
    ;;
esac

# ---------------------------------------------------------------------------
# Pre-deploy gates
# ---------------------------------------------------------------------------
if [[ "$SERVICE" == "backend" || "$SERVICE" == "all" ]]; then
  echo "==> Pre-deploy: backend tests..."
  (cd "$BACKEND_DIR" && python3 -m pytest tests/ -q) || {
    echo "ABORT: backend tests failed. Fix before deploying." >&2
    exit 1
  }
fi
if [[ "$SERVICE" == "frontend" || "$SERVICE" == "all" ]]; then
  echo "==> Pre-deploy: frontend build..."
  # Fresh checkouts/worktrees have no node_modules — install before building.
  [[ -d "$FRONTEND_DIR/node_modules" ]] || (cd "$FRONTEND_DIR" && npm ci)
  (cd "$FRONTEND_DIR" && npm run build) || {
    echo "ABORT: frontend build failed." >&2
    exit 1
  }
fi

# ---------------------------------------------------------------------------
# Deploy backend
# ---------------------------------------------------------------------------
# Apply pending DB migrations BEFORE the new revision serves traffic — the
# app hard-depends on its migrations (e.g. 005 users.user_access_sub is read
# by the auth dependency on every request). The DSN in Secret Manager uses
# the /cloudsql/ unix-socket form, so from a workstation we front it with a
# short-lived Cloud SQL Auth Proxy socket. The DSN is never echoed.
run_migrations() {
  if [[ "${SKIP_MIGRATIONS:-0}" == "1" ]]; then
    echo "==> SKIP_MIGRATIONS=1 — NOT applying migrations (deployed code may 500 if any are pending)"
    return 0
  fi
  command -v cloud-sql-proxy >/dev/null 2>&1 || {
    echo "ERROR: cloud-sql-proxy not found (brew install cloud-sql-proxy)," >&2
    echo "       or rerun with SKIP_MIGRATIONS=1 after applying migrations another way." >&2
    exit 1
  }

  echo "==> Applying DB migrations for ${ENV}..."
  local dsn socket_dir proxy_pid
  dsn="$(gcloud secrets versions access latest \
          --secret "mfsynced-database-url-${ENV}" --project "$PROJECT")"
  # Short path on purpose: macOS caps AF_UNIX socket paths at ~104 chars, and
  # the proxy appends "/<project:region:instance>/.s.PGSQL.5432" to this dir —
  # mktemp's default /var/folders/... prefix overflows that.
  socket_dir="$(mktemp -d /tmp/csql.XXXXXX)"
  cloud-sql-proxy --unix-socket "$socket_dir" "$SQL_INSTANCE" \
    >/dev/null 2>&1 &
  proxy_pid=$!
  # shellcheck disable=SC2064  # expand now: values are fixed at trap time
  trap "kill ${proxy_pid} 2>/dev/null || true; rm -rf '${socket_dir}'" RETURN
  for _ in $(seq 1 20); do
    [[ -S "${socket_dir}/${SQL_INSTANCE}/.s.PGSQL.5432" || -S "${socket_dir}/${SQL_INSTANCE}" ]] && break
    sleep 0.5
  done

  # Point the DSN's host= at the local proxy socket dir instead of /cloudsql.
  local local_dsn="${dsn/\/cloudsql/${socket_dir}}"
  DATABASE_URL="$local_dsn" python3 "$BACKEND_DIR/scripts/migrate.py" || {
    echo "ERROR: migrations failed — aborting deploy." >&2
    exit 1
  }
}

deploy_backend() {
  local min_instances=0
  [[ "$ENV" == "production" ]] && min_instances=1

  run_migrations

  echo "==> Deploying ${BACKEND_SVC}..."
  echo "    APP_ENV=${ENV}  CORS_ORIGINS=${CORS_ORIGINS}"
  echo "    USER_ACCESS_ISSUER=${USER_ACCESS_ISSUER}  USER_ACCESS_AUDIENCE=${USER_ACCESS_AUDIENCE}"

  # USER_ACCESS_OPERATOR_AUDIENCES is optional — only pass it through if the
  # caller set it in their shell env (not a secret; a comma-joined allowlist
  # of extra audiences for operator-tooling tokens). Left unset here by
  # default so a bare `./deploy.sh <env> backend` doesn't silently widen it.
  local env_vars="APP_ENV=${ENV}"
  env_vars="${env_vars}@CORS_ORIGINS=${CORS_ORIGINS}"
  env_vars="${env_vars}@USER_ACCESS_ISSUER=${USER_ACCESS_ISSUER}"
  env_vars="${env_vars}@USER_ACCESS_JWKS_URL=${USER_ACCESS_JWKS_URL}"
  env_vars="${env_vars}@USER_ACCESS_AUDIENCE=${USER_ACCESS_AUDIENCE}"
  if [[ -n "${USER_ACCESS_OPERATOR_AUDIENCES:-}" ]]; then
    env_vars="${env_vars}@USER_ACCESS_OPERATOR_AUDIENCES=${USER_ACCESS_OPERATOR_AUDIENCES}"
    echo "    USER_ACCESS_OPERATOR_AUDIENCES=${USER_ACCESS_OPERATOR_AUDIENCES}"
  fi

  # DATABASE_URL is the only secret post-cutover: this branch (stacked on
  # the OIDC PR) deletes JWT_SECRET from config entirely, so the legacy
  # mfsynced-jwt-secret-<env> mount is gone with it.
  local secrets="DATABASE_URL=mfsynced-database-url-${ENV}:latest"

  (cd "$BACKEND_DIR" && gcloud run deploy "$BACKEND_SVC" \
    --source . \
    --project "$PROJECT" \
    --region "$REGION" \
    --platform managed \
    --allow-unauthenticated \
    --port 8080 \
    --add-cloudsql-instances "$SQL_INSTANCE" \
    --update-env-vars "^@^${env_vars}" \
    --update-secrets "$secrets" \
    --min-instances "$min_instances" \
    --max-instances 10 \
    --quiet)
  echo "==> Backend deployed: ${BACKEND_SVC}"
}

# ---------------------------------------------------------------------------
# Deploy frontend
#
# VITE_API_URL and VITE_GOOGLE_CLIENT_ID were the two build args baked at
# image-build time (per the existing cloudbuild.yaml + Dockerfile ARGs).
# VITE_GOOGLE_CLIENT_ID is DROPPED here — it was the direct-Google-OAuth
# client id, retired by the user-access OIDC cutover (PR #2); the frontend's
# LoginPage.tsx moves to user-access's hosted login flow, which needs no
# client id baked into the SPA bundle (user-access owns that redirect).
# VITE_API_URL IS consumed (src/api/client.ts, src/components/MessageBubble.tsx)
# but both default to '' when unset, which resolves to same-origin requests
# ("/v1/...", relative). That's the CORRECT value here: the SPA is served by
# nginx, which proxies /v1 and /ws to $BACKEND_URL same-origin (nginx.conf) —
# unlike deploy/crm's frontends, which bake an absolute cross-origin API URL.
# So VITE_API_URL is deliberately left unset/empty below; do not "fix" this
# by wiring an absolute URL, it would just duplicate what the proxy already
# does and diverge from the nginx.conf contract.
#
# BACKEND_URL / BACKEND_HOST are RUNTIME env vars (not build args) — nginx's
# templates/default.conf.template does envsubst at container start
# (confirmed via `gcloud run services describe mfsynced-dashboard-<env>`:
# both dashboards already carry BACKEND_URL/BACKEND_HOST as plain env vars,
# not secrets). Get this wrong (e.g. pass as --build-arg) and the proxy
# silently serves the literal string "${BACKEND_URL}" to nginx.
# ---------------------------------------------------------------------------
deploy_frontend() {
  local image="gcr.io/${PROJECT}/${FRONTEND_SVC}"

  # cloudbuild.yaml on this branch (post-OIDC-cutover) takes only _IMAGE —
  # the _VITE_GOOGLE_CLIENT_ID build arg was retired with Google OAuth.
  echo "==> Building ${FRONTEND_SVC} via cloudbuild.yaml..."
  gcloud builds submit "$FRONTEND_DIR" \
    --config "$FRONTEND_DIR/cloudbuild.yaml" \
    --substitutions "_IMAGE=${image}" \
    --project "$PROJECT" \
    --region "$REGION"

  echo "==> Deploying ${FRONTEND_SVC}..."
  gcloud run deploy "$FRONTEND_SVC" \
    --image "$image" \
    --project "$PROJECT" \
    --region "$REGION" \
    --platform managed \
    --allow-unauthenticated \
    --port 8080 \
    --update-env-vars "^@^BACKEND_URL=${BACKEND_URL}@BACKEND_HOST=${BACKEND_HOST}" \
    --max-instances 10 \
    --quiet
  echo "==> Frontend deployed: ${FRONTEND_SVC}"
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
if [[ "$SERVICE" == "backend" || "$SERVICE" == "all" ]]; then deploy_backend; echo; fi
if [[ "$SERVICE" == "frontend" || "$SERVICE" == "all" ]]; then deploy_frontend; echo; fi

# ---------------------------------------------------------------------------
# Post-deploy smoke checks
# ---------------------------------------------------------------------------
echo "==> Smoke checks..."
if [[ "$SERVICE" == "backend" || "$SERVICE" == "all" ]]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' "${BACKEND_URL}/health" || echo "000")"
  if [[ "$code" == "200" ]]; then
    echo "  backend /health: OK (${BACKEND_URL})"
  else
    echo "  backend /health: FAIL (got ${code}) (${BACKEND_URL})" >&2
    exit 1
  fi
fi
if [[ "$SERVICE" == "frontend" || "$SERVICE" == "all" ]]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' "${FRONTEND_URL}/" || echo "000")"
  if [[ "$code" == "200" ]]; then
    echo "  frontend /: OK (${FRONTEND_URL})"
  else
    echo "  frontend /: FAIL (got ${code}) (${FRONTEND_URL})" >&2
    exit 1
  fi
fi

echo "==> Deploy to ${ENV} complete."

# =============================================================================
# ONE-TIME (not run by this script) — prod custom domains.
# message.moonfive.tech (dashboard) + api.message.moonfive.tech (API).
# Print-only: review + run by hand once DNS is ready. Domain mappings emit a
# CNAME/A/AAAA record set that must then be created at the DNS host
# (moonfive.tech is on Squarespace DNS — see reference_moonfive-dns-squarespace
# in project memory) before the mapping goes CERTIFICATE_READY.
#
#   gcloud run domain-mappings create \
#     --service mfsynced-dashboard-production \
#     --domain message.moonfive.tech \
#     --region us-central1 --project moonfive-crm
#
#   gcloud run domain-mappings create \
#     --service mfsynced-api-production \
#     --domain api.message.moonfive.tech \
#     --region us-central1 --project moonfive-crm
#
#   gcloud run domain-mappings describe --domain message.moonfive.tech \
#     --region us-central1 --project moonfive-crm \
#     --format='value(status.resourceRecords)'
#   gcloud run domain-mappings describe --domain api.message.moonfive.tech \
#     --region us-central1 --project moonfive-crm \
#     --format='value(status.resourceRecords)'
#
# After DNS propagates and both mappings are CERTIFICATE_READY:
#   - CORS_ORIGINS above already includes https://message.moonfive.tech for
#     production, so no deploy.sh change is needed once the mapping is live.
#   - USER_ACCESS_ISSUER for mfsynced stays the run.app host unless/until
#     user-access itself gets a custom domain — do not conflate the two.
# =============================================================================
