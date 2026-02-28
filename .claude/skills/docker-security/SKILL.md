---
name: docker-security
description: Harden Docker Compose service definitions with security best practices — drop capabilities, enforce non-root users, set resource limits, add health checks, restrict filesystem access, and flag dangerous patterns like Docker socket mounts or host networking. Use this skill whenever the user creates or modifies a docker-compose.yml, adds a new container to a stack, reviews a Docker Compose file for security, asks about container hardening, or wants to audit an existing compose stack. Also trigger when the user mentions "docker security", "container hardening", "cap_drop", "no-new-privileges", "docker socket security", "read_only container", or asks why a container is running as root. This skill applies to EVERY container definition — not just internet-exposed ones. Internal containers that get compromised become pivot points for lateral movement.
---

# Docker Compose Security Hardening

Review and harden Docker Compose service definitions. Every container in your stack should follow these practices — not just the internet-facing ones. A compromised internal container with excessive privileges becomes an attacker's foothold for lateral movement.

## Why This Matters

Docker containers are not VMs. By default they run as root, retain dozens of Linux capabilities they don't need, can write to their entire filesystem, and have no resource limits. A single vulnerability in any containerized service — even one that's "only internal" — can escalate to full host compromise if the container has unnecessary privileges.

## The Hardening Checklist

Apply these to every service definition. Each section explains what, why, and how.

### 1. Drop All Capabilities, Add Back Minimally

**Default risk**: Docker grants containers 14 capabilities by default (NET_RAW, CHOWN, DAC_OVERRIDE, SETUID, SETGID, etc.). Most services need zero of them.

**Fix**:
```yaml
services:
  myservice:
    cap_drop:
      - ALL
    # Only add back what's genuinely needed:
    # cap_add:
    #   - NET_BIND_SERVICE  # only if binding to ports < 1024
```

**Common capabilities and when to add them back**:

| Capability | When Needed | Examples |
|-----------|-------------|---------|
| `NET_BIND_SERVICE` | Binding to port < 1024 | Nginx on :80/:443 |
| `NET_ADMIN` | Network configuration | Tailscale sidecars, VPN containers, WireGuard, fail2ban |
| `SYS_MODULE` | Loading kernel modules | Tailscale sidecars (used with NET_ADMIN) |
| `CHOWN` | `chown` on files/dirs at startup | s6-overlay, init scripts that fix volume ownership |
| `FOWNER` | `chmod`/`utime` on files not owned by process UID | Init scripts that chmod volume files after mounting |
| `DAC_OVERRIDE` | Bypass read/write/execute checks (incl. `rm`, `ln`, file writes) | Init scripts that delete/create files in dirs owned by another UID |
| `SETUID` / `SETGID` | Dropping from root to non-root at startup | s6-overlay, gosu, images that start as root then switch users |

**The init-as-root pattern**: Any container whose entrypoint initializes a host-mounted volume then drops to a non-root user needs the full set. Errors appear sequentially — fix one and the next reveals itself:

| Init step | Error in logs | Capability needed |
|-----------|--------------|-------------------|
| `chown /app/data` | `chown: Operation not permitted` | `CHOWN` |
| `chmod /app/data/file` | `chmod: Operation not permitted` | `FOWNER` |
| `rm /app/data/stale.wal` | `rm: Permission denied` | `DAC_OVERRIDE` |
| `ln /path/to/file /app/data/link` | `ln: Permission denied` | `DAC_OVERRIDE` |
| `su-exec bun ./app` or `gosu node ./app` | `failed switching to "bun": operation not permitted` | `SETUID` + `SETGID` |

**Audit the entrypoint script, not just the main process.** A comment like "runs as non-root — no cap_add needed" is wrong if the entrypoint wrapper runs as root first. Expect to need CHOWN + FOWNER + DAC_OVERRIDE + SETUID + SETGID for any image that "fixes permissions" before starting.

**The rule**: Start with `cap_drop: ALL`. If the container fails to start, check the logs for "permission denied" or "operation not permitted" errors, identify the specific capability needed, and add only that one back. Don't preemptively add capabilities "just in case."

**Exception**: Tailscale sidecar containers genuinely need `NET_ADMIN` and `SYS_MODULE`. This is the one case where broad capabilities are justified — Tailscale creates a network interface inside the container.

### 2. Prevent Privilege Escalation

**Default risk**: Processes inside a container can gain new privileges (e.g., via setuid binaries).

**Fix**:
```yaml
services:
  myservice:
    security_opt:
      - no-new-privileges:true
```

Always include this. There is almost never a reason to omit it. The only exception is containers that explicitly need setuid/setgid to drop from root to a non-root user at startup — and even then, many images handle this without `no-new-privileges` being a problem.

### 3. Run as Non-Root

**Default risk**: Most Docker images run as root (UID 0) by default. If an attacker escapes the container, they're root on the host.

**Fix — Option A**: Image provides a non-root user (best):
```yaml
services:
  myservice:
    user: "1000:1000"  # or the image's documented non-root user
```

**Fix — Option B**: Image requires root at startup but drops privileges internally. Check the image documentation — many LinuxServer.io images use PUID/PGID:
```yaml
services:
  myservice:
    environment:
      - PUID=1000
      - PGID=1000
```

**How to check if an image supports non-root**:
1. Check the Dockerfile for `USER` directive
2. Check the image documentation for PUID/PGID or `user` instructions
3. Try setting `user: "1000:1000"` — if it works, the image supports it
4. If it fails with permission errors, the image likely needs root at startup

**Common images and their non-root status**:

| Image | Non-Root Support | How |
|-------|-----------------|-----|
| LinuxServer.io images | Yes | `PUID=1000` + `PGID=1000` env vars |
| Grafana | Yes | Runs as `grafana` (UID 472) by default |
| Prometheus | Yes | Runs as `nobody` by default |
| Loki | Yes | Runs as UID 10001 by default |
| Alloy | Yes | `user: "1000:1000"` or runs as grafana user |
| PostgreSQL | Yes | Runs as `postgres` (UID 999 or 70) by default |
| code-server | Yes | Runs as `coder` (UID 1000) by default |
| n8n | Yes | Runs as `node` (UID 1000) by default |
| Vaultwarden | Yes | `user: "1000:1000"` works |
| Tailscale | **No** | Needs root for network interface creation |
| Open WebUI | Check docs | May need root — verify |

### 4. Read-Only Filesystem

**Default risk**: A compromised container can write anywhere in its filesystem — installing tools, dropping webshells, modifying binaries.

**Fix**:
```yaml
services:
  myservice:
    read_only: true
    tmpfs:
      - /tmp
      - /run
    volumes:
      - myservice_data:/data  # only the dirs that need writes
```

**How it works**: `read_only: true` makes the container's root filesystem immutable. The app can only write to explicitly mounted volumes and tmpfs mounts. This means an attacker can't modify the application binaries, install additional tools, or persist malware in the container filesystem.

**Common tmpfs needs**: Most apps need `/tmp` writable. Some need `/run` for PID files. Add tmpfs mounts as the container demands — check logs for "read-only filesystem" errors.

**When to skip**: Some images heavily modify their own filesystem at startup (installing plugins, compiling assets). These are harder to run read-only. Try it first; skip if it's impractical. The other hardening measures still apply.

### 5. Resource Limits

**Default risk**: A container with no resource limits can consume all host memory (OOM-killing other containers, including your LLM inference) or all CPU.

**Fix**:
```yaml
services:
  myservice:
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: "2.0"
        reservations:
          memory: 256M
```

**Sizing guidance**:

| Service Type | Memory Limit | CPU Limit | Notes |
|-------------|-------------|-----------|-------|
| Web UIs (Grafana, Open WebUI, n8n) | 1G | 2.0 | Spiky under load |
| Databases (PostgreSQL) | 1G-2G | 2.0 | Size to dataset |
| Proxy/routing (LiteLLM, nginx) | 512M | 1.0 | Low steady-state |
| Monitoring agents (Alloy) | 256M-512M | 1.0 | Depends on log volume |
| Tailscale sidecars | 128M | 0.5 | Very lightweight |
| Static sites | 256M | 0.5 | Minimal resources |

**On this VPS**: Memory limits are critical because every GB consumed by a runaway container reduces headroom for other services. Set limits on everything.

### 6. Health Checks

**Default risk**: Docker reports a container as "running" even if the application inside has crashed, deadlocked, or become unresponsive. Without health checks, `docker compose ps` lies to you.

**Fix**:
```yaml
services:
  myservice:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:PORT/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
```

**If the image doesn't have curl**: Use `wget` or a simple TCP check:
```yaml
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:PORT/health || exit 1"]
      # or TCP-only:
      test: ["CMD-SHELL", "nc -z localhost PORT || exit 1"]
```

**Common health check endpoints**:

| Service | Endpoint | Method |
|---------|----------|--------|
| Grafana | `http://localhost:3000/api/health` | curl/wget |
| Prometheus | `http://localhost:9090/-/healthy` | curl/wget |
| Loki | `http://localhost:3100/ready` | curl/wget |
| n8n | `http://localhost:5678/healthz` | curl/wget |
| Vaultwarden | `http://localhost:80/alive` | curl/wget |
| PostgreSQL | `pg_isready -U postgres` | CMD |
| LiteLLM | `http://localhost:4000/health` | curl/wget |
| Open WebUI | `http://localhost:8080/health` | curl/wget |

### 7. Docker Socket Mounts

**Default risk**: Mounting `/var/run/docker.sock` gives a container full control over Docker — it can create, delete, and exec into any container on the host. This is equivalent to root access on the host.

**Rule**: Only mount the Docker socket when the container's core function requires it, and understand that you are giving it full host control.

**Justified uses**:
- Alloy/Promtail (Docker log discovery — needs to list containers)
- Portainer/Dockge (Docker management — that's its entire purpose)
- Traefik/SWAG (auto-discovery of containers for routing)
- Watchtower (auto-updating containers)

**Mitigations when you must mount it**:
```yaml
services:
  alloy:
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro  # READ-ONLY
    user: "1000:999"  # non-root user in docker group
```

Always mount `:ro` (read-only) unless the container needs to manage Docker (Portainer, Watchtower). Log collectors like Alloy only need read access.

**For stronger isolation**: Consider using a Docker socket proxy like [Tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) that exposes only specific Docker API endpoints:
```yaml
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy
    environment:
      - CONTAINERS=1     # allow listing containers
      - POST=0           # deny all write operations
      - NETWORKS=0
      - VOLUMES=0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - internal

  alloy:
    # Connect to proxy instead of raw socket
    environment:
      - DOCKER_HOST=tcp://docker-socket-proxy:2375
    networks:
      - internal
```

### 8. Network Segmentation

**Default risk**: All containers on the same Docker network can talk to each other on any port. Your monitoring agent can reach your database. Your static site container can reach your password manager.

**Fix**: Use multiple named networks and only attach containers to the networks they need:

```yaml
networks:
  frontend:    # Internet-facing services
  backend:     # Databases, internal APIs
  monitoring:  # Metrics and log collection

services:
  nginx:
    networks: [frontend, backend]   # Bridges the two
  postgres:
    networks: [backend]             # Only reachable from backend
  grafana:
    networks: [monitoring]          # Isolated from app traffic
  alloy:
    networks: [monitoring]          # Only needs monitoring network
```

**Principle**: A container should be on the minimum number of networks required for it to function.

### 9. Image Pinning

**Default risk**: `:latest` tags are mutable. A `docker compose pull` could introduce a breaking change or — in a supply chain attack — a compromised image.

**Recommended approach**:
```yaml
# Development/homelab: Pin to version tags
image: grafana/grafana-oss:11.1.0

# High security: Pin to digest
image: grafana/grafana-oss@sha256:abc123...
```

**Practical guidance for homelab**: Version tags (`:11.1.0`) are a good balance. Full digest pinning is more secure but makes updates tedious. Use `:latest` only during initial setup and experimentation, then pin once stable.

### 10. Secrets Handling

**Default risk**: Secrets in `environment:` are visible in `docker inspect`, `docker compose config`, process listings, and container logs that include environment dumps.

**Better options** (in order of preference):

**Option A — Environment file** (good for homelab):
```yaml
services:
  myservice:
    env_file: .env  # Keep secrets in .env, not inline
```

**Option B — Docker secrets** (better, but more complex):
```yaml
secrets:
  db_password:
    file: ./secrets/db_password.txt

services:
  postgres:
    secrets:
      - db_password
    environment:
      - POSTGRES_PASSWORD_FILE=/run/secrets/db_password
```

**Option C — File-based injection** (if the app supports it):
```yaml
services:
  myservice:
    volumes:
      - ./secrets/api_key:/run/secrets/api_key:ro
    environment:
      - API_KEY_FILE=/run/secrets/api_key
```

**Minimum bar**: Never put actual secret values inline in `docker-compose.yml`. Use `${VARIABLE}` references to `.env` at minimum.

## Applying the Checklist

When reviewing or generating a Docker Compose service, apply this hardened template:

```yaml
services:
  example:
    image: vendor/image:1.2.3           # Pinned version, not :latest
    user: "1000:1000"                    # Non-root (if image supports it)
    read_only: true                      # Immutable filesystem
    security_opt:
      - no-new-privileges:true           # No privilege escalation
    cap_drop:
      - ALL                              # Drop all capabilities
    # cap_add:                           # Add back ONLY what's needed
    #   - NET_BIND_SERVICE
    tmpfs:
      - /tmp                             # Writable temp space
      - /run                             # PID files if needed
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: "2.0"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:PORT/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - app_data:/data                   # Only mount what's needed
    environment:
      - CONFIG_VAR=value                 # Non-sensitive config only
    env_file: .env                       # Secrets via env file
    restart: unless-stopped
```

Not every field applies to every container. The point is to start from the hardened template and remove restrictions only when the container genuinely requires it — not to start from the permissive default and hope you remember to add restrictions.

## Audit Mode

When asked to audit an existing docker-compose.yml, review each service against this checklist and report findings in this format:

```
Service: <name>
  ✅ cap_drop: ALL present
  ⚠️  Running as root (no user: directive) — image supports non-root via PUID/PGID
  ❌ No resource limits — can OOM-kill other services
  ❌ Docker socket mounted read-write — should be :ro
  ⚠️  Using :latest tag — pin to version for stability
  ✅ no-new-privileges set
  ❌ No health check defined
```

Severity levels:
- ❌ **Fix now**: Directly exploitable or high-impact (Docker socket RW, running as root with no justification, no resource limits on a memory-constrained host)
- ⚠️ **Should fix**: Increases attack surface or reduces operational reliability (mutable tags, missing health checks, capabilities not dropped)
- ✅ **Good**: Already hardened

## Exceptions Log

Some containers legitimately need elevated privileges. When you must grant them, document why:

```yaml
  # SECURITY EXCEPTION: Tailscale sidecar requires NET_ADMIN + SYS_MODULE
  # to create and manage the Tailscale network interface.
  # This is a fundamental requirement of how Tailscale works in containers.
  ts-service:
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    # Still apply everything else:
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:
          memory: 128M
```

Always apply as many hardening measures as possible even on containers that need exceptions. A Tailscale sidecar needs capabilities but should still have resource limits, health checks, and no-new-privileges.
