#!/usr/bin/env bash
# Sync the root .env file to GitHub Actions secrets.
# Each KEY=value pair in .env is set as a GitHub secret KEY.
#
# Prerequisites: gh CLI authenticated (gh auth status)
# Usage: ./scripts/sync-env-to-gh.sh [--env-file /path/to/.env] [--dry-run]

set -euo pipefail

REPO="dagint/plutonium"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! gh auth status --hostname github.com &>/dev/null; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example to .env and fill in values." >&2
  exit 1
fi

echo "Syncing $ENV_FILE → GitHub secrets for $REPO"
$DRY_RUN && echo "(dry-run mode — no changes will be made)"
echo ""

while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip blank lines and comments
  [[ -z "${line// }" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  key="${line%%=*}"
  value="${line#*=}"

  # Skip keys with empty values
  if [[ -z "$value" ]]; then
    echo "  SKIP $key (empty value)"
    continue
  fi

  if $DRY_RUN; then
    echo "  [dry-run] would set: $key"
  else
    echo "  Setting $key"
    gh secret set "$key" --body "$value" --repo "$REPO"
  fi
done < "$ENV_FILE"

echo ""
echo "Done."
