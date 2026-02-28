#!/usr/bin/env bash
# backup.sh — Restic backup of all critical volumes and configs.
# Requires: restic installed, RESTIC_REPOSITORY and RESTIC_PASSWORD set in environment
#           or via /etc/restic.env (sourced below if present).
set -euo pipefail

LOG_FILE="/var/log/plutonium-backup.log"
TIMESTAMP="$(date +%F_%H-%M)"

log() { echo "[$(date +%F\ %T)] $*" | tee -a "${LOG_FILE}"; }

# Source credentials if present
if [[ -f /etc/restic.env ]]; then
  # shellcheck disable=SC1091
  source /etc/restic.env
fi

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set}"

log "=== Backup started ==="

# ---- Paperless PostgreSQL dump ----
log "Dumping Paperless PostgreSQL..."
docker exec paperless-db pg_dump -U paperless paperless \
  > "/tmp/paperless-pg-${TIMESTAMP}.sql" 2>>"${LOG_FILE}"

# ---- Restic backup ----
log "Running restic backup..."
restic backup \
  /var/lib/docker/volumes/monitoring_grafana_data \
  /var/lib/docker/volumes/monitoring_prometheus_data \
  /var/lib/docker/volumes/monitoring_loki_data \
  /var/lib/docker/volumes/n8n_n8n_data \
  /var/lib/docker/volumes/paperless_media \
  /var/lib/docker/volumes/paperless_data \
  "/tmp/paperless-pg-${TIMESTAMP}.sql" \
  ~/plutonium \
  --exclude="~/plutonium/**/.git" \
  --exclude="~/plutonium/**/.env" \
  2>>"${LOG_FILE}"

# ---- Retention ----
log "Applying retention policy..."
restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune \
  2>>"${LOG_FILE}"

# ---- Cleanup temp files ----
rm -f "/tmp/paperless-pg-${TIMESTAMP}.sql"

log "=== Backup complete ==="
