# CLAUDE.md — Homelab Host: Monitoring + Services

## What This Repo Is

Infrastructure-as-code for a dedicated Ubuntu homelab host running Docker. This repo covers the **centralized observability stack** (Grafana, Loki, Prometheus/Mimir, Alloy). The host also runs co-located application services (n8n, Paperless-ngx, iSponsorBlockTV) managed in separate compose projects on the same machine.

The monitoring stack is being **rebuilt from scratch**. The legacy `monitoring/docker-compose.yml` (Promtail, AlertManager, standalone Prometheus with open ports) is the old state — it is being replaced entirely.

---

## Host Information

| Field | Value |
|-------|-------|
| OS | Ubuntu (dedicated homelab host) |
| Primary role | Centralized monitoring stack |
| Secondary role | Application services (n8n, Paperless, iSponsorBlockTV) |
| IP | TBD (will change — do not hardcode IPs in configs) |
| Repo dir (on host) | `~/plutonium/` |
| Per-service layout | `~/plutonium/docker/<service>/docker-compose.yml` (one folder per service) |
| Tailscale hostname | TBD — set in each service's `.env` |

---

## Architecture

### Stack Components

| Service | Role | Internal Port | Access |
|---------|------|--------------|--------|
| Grafana | Dashboards + alerting UI | 3000 | Tailscale sidecar + LAN |
| Loki | Log ingestion and storage | 3100 | Tailscale sidecar + LAN |
| Prometheus **or** Mimir | Metrics storage (see decision below) | 9090 / 9009 | Tailscale sidecar + LAN |
| Alloy | Local telemetry agent (this host) | 12345 | Internal only |
| UniFi Poller | UniFi Network + Protect metrics | 9130 | Internal only |
| PowerWall Exporter | Tesla Powerwall metrics | 9961 | Internal only |
| Tempest Exporter | WeatherFlow weather station | 6969 | Internal only |
| Cloudflare Exporter | Edge metrics (optional) | 8080 | Internal only |

### Access Model

```
┌──────────────────────────────────────────────────────────────┐
│  Remote Access (Tailscale)                                   │
│                                                              │
│  Monitoring:                                                 │
│    grafana.tailnet.ts.net    → Grafana       :3000           │
│    loki.tailnet.ts.net       → Loki          :3100           │
│    metrics.tailnet.ts.net    → Prom/Mimir    :9090/9009      │
│                                                              │
│  Services:                                                   │
│    n8n.tailnet.ts.net        → n8n           :5678           │
│    paperless.tailnet.ts.net  → Paperless-ngx :8000           │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  Local Access (LAN — UFW restricted to LAN subnet)           │
│                                                              │
│  Monitoring:                                                 │
│    <host-lan-ip>:3000  → Grafana                             │
│    <host-lan-ip>:3100  → Loki (agent push + UI)              │
│    <host-lan-ip>:9090  → Prometheus / Mimir                  │
│                                                              │
│  Services:                                                   │
│    <host-lan-ip>:5678  → n8n                                 │
│    <host-lan-ip>:8000  → Paperless-ngx                       │
│    <host-lan-ip>:8001  → iSponsorBlockTV (LAN only, no TS)   │
└──────────────────────────────────────────────────────────────┘
```

**Tailscale pattern**: Each externally exposed service gets its own Tailscale sidecar container. The service runs with `network_mode: service:ts-<name>`, sharing the sidecar's network namespace. This provides per-service Tailscale hostnames with automatic HTTPS (Tailscale cert provisioning).

**Local access**: Services bind to `<LAN_IP>:<port>:<port>` (set via `BIND_ADDR` in `.env`) and UFW restricts inbound to the LAN subnet.

### Telemetry Sources

```
Remote hosts       → Alloy agent → Tailscale → Loki push + Prometheus remote_write
UniFi (10.80.1.1)  → UniFi Poller → Prometheus scrape
UniFi Protect NVR (10.80.21.97) → UniFi Poller → Prometheus scrape
Tesla Powerwall    → PowerWall Exporter → Prometheus scrape
WeatherFlow Tempest → Tempest Exporter → Prometheus scrape
Cloudflare         → CF Exporter → Prometheus scrape
```

### Cross-Project Docker Networking

Services in different compose projects communicate via an **externally-defined Docker network**. This allows Alloy (in `monitoring/`) to reach containers in other compose projects by name, and keeps all inter-service traffic off the host network interface.

Create the shared network **once on the host** before deploying any stack:

```bash
docker network create plutonium
```

Each compose project that needs cross-project access declares it as external:

```yaml
networks:
  plutonium:
    external: true
```

Alloy joins this network to discover and scrape all containers. Services that don't need cross-project communication use their own internal-only network.

---

## Metrics Backend: Prometheus vs Mimir

| Criteria | Prometheus | Mimir (single-binary) |
|----------|------------|----------------------|
| Complexity | Low | Low-medium |
| Storage compression | Moderate | High (2-3x better) |
| Long-term retention | Practical limit ~1 year | 2+ years easily |
| Remote write target | Yes | Yes (drop-in compatible) |
| Multi-tenancy | No | Yes (can ignore for homelab) |
| Grafana datasource | `Prometheus` type | `Prometheus` type (same API) |
| Config complexity | Simple YAML | Slightly more config |
| Migration path | N/A | Alloy re-targets; keep Prometheus during cutover |

**Default choice**: Start with **Prometheus**. Lower ops overhead suits a single-host homelab. Mimir becomes worth it at 1+ year retention or if storage cost matters.

**To switch to Mimir**: Replace the `prometheus` service with `mimir`, update Alloy's `prometheus.remote_write` endpoint to `http://ts-mimir:9009/api/v1/push`, update Grafana datasource URL. No dashboard changes needed — Mimir exposes an identical query API.

---

## Security Requirements

This project is security-first. Every decision must apply the most secure reasonable option.

### Non-Negotiable Rules

1. **No plaintext secrets in committed files** — `.env` holds all secrets; it is gitignored.
2. **No anonymous access** — Grafana requires authentication (`GF_AUTH_ANONYMOUS_ENABLED=false`).
3. **No open internet exposure** — nothing is reachable from the internet; Tailscale is the only remote path.
4. **Least privilege everywhere** — read-only volume mounts (`:ro`), non-root container users, `cap_drop: [ALL]` with selective adds.
5. **No default passwords** — all passwords are generated 32+ character random strings.
6. **Dedicated service accounts** — UniFi Poller uses a read-only local account in the UniFi controller; never an admin account.
7. **UFW restricts LAN ports** — local service ports are only reachable from the LAN subnet.
8. **SSH key-only** — password authentication is disabled on the host; never re-enable it.

### Container Hardening (apply to every service)

```yaml
security_opt:
  - no-new-privileges:true
read_only: true               # where the image supports it
cap_drop:
  - ALL
cap_add:
  - <only what is specifically required>
user: "65534"                 # nobody — or the image's documented UID
deploy:
  resources:
    limits:
      memory: 512m            # tune per service; prevents one container starving the host
      cpus: "0.5"
logging:
  driver: json-file
  options:
    max-size: "10m"           # prevents verbose containers filling the disk
    max-file: "3"
healthcheck:
  test: ["CMD", "<appropriate check for this service>"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 30s
```

Every container definition must include `deploy.resources.limits`, `logging`, and `healthcheck`. No exceptions.

### Network Isolation

- Monitoring services run on the `monitoring` bridge network (internal to that compose project).
- Services that need cross-project access also join the `plutonium` external network.
- Alloy uses `network_mode: host` (required for Docker socket + host metrics — intentional exception).
- Tailscale sidecars require `cap_add: [NET_ADMIN, SYS_MODULE]` (Tailscale needs tun device).
- No service has `privileged: true`.

### Secrets Management

`.gitignore` for every service folder:

```gitignore
# Secrets
.env
*.key
*.pem
*.p12

# Tailscale state
**/*.state
tailscale/state/

# Runtime data (not config — not committed)
data/
media/

# OS noise
.DS_Store
Thumbs.db
```

Rotate Tailscale auth keys: use reusable keys with expiry. Re-issue from the Tailscale admin panel; update `.env` and restart the sidecar container.

### Tailscale ACL Requirements

In the Tailscale admin console → Access Controls, ensure these are defined:

```json
{
  "tagOwners": {
    "tag:monitoring": ["autogroup:admin"],
    "tag:homelab-host": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["tag:homelab-host"],
      "dst": ["tag:monitoring:3000,3100,9090"]
    }
  ]
}
```

Container sidecars advertise with `TS_EXTRA_ARGS=--advertise-tags=tag:monitoring`.
The host itself advertises with `--advertise-tags=tag:homelab-host`.

---

## Docker Daemon Configuration

Create `/etc/docker/daemon.json` on the host **before** installing or running any containers:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true
}
```

- `live-restore` — containers keep running if the Docker daemon restarts (e.g., during updates)
- `userland-proxy: false` — use iptables directly for port mapping; more secure, less overhead
- `no-new-privileges` — daemon-level enforcement alongside per-container `security_opt`
- `log-opts` — default log limits for any container that doesn't define its own

Apply: `sudo systemctl restart docker`

---

## What Is Being Replaced (Legacy Stack)

The existing `docker/monitoring/docker-compose.yml` represents the OLD state. It is **being fully removed**:

| Old Service | Replacement | Reason |
|-------------|-------------|--------|
| `promtail` | `alloy` | Promtail is deprecated; Alloy is the unified collector |
| `alertmanager` | Grafana built-in alerting | Grafana unified alerting handles routing; Alertmanager adds complexity without benefit at this scale |
| `node_exporter` | `alloy` (`prometheus.exporter.unix`) | Alloy includes a native unix/node exporter |
| Direct port binding (`0.0.0.0:3000`) | LAN-bound ports + Tailscale sidecars | Never expose to all interfaces |

Services to **preserve and migrate**:
- `unpoller` — keep; update config
- `powerwall-exporter` — keep; update config
- `tempest-exporter` — keep; update config

### Nuclear Reset (run on host before deploying new stack)

```bash
docker ps -q | xargs -r docker stop
docker ps -aq | xargs -r docker rm
docker volume ls -q | xargs -r docker volume rm   # DESTRUCTIVE — confirm first
docker network ls --filter type=custom -q | xargs -r docker network rm
docker system prune -af --volumes
```

**Confirm before running**: verify no volumes contain data worth keeping.

---

## Directory Structure

```
~/plutonium/
├── CLAUDE.md
└── docker/
    ├── monitoring/
    │   ├── docker-compose.yml
    │   ├── .env                          # secrets — never commit
    │   ├── .env.example
    │   ├── .gitignore
    │   ├── grafana/
    │   │   ├── provisioning/
    │   │   │   ├── datasources/datasources.yaml
    │   │   │   └── dashboards/
    │   │   │       ├── dashboards.yaml
    │   │   │       └── json/             # dashboard JSON files
    │   │   └── grafana.ini
    │   ├── loki/config.yaml
    │   ├── prometheus/prometheus.yml     # or mimir/mimir.yaml
    │   ├── alloy/
    │   │   ├── config.alloy              # local collector for this host
    │   │   └── remote-agent.alloy        # template for remote hosts
    │   ├── tailscale/
    │   │   ├── grafana.json
    │   │   ├── loki.json
    │   │   └── prometheus.json
    │   ├── unpoller/up.conf
    │   └── scripts/
    │       ├── nuke.sh
    │       ├── start.sh
    │       ├── stop.sh
    │       ├── backup.sh
    │       └── health-check.sh
    ├── n8n/
    │   ├── docker-compose.yml
    │   ├── .env.example
    │   └── .gitignore
    ├── paperless/
    │   ├── docker-compose.yml
    │   ├── .env.example
    │   └── .gitignore
    └── isponsorblock/
        ├── docker-compose.yml
        └── config.json
```

---

## Environment Variables

### Monitoring Stack (`monitoring/.env`)

```bash
# Networking
BIND_ADDR=192.168.x.x

# Tailscale
TS_AUTHKEY=tskey-client-xxxxx

# Grafana
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=           # 32+ char random
GRAFANA_ROOT_URL=https://grafana.<tailnet>.ts.net

# UniFi Poller
UNIFI_URL=https://10.80.1.1
UNIFI_PROTECT_URL=https://10.80.21.97
UNIFI_USER=                       # read-only local account — never the admin account
UNIFI_PASS=
UNIFI_VERIFY_SSL=false            # self-signed cert on controller

# PowerWall
PW_HOST=
PW_PASSWORD=
PW_EMAIL=

# Tempest Weather
TEMPEST_STATION_ID=
TEMPEST_API_TOKEN=

# Cloudflare (optional)
CLOUDFLARE_API_TOKEN=
```

### n8n (`n8n/.env`)

```bash
BIND_ADDR=192.168.x.x
TS_AUTHKEY=tskey-client-xxxxx
N8N_ENCRYPTION_KEY=               # 32+ char random — generate once, NEVER change
N8N_HOST=n8n.<tailnet>.ts.net
WEBHOOK_URL=https://n8n.<tailnet>.ts.net/
N8N_ADMIN_EMAIL=
N8N_ADMIN_PASSWORD=               # 32+ char random
```

### Paperless (`paperless/.env`)

```bash
BIND_ADDR=192.168.x.x
TS_AUTHKEY=tskey-client-xxxxx
PAPERLESS_SECRET_KEY=             # 50+ char random — generate once, NEVER change
PAPERLESS_ADMIN_USER=
PAPERLESS_ADMIN_PASSWORD=         # 32+ char random
PAPERLESS_URL=https://paperless.<tailnet>.ts.net
POSTGRES_PASSWORD=                # 32+ char random
```

---

## Deployment Sequence

### Step 1: Host Hardening (one-time)

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y ufw fail2ban

# SSH — disable password auth, enforce key-only
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd
# IMPORTANT: confirm key-based SSH works in a new session before closing this one

# fail2ban (SSH brute force protection)
sudo systemctl enable --now fail2ban

# Docker daemon config (before installing Docker)
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true
}
EOF

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
sudo systemctl restart docker

# UFW
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
# Monitoring
sudo ufw allow from 192.168.x.0/24 to any port 3000
sudo ufw allow from 192.168.x.0/24 to any port 3100
sudo ufw allow from 192.168.x.0/24 to any port 9090
# Services
sudo ufw allow from 192.168.x.0/24 to any port 5678
sudo ufw allow from 192.168.x.0/24 to any port 8000
sudo ufw allow from 192.168.x.0/24 to any port 8001
sudo ufw enable

# Tailscale (host-level — for SSH access, separate from container sidecars)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-tags=tag:homelab-host

# Shared Docker network (before deploying any stack)
docker network create plutonium
```

### Step 2: Clone and Configure

```bash
git clone <repo> ~/plutonium
cd ~/plutonium/docker/monitoring && cp .env.example .env   # fill in all values
cd ~/plutonium/docker/n8n        && cp .env.example .env
cd ~/plutonium/docker/paperless  && cp .env.example .env
```

### Step 3: Deploy

```bash
cd ~/plutonium/docker/monitoring    && docker compose up -d
cd ~/plutonium/docker/n8n           && docker compose up -d
cd ~/plutonium/docker/paperless     && docker compose up -d
cd ~/plutonium/docker/isponsorblock && docker compose up -d
```

### Step 4: Validate

```bash
docker compose ps                                              # all healthy
curl -s http://${BIND_ADDR}:3000/api/health | python3 -m json.tool  # Grafana
tailscale status                                               # sidecars registered
curl -s http://localhost:12345/-/ready                         # Alloy ready
```

---

## Co-Hosted Application Services

Each application service gets **its own subfolder and its own `docker-compose.yml`**. This is a hard rule — services are never merged into a shared compose file. Independent folders mean independent deployments, restarts, and rollbacks.

### Service Inventory

| Service | Purpose | Port | Access | Dir |
|---------|---------|------|--------|-----|
| n8n | Workflow automation | 5678 | Tailscale + LAN | `docker/n8n/` |
| Paperless-ngx | Document management | 8000 | Tailscale + LAN | `docker/paperless/` |
| iSponsorBlockTV | SponsorBlock proxy for TV devices | 8001 | LAN only | `docker/isponsorblock/` |

### n8n

- **Image**: `n8nio/n8n`
- **Database**: SQLite (adequate for single-user homelab; upgrade to PostgreSQL if needed)
- **Critical env vars**:
  - `N8N_ENCRYPTION_KEY` — generate once before first run; changing it breaks all stored credentials
  - `N8N_ADMIN_EMAIL` + `N8N_ADMIN_PASSWORD` — n8n uses built-in user management (`N8N_BASIC_AUTH_ACTIVE` is deprecated and removed in recent versions)
  - `WEBHOOK_URL` — must be set to the Tailscale URL so webhook nodes generate correct external URLs
- **Data volume**: named volume mounted to `/home/node/.n8n` — losing this loses all workflows and credentials
- **Tailscale**: sidecar required so webhook endpoints are reachable from other tailnet nodes

### Paperless-ngx

- **Images**: `ghcr.io/paperless-ngx/paperless-ngx` + Redis + PostgreSQL
- **Critical env vars**:
  - `PAPERLESS_SECRET_KEY` — generate once; changing it invalidates all sessions
  - `PAPERLESS_URL` — must match the Tailscale URL for correct link generation
- **Volumes**: `media/` (documents), `data/` (index), `consume/` (auto-import drop folder)
- **Backup**: `media/` and `data/` are critical — see Backup Strategy

### iSponsorBlockTV

- **Image**: `ghcr.io/dmunozv04/isponsorblocktv`
- **Purpose**: intercepts YouTube TV app traffic to skip sponsor segments on Apple TV / Roku / Fire TV
- **Access**: LAN only — TV devices point their DNS/proxy at this host's LAN IP
- **Port**: 8001 (check image docs — some builds use 8080)

### unpoller

UniFi Poller is **part of the monitoring compose project**, not a standalone service. It is a Prometheus scrape target, not a user-facing application. It lives in `~/plutonium/docker/monitoring/`.

---

## Onboarding Remote Hosts

Each remote Docker host runs a lightweight Alloy agent shipping data here via Tailscale.

Use `docker/monitoring/alloy/remote-agent.alloy` as the template. Per-host substitutions:
- `HOST_NAME_HERE` → unique identifier for that host
- Loki push URL: `https://loki.<tailnet>.ts.net/loki/api/v1/push`
- Prometheus remote_write URL: `https://metrics.<tailnet>.ts.net/api/v1/write`

Remote Alloy uses the host-level Tailscale (or its own sidecar) to reach these endpoints.

---

## Grafana Dashboard IDs (import from grafana.com)

| Dashboard | ID | Purpose |
|-----------|----|---------|
| Docker Container Monitoring | 11600 | Per-container CPU, memory, network |
| Node Exporter Full | 1860 | Host system metrics |
| Loki Docker Logs | 15141 | Container log viewer |
| UniFi Poller: Client DPI | 11310 | Per-client traffic |
| UniFi Poller: Network Sites | 11311 | Site overview |
| UniFi Poller: USW Switches | 11312 | Switch port utilization |
| UniFi Poller: UAP Access Points | 11313 | AP metrics |
| UniFi Poller: USG/UDM Gateway | 11314 | Router/gateway metrics |
| UniFi Poller: Clients | 11315 | Client bandwidth + connectivity |

---

## Alerting

Configure in Grafana → Alerting. Recommended starting alerts:

**Infrastructure**: Disk > 85%, memory > 90%, no metrics for 5 min (host down), container restart loop.

**Security**: Grafana/n8n/Paperless failed logins, SSH brute-force attempts (Alloy tails `/var/log/auth.log` → Loki).

**Services**: UniFi AP offline, Powerwall islanded/low charge, Tempest station offline.

**Notification channels**: Grafana → Alerting → Contact Points. Recommended: Discord webhook or Ntfy for mobile push.

---

## Backup Strategy

### What to Back Up

| Service | Critical Data | Notes |
|---------|--------------|-------|
| Grafana | `grafana_data` volume | Dashboards, alert rules, users |
| Prometheus/Mimir | `prometheus_data` / `mimir_data` volume | Metrics history |
| Loki | `loki_data` volume | Log history |
| n8n | `n8n_data` volume | Workflows + credentials — critical |
| Paperless | `media/` + `data/` volumes | Documents + index — critical |
| Paperless DB | PostgreSQL dump | Run before volume backup |
| Configs | All `*.yml`, `*.json`, `*.alloy` | Already versioned in git |

### Tool: Restic

```bash
sudo apt install -y restic

# Initialize repo (Backblaze B2 example)
restic -r b2:<bucket>:<path> init

# monitoring/scripts/backup.sh
#!/usr/bin/env bash
set -euo pipefail

# Dump Paperless PostgreSQL first
docker exec paperless-db pg_dump -U paperless paperless > /tmp/paperless-pg-$(date +%F).sql

# Restic backup
restic -r b2:<bucket>:<path> backup \
  /var/lib/docker/volumes/monitoring_grafana_data \
  /var/lib/docker/volumes/monitoring_prometheus_data \
  /var/lib/docker/volumes/n8n_n8n_data \
  /var/lib/docker/volumes/paperless_media \
  /var/lib/docker/volumes/paperless_data \
  /tmp/paperless-pg-$(date +%F).sql \
  ~/plutonium

# Retention: 7 daily, 4 weekly, 6 monthly
restic -r b2:<bucket>:<path> forget \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

Schedule via cron:
```
0 3 * * * /home/<user>/plutonium/docker/monitoring/scripts/backup.sh >> /var/log/backup.log 2>&1
```

### Restore Order

1. Stop all compose stacks
2. `restic restore latest --target /` for volumes
3. `docker exec -i paperless-db psql -U paperless < paperless-pg.sql`
4. Start monitoring stack first, then application services

---

## Maintenance

### Image Version Pinning

After initial deployment, replace `:latest` with pinned versions. Record them here:

| Service | Pinned Version |
|---------|---------------|
| grafana/grafana-oss | TBD after initial deploy |
| grafana/loki | TBD |
| grafana/alloy | TBD |
| prom/prometheus | TBD |
| n8nio/n8n | TBD |
| ghcr.io/paperless-ngx/paperless-ngx | TBD |

### Upgrading a Service

```bash
cd ~/plutonium/docker/<service>
docker compose pull
docker compose up -d
docker compose ps   # confirm all healthy before moving on
```

### Log Retention

- Loki: 30 days — `docker/monitoring/loki/config.yaml` → `limits_config.retention_period`
- Prometheus: 90 days — `--storage.tsdb.retention.time` in compose command
- Mimir: `mimir.yaml` → `blocks_storage` + compactor settings

---

## What Claude Should Know

- **Security over convenience** — always choose the more secure option; document why.
- **Read-only mounts first** — only make a volume writable if the service actively writes to it.
- **No `0.0.0.0` binding** — always bind to `${BIND_ADDR}` or `127.0.0.1`, never all interfaces.
- **Tailscale sidecar pattern** — services use `network_mode: service:ts-<name>`. Reach them internally by sidecar container name (e.g., `ts-grafana:3000`).
- **Alloy replaces Promtail** — never suggest reverting to Promtail.
- **Alertmanager is removed** — Grafana unified alerting handles all routing.
- **No hardcoded IPs** — use Docker service names or Tailscale hostnames throughout.
- **Mimir migration** — swap service, retarget Alloy `remote_write`, update Grafana datasource URL. No dashboard changes.
- **UniFi Poller needs a read-only account** — never the admin account. Same for Protect.
- **Existing integrations**: UniFi Poller (10.80.1.1 + 10.80.21.97), PowerWall exporter, Tempest exporter.
- **nuke.sh is destructive** — always confirm before running.
- **Alloy auto-discovers all containers** — logs from every container flow to Loki with no per-service config.
- **n8n encryption key is set-once** — generate before first run, never rotate.
- **n8n auth** — uses built-in user management; `N8N_BASIC_AUTH_ACTIVE` is deprecated and removed in recent versions.
- **Paperless secret key is set-once** — generate before first run, never rotate.
- **iSponsorBlockTV is LAN-only** — no Tailscale sidecar.
- **unpoller belongs in `monitoring/`** — it is a scrape target, not an application service.
- **One service, one folder, one compose file** — never merge services. No exceptions.
- **`plutonium` external network** — created manually on the host once. All compose projects that need cross-project access declare `external: true`. Never route inter-service traffic over the host network interface.
- **Every container needs resource limits, log limits, and a health check** — no container definition is complete without all three.
- **SSH is key-only** — password authentication is disabled on this host. Never re-enable it.
