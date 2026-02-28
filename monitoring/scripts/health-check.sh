#!/usr/bin/env bash
# health-check.sh — Report health status of all plutonium services.
set -euo pipefail

PASS='\033[0;32m✓\033[0m'
FAIL='\033[0;31m✗\033[0m'

check() {
  local name="$1"
  local url="$2"
  if curl -sf --max-time 5 "${url}" &>/dev/null; then
    echo -e "${PASS} ${name}"
  else
    echo -e "${FAIL} ${name} — ${url}"
  fi
}

# Requires BIND_ADDR to be set (source from .env or pass in environment)
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/../.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/../.env"
fi
: "${BIND_ADDR:?BIND_ADDR not set — source monitoring/.env first}"

echo "=== Monitoring ==="
check "Grafana"    "http://${BIND_ADDR}:3000/api/health"
check "Loki"       "http://${BIND_ADDR}:3100/ready"
check "Prometheus" "http://${BIND_ADDR}:9090/-/healthy"
check "Alloy"      "http://localhost:12345/-/ready"

echo ""
echo "=== Services ==="
check "n8n"             "http://${BIND_ADDR}:5678/healthz"
check "Paperless"       "http://${BIND_ADDR}:8000"
check "iSponsorBlockTV" "http://${BIND_ADDR}:8001"

echo ""
echo "=== Docker container health ==="
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -v NAMES | \
  awk '{
    if ($0 ~ /healthy/) print "\033[0;32m✓\033[0m " $0
    else if ($0 ~ /unhealthy/) print "\033[0;31m✗\033[0m " $0
    else print "  " $0
  }'
