#!/usr/bin/env bash
# Split the root .env into per-service .env files under docker/<app>/.
# Run this locally after editing .env, and on every deploy before
# docker compose up.
#
# Usage: ./scripts/generate-env.sh [/path/to/.env]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example to .env and fill in values." >&2
  exit 1
fi

# Load all vars from root .env
declare -A VARS
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "${line// }" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  VARS["$key"]="$value"
done < "$ENV_FILE"

# Write a per-service .env containing only the specified keys
write_env() {
  local service="$1"; shift
  local keys=("$@")
  local out="$ROOT/docker/$service/.env"

  : > "$out"
  for key in "${keys[@]}"; do
    if [[ -v VARS["$key"] ]]; then
      printf '%s=%s\n' "$key" "${VARS[$key]}" >> "$out"
    fi
  done
  echo "  wrote docker/$service/.env (${#keys[@]} vars)"
}

echo "Generating per-service .env files from $ENV_FILE"
echo ""

write_env monitoring \
  BIND_ADDR TS_AUTHKEY_MONITORING \
  GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GRAFANA_ROOT_URL \
  UNIFI_URL UNIFI_USER UNIFI_PASS \
  UNIFI_PROTECT_URL UNIFI_PROTECT_USER UNIFI_PROTECT_PASS \
  PW_HOST PW_PASSWORD PW_EMAIL \
  TEMPEST_STATION_ID TEMPEST_API_TOKEN \
  CLOUDFLARE_API_TOKEN

write_env n8n \
  BIND_ADDR TS_AUTHKEY_N8N TIMEZONE \
  N8N_ENCRYPTION_KEY N8N_HOST WEBHOOK_URL \
  N8N_ADMIN_EMAIL N8N_ADMIN_PASSWORD

write_env paperless \
  BIND_ADDR TS_AUTHKEY_PAPERLESS TIMEZONE \
  PAPERLESS_SECRET_KEY \
  PAPERLESS_ADMIN_USER PAPERLESS_ADMIN_PASSWORD \
  PAPERLESS_URL PAPERLESS_ALLOWED_HOSTS \
  POSTGRES_PASSWORD

write_env isponsorblock \
  BIND_ADDR

write_env silverbullet \
  BIND_ADDR TS_AUTHKEY_SILVERBULLET \
  SB_USER

echo ""
echo "Done. Per-service .env files are gitignored — do not commit them."
