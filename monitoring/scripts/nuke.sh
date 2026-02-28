#!/usr/bin/env bash
# nuke.sh — Stop and remove ALL Docker resources on this host.
# DESTRUCTIVE. Confirm before running.
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}WARNING: This will destroy ALL Docker containers, volumes, and networks on this host.${NC}"
echo -e "${YELLOW}This includes data in Grafana, Loki, Prometheus, n8n, Paperless, and all other containers.${NC}"
echo ""
read -r -p "Type YES to continue: " confirm

if [[ "${confirm}" != "YES" ]]; then
  echo "Aborted."
  exit 0
fi

echo "Stopping all containers..."
docker ps -q | xargs -r docker stop

echo "Removing all containers..."
docker ps -aq | xargs -r docker rm

echo "Removing all volumes..."
docker volume ls -q | xargs -r docker volume rm

echo "Removing custom networks..."
docker network ls --filter type=custom -q | xargs -r docker network rm

echo "Pruning system..."
docker system prune -af --volumes

echo "Done. Host is clean."
