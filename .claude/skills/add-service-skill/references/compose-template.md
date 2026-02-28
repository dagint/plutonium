# Docker Compose Templates for New VPS Services

## Template: Standard Service (No s6-overlay)

For services with a fixed internal UID (most non-LSIO images — Next.js, Node, Python apps):

```yaml
services:
  <service>:
    image: <image>:<tag>
    container_name: <service>
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    networks:
      - proxy
    volumes:
      - ./data:/app/data
    environment:
      - PUID=${PUID:-1001}
      - PGID=${PGID:-1001}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:<port>/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
        reservations:
          cpus: '0.1'
          memory: 128M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    external: true
```

**Data dir setup** (in `deploy-services.sh`):
```bash
mkdir -p data
chmod 777 data          # Container writes as its own UID, not flux-deploy
```

## Template: s6-overlay Service (LSIO Images)

For LinuxServer.io images (`lscr.io/linuxserver/*`) — they use s6-overlay: start as root, chown dirs, drop to PUID/PGID:

```yaml
services:
  <service>:
    image: lscr.io/linuxserver/<service>:latest
    container_name: <service>
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    networks:
      - proxy
    volumes:
      - ./data:/config
    environment:
      - PUID=${PUID:-1001}
      - PGID=${PGID:-1001}
      - TZ=America/New_York
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:<port>/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
        reservations:
          cpus: '0.1'
          memory: 128M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    external: true
```

**Data dir setup** (in `deploy-services.sh`):
```bash
# Let the container create and chown its own data dirs — don't pre-create them
# The s6 init script handles chown based on PUID/PGID
```

## Template: Service with Database

For services that need a PostgreSQL or SQLite database alongside:

```yaml
services:
  <service>-db:
    image: postgres:16-alpine
    container_name: <service>-db
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    networks:
      - <service>-internal
    volumes:
      - ./db:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=${DB_NAME:-<service>}
      - POSTGRES_USER=${DB_USER:-<service>}
      - POSTGRES_PASSWORD=${DB_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-<service>}"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  <service>:
    image: <image>:<tag>
    container_name: <service>
    restart: unless-stopped
    depends_on:
      <service>-db:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    networks:
      - proxy
      - <service>-internal
    environment:
      - DATABASE_URL=postgresql://${DB_USER:-<service>}:${DB_PASSWORD}@<service>-db:5432/${DB_NAME:-<service>}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:<port>/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    external: true
  <service>-internal:
    internal: true
```

## deploy-services.sh Template

```bash
#!/bin/bash
# Deploy script for <service>
# Sets up data directories and pulls the image

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Setting up <service> directories..."
mkdir -p "$SCRIPT_DIR/data"
# chmod 777 "$SCRIPT_DIR/data"   # Uncomment for non-s6 containers with fixed UID

echo "Pulling <service> image..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" pull

echo "<service> setup complete"
```

Make executable: `chmod +x deploy-services.sh`

## Security Notes

- **Never expose container ports on host** (`ports:` mapping) — services communicate via the `proxy` Docker network only
- **`no-new-privileges:true`** — prevents privilege escalation attacks
- **`cap_drop: ALL`** — remove all Linux capabilities (add back only what's needed)
- **s6-overlay containers** need `cap_add: [CHOWN, SETUID, SETGID]` — they drop from root to app user during startup
- **Resource limits** prevent any single container from exhausting host resources
- **`restart: unless-stopped`** — automatically recovers from crashes but respects manual stops
- **Named volumes or relative bind mounts** (`./data`) — never use absolute paths in Compose for portability
