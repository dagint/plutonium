#!/usr/bin/env bash
# start.sh — Bring up the full plutonium stack.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Ensure external network exists
if ! docker network inspect plutonium &>/dev/null; then
  echo "Creating external plutonium network..."
  docker network create plutonium
fi

services=(monitoring n8n paperless isponsorblock)

for svc in "${services[@]}"; do
  dir="${REPO_ROOT}/${svc}"
  if [[ -f "${dir}/docker-compose.yml" ]]; then
    echo "Starting ${svc}..."
    (cd "${dir}" && docker compose up -d)
  fi
done

echo "All services started."
