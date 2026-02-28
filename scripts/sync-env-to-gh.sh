#!/usr/bin/env bash
# Sync per-service .env files to GitHub Actions secrets.
#
# Reads each docker/<service>/.env and sets secrets prefixed by service:
#   docker/monitoring/.env  → MONITORING_<KEY>
#   docker/n8n/.env         → N8N_<KEY>
#   docker/paperless/.env   → PAPERLESS_<KEY>
#   docker/isponsorblock/.env → ISPONSORBLOCK_<KEY>
#
# Prerequisites: gh CLI authenticated (gh auth status)
# Usage: ./scripts/sync-env-to-gh.sh [--dry-run]

set -euo pipefail

REPO="dagint/plutonium"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if ! gh auth status --hostname github.com &>/dev/null; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

sync_env() {
  local service="$1"
  local env_file="$2"
  local prefix="$3"

  if [[ ! -f "$env_file" ]]; then
    echo "  SKIP $service: $env_file not found"
    return
  fi

  echo "==> $service"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    key="${line%%=*}"
    value="${line#*=}"

    if [[ -z "$value" ]]; then
      echo "  SKIP $key (empty value)"
      continue
    fi

    secret_name="${prefix}${key}"

    if $DRY_RUN; then
      echo "  [dry-run] would set: $secret_name"
    else
      echo "  Setting $secret_name"
      gh secret set "$secret_name" --body "$value" --repo "$REPO"
    fi
  done < "$env_file"
}

echo "Syncing .env files → GitHub secrets for $REPO"
$DRY_RUN && echo "(dry-run mode — no changes will be made)"
echo ""

sync_env "monitoring"    "$ROOT/docker/monitoring/.env"    "MONITORING_"
sync_env "n8n"           "$ROOT/docker/n8n/.env"           "N8N_"
sync_env "paperless"     "$ROOT/docker/paperless/.env"     "PAPERLESS_"
sync_env "isponsorblock" "$ROOT/docker/isponsorblock/.env" "ISPONSORBLOCK_"

echo ""
echo "Done."
