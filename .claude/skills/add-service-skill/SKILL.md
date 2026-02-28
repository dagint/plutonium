---
name: add-service
description: Add a new Docker service to this VPS setup with proper Authentik SSO integration, nginx proxy config, deployment pipeline support, and backup coverage. Use this skill whenever the user wants to add a new service, container, or app to the VPS. Also trigger when the user says "add <service>", "deploy <service> to the VPS", "set up <service>", or asks about running a new Docker container on the server. This skill covers all 7 required touch points — missing any one of them is the most common cause of incomplete service additions.
---

# Add New VPS Service

Add a new Docker service to the VPS with all required integration points. There are 7 touch points that must all be covered for a service to be fully functional, deployed, and maintainable.

## Before You Start: Gather These Details

| Detail | Where to Find It | Example |
|--------|-----------------|---------|
| **Docker image** | Docker Hub / ghcr.io | `louislam/uptime-kuma:1` |
| **Container name** | You choose (kebab-case) | `uptime-kuma` |
| **Internal port** | Image documentation | `3001` |
| **Subdomain** | User preference | `uptime` → `uptime.dagint.com` |
| **Authentik protection?** | Security requirement | Yes (most services) |
| **Data dir(s)** | Image docs (volumes) | `/app/data` |
| **Container UID** | Image docs or `docker run --rm <image> id` | `1000` (node user) |
| **s6-overlay?** | Does image use LSIO/s6-overlay base? | No → uptime-kuma is node |

The container UID matters for backup strategy — see Touch Point 7 below.

## The 7 Touch Points

### 1. Docker Compose (`docker/<service>/docker-compose.yml`)

Create the container definition. Use the template from `references/compose-template.md`. Key decisions:

- **s6-overlay containers** (LSIO images like linuxserver/*): add `cap_add: [CHOWN, SETUID, SETGID]` — they start as root, chown the data dir, then drop to app user. Do NOT pre-create data dirs owned by flux-deploy.
- **Direct-run containers** (most non-LSIO images): start as fixed internal UID. Use `chmod 777` on data dirs so the container can write regardless of UID mismatch. Or pre-create dirs owned by the container's UID if known.
- **Port exposure**: never expose ports on the host (no `ports:` mapping). Services communicate via the `proxy` Docker network.

### 2. Deploy Script (`docker/<service>/deploy-services.sh`)

Create the directory setup script. Called by `deploy-remote.sh` before `docker compose up`. Responsible for:
- Creating data directories (`mkdir -p`)
- Setting ownership/permissions appropriate for the container UID
- `docker compose pull`
- `docker compose up -d --no-start` (optional pre-pull)

See `references/compose-template.md` for the deploy-services.sh template.

### 3. Nginx Proxy Config (`services/vps/<service>.subdomain.conf`)

Create the SWAG proxy config. Use the `swag-proxy-config` skill for detailed templates and rules.

Quick pattern:
```nginx
server {
    listen 443 ssl; listen [::]:443 ssl; http2 on;
    server_name <service>.*;
    include /config/nginx/ssl.conf;
    include /config/nginx/proxy.conf;
    include /config/nginx/authentik-server.conf;  # if auth enabled

    location / {
        include /config/nginx/authentik-location.conf;  # if auth enabled
        include /config/nginx/resolver.conf;
        set $upstream_app <container-name>;
        set $upstream_port <port>;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;
    }
}
```

### 4. Deploy Pipeline (`scripts/deploy-remote.sh`)

Add a deploy block for the new service. Pattern — add after the last service block (before the permissions fix section):

```bash
# Deploy <Service Name>
if [ -d "$DOCKER_DIR/<service>" ]; then
    echo -e "${YELLOW}  Deploying <Service Name>...${NC}"
    if [ -f "$DOCKER_DIR/<service>/deploy-services.sh" ]; then
        $CMD_PREFIX bash -c "cd '$DOCKER_DIR/<service>' && export PUID='$DEPLOY_UID' && export PGID='$DEPLOY_GID' && ./deploy-services.sh"
    fi
    $CMD_PREFIX bash -c "cd '$DOCKER_DIR/<service>' && docker compose up -d --remove-orphans"
    echo -e "${GREEN}  ✓ <Service Name> deployed${NC}"
fi
```

### 5. Rsync Excludes (`.github/workflows/deploy.yml`)

Prevent CI/CD from overwriting persistent data on each deploy. Find the rsync `--exclude` block (around line 185) and add:

```yaml
            --exclude 'docker/<service>/data' \
```

Add alongside existing excludes like `--exclude 'docker/bitwarden/data'`. Do this for each data directory the container writes to.

### 6. Authentik SSO (`scripts/configure-authentik.py`)

Add the service to the `SERVICES` list (around line 516):

```python
    ("<Display Name>",  "<slug>",  f"https://<subdomain>.{DOMAIN}",  DOMAIN),
```

The script automatically creates a Proxy Provider, Application, and adds it to the Embedded Outpost. The slug must be unique (kebab-case, matches the service name).

For admin-only services, also add the slug to `ADMIN_ONLY_SLUGS`.

**Skip this step if the service has its own auth** (Vaultwarden, Plex, Jellyseerr).

### 7. Backup (`scripts/backup-vps.sh`)

Two changes:

**a) Add to the compose-files loop** (find the `for stack in swag bitwarden ...` line):
```bash
for stack in swag bitwarden vaultwarden authentik uptime-kuma homarr teslamate <service>; do
```

**b) Add a data backup section** after the other service-specific backup blocks. Use the right function:

- **`backup_container_dir`** — when the container runs as a non-deploy UID (uptime-kuma runs as `node`/1000, authentik as `authentik`). Uses `docker exec tar` so host UID doesn't matter:
  ```bash
  # --- <Service> data ---
  backup_container_dir "<container-name>" "/app/data" "<service>/data" "<Service> data"
  ```

- **`backup_dir`** — when the data dir is owned by `flux-deploy` (UID 1001, which is PUID/PGID for LSIO images):
  ```bash
  # --- <Service> data ---
  backup_dir "$DOCKER_DIR/<service>/data" "<service>/data" "<Service> data"
  ```

For services with a **PostgreSQL database**, add a `pg_dump` step too:
```bash
# --- <Service> database ---
if [ "$DRY_RUN" = false ]; then
    if docker exec <db-container> pg_dump -U <dbuser> <dbname> > "$BACKUP_DIR/<service>/<service>.sql"; then
        gzip "$BACKUP_DIR/<service>/<service>.sql"
        log "<Service> database backup complete"
    else
        warn "<Service> database backup failed"
        BACKUP_ERRORS=$((BACKUP_ERRORS + 1))
    fi
fi
```

## After Adding the Service

1. Run `./scripts/build-proxy-confs.sh` to generate the nginx config
2. Run `./scripts/validate.sh` to check for issues
3. Create a branch: `git checkout -b feat/add-<service>`
4. Commit and push: `git add -A && git commit -m "feat: add <Service> service"`
5. Open PR: `gh pr create`
6. After merge + deploy, run `python3 scripts/configure-authentik.py` on the VPS (or SSH in) to create the Authentik application
7. First visit to `https://<service>.dagint.com` → Authentik login → service

## Common Mistakes

- **Editing `docker/swag/config/nginx/proxy-confs/` directly** — overwritten by `build-proxy-confs.sh`. Always edit `services/vps/` instead.
- **Forgetting the rsync exclude** — CI/CD overwrites the data directory on next deploy, wiping persistent state.
- **Wrong backup function** — using `backup_dir` for a container that doesn't run as UID 1001 results in silent failure (copies nothing, no error in old code; now errors with BACKUP_ERRORS increment in new code).
- **Skipping `configure-authentik.py`** — the service won't appear in Authentik's app list. The nginx config will accept/reject based on Authentik session, but the app isn't registered.
- **Missing WebSocket headers** for services that use Socket.IO/WebSocket (Uptime Kuma, n8n, etc.) — UI loads but real-time features silently fail.
- **s6 container + `cap_drop: ALL` without `cap_add`** — LSIO containers fail to start because they need CHOWN/SETUID/SETGID to drop from root to app user.
