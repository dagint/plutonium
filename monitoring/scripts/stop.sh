#!/usr/bin/env bash
# stop.sh — Gracefully stop the full plutonium stack.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

services=(isponsorblock paperless n8n monitoring)

for svc in "${services[@]}"; do
  dir="${REPO_ROOT}/${svc}"
  if [[ -f "${dir}/docker-compose.yml" ]]; then
    echo "Stopping ${svc}..."
    (cd "${dir}" && docker compose down)
  fi
done

echo "All services stopped."
