---
name: debug-service
description: Diagnose and fix issues with VPS services in this SWAG + Authentik + Docker stack. Use this skill when a service is unreachable, returning errors, failing to start, or behaving unexpectedly. Also trigger when the user says a service is "broken", "not working", "returning 502/404/403", "stuck in a redirect loop", or when containers are crashing. This skill covers the full diagnostic flow: nginx → Authentik → container → networking → Tailscale DNS.
---

# Debug VPS Service Issues

Systematic diagnostic flow for the SWAG + Authentik + Docker stack. Work top-down: browser → nginx → auth → container → networking.

## Quick Triage: What's the Symptom?

| Symptom | Most Likely Cause | Jump To |
|---------|------------------|---------|
| 502 Bad Gateway | Container not running or wrong port | Container Health |
| 404 Not Found | nginx config missing or wrong server_name | Nginx Config |
| 403 Forbidden | Authentik blocking or wrong app slug | Authentik Auth |
| Infinite redirect loop | Authentik config error / auth on auth endpoint | Authentik Auth |
| 301 redirect storm | HTTP→HTTPS redirect issue | Nginx Config |
| Service loads but no real-time updates | Missing WebSocket headers | WebSocket |
| "Could not connect" / DNS failure | Container not on proxy network | Network |
| Works on Tailscale, fails on public | UFW blocking non-Cloudflare IP | Firewall |
| Auth prompt keeps reappearing | Authentik session / outpost not bound | Authentik Auth |

---

## 1. Nginx Config

### Check if config is loaded

```bash
# Validate syntax
docker exec swag nginx -t

# Check if the config file exists in the right place
ls docker/swag/config/nginx/proxy-confs/<service>.subdomain.conf

# Did build-proxy-confs.sh run? (compare services/vps/ to proxy-confs/)
diff <(ls services/vps/) <(ls docker/swag/config/nginx/proxy-confs/*.subdomain.conf | xargs -n1 basename)
```

### Common nginx config mistakes

- **Config in wrong location**: Edit `services/vps/`, not `docker/swag/config/nginx/proxy-confs/`. Run `./scripts/build-proxy-confs.sh` after editing.
- **Wrong `server_name`**: Pattern is `server_name <service>.*;` — the wildcard matches all domains. Check what you put.
- **Missing `include /config/nginx/authentik-server.conf;`**: The outpost endpoint is never registered, so Authentik redirects have nowhere to go.
- **`auth_request` on wrong location**: If `/api/` has no `authentik-location.conf`, that path bypasses auth.
- **`$connection_upgrade` not defined**: SWAG's `proxy.conf` should define this. If WebSocket fails, verify `proxy.conf` is included.

### View nginx error logs

```bash
docker logs swag --tail=50
docker exec swag tail -50 /config/log/nginx/error.log
docker exec swag tail -50 /config/log/nginx/access.log
```

---

## 2. Container Health

### Is the container running?

```bash
docker ps | grep <service>
docker compose -f docker/<service>/docker-compose.yml ps
```

### Container crash logs

```bash
docker logs <container-name> --tail=100
docker logs <container-name> --since=10m
```

### Common container issues

- **Permission denied on data dir**: Container running as non-root UID can't write to dir owned by flux-deploy.
  - For LSIO images (s6-overlay): add `cap_add: [CHOWN, SETUID, SETGID]`; also don't pre-create dirs owned by flux-deploy (let container create them).
  - For direct-run images: use `chmod 777` on the data dir, or pre-chown to the container's UID.

- **Port conflict**: Another service using the same container port. Check `docker compose.yml` for port mapping.

- **Missing environment variables**: Container exits early. Check `.env` file exists and has required vars.

- **Container not on proxy network**: nginx resolves the container name via Docker DNS on the `proxy` network. If the container's network isn't `proxy`, it won't be reachable.

  ```yaml
  # In docker-compose.yml
  networks:
    proxy:
      external: true
  ```

- **Resource limits too strict**: Container OOM-killed. Check with `docker stats <container>`.

---

## 3. Authentik Auth

### Check if outpost is bound

1. Browse to `https://auth.dagint.com/if/admin/`
2. Navigate to **Applications → Outposts**
3. Click **Embedded Outpost** → verify the service's application is listed

### Application not in Authentik

The application wasn't added to Authentik. Run:
```bash
python3 scripts/configure-authentik.py --dry-run
# Review what it would create, then:
python3 scripts/configure-authentik.py
```

Or manually: Authentik Admin → Providers → add Proxy Provider → add Application → bind to Embedded Outpost.

### Infinite redirect loop

Cause: `authentik-location.conf` is included inside the Authentik outpost location itself (`/outpost.goauthentik.io`), or `auth_request` points at itself.

Check `services/vps/<service>.subdomain.conf`:
- `authentik-server.conf` include should be in the **server block** (not inside a location)
- `authentik-location.conf` should be in the **content-serving location** (`/`), NOT inside the outpost location

### 401 on every request (even after login)

- **Cookie domain mismatch**: Service uses a different domain than the auth callback expected
- **Outpost not configured**: Application not bound to Embedded Outpost in Authentik admin
- **Authentik itself is down**: `docker logs authentik-server --tail=50`

### Check Authentik logs

```bash
docker logs authentik-server --tail=50
docker logs authentik-worker --tail=50
```

---

## 4. Network / DNS

### Container-to-container DNS (Docker internal)

```bash
# Can swag reach the service container?
docker exec swag ping <container-name>
docker exec swag wget -q -O- http://<container-name>:<port>/ | head -5

# Is the container on the proxy network?
docker network inspect proxy | grep -A3 "<container-name>"
```

### Tailscale DNS (for remote/homelab services)

Services on the homelab use Tailscale MagicDNS names. Check:

```bash
# From inside the swag container
docker exec swag nslookup zelda-plex.tail147f1.ts.net
docker exec swag wget -q -O- http://zelda-plex.tail147f1.ts.net:32450/ | head -5
```

If DNS fails inside swag, check:
- `resolver.conf` is present at `/config/nginx/resolver.conf`
- The Tailscale node is online: `tailscale status` on the VPS

### Tailscale ACL

If a Tailscale path works from one node but not another, check the ACL:
- Tags: `tag:reverse-proxy` (VPS swag container), `tag:homelab-media` (Zelda)
- Required ports must be open in the ACL for the tag pair

### UFW (public traffic)

Public HTTPS traffic must come from Cloudflare IPs. To check:
```bash
sudo ufw status numbered | head -30
# Should show Cloudflare IPv4/IPv6 ranges allowing ports 80/443
```

---

## 5. WebSocket Issues

Services that use WebSocket or Socket.IO (Uptime Kuma, n8n, Homarr) need upgrade headers in the location block:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

`$connection_upgrade` is defined in SWAG's `proxy.conf` — ensure `include /config/nginx/proxy.conf;` is in the server block.

Browser test: open DevTools → Network → WS tab. If connections are failing with 400/404, the headers are missing.

---

## 6. After Making Fixes

```bash
# Regenerate nginx configs from source
./scripts/build-proxy-confs.sh

# Validate nginx syntax
docker exec swag nginx -t

# Reload nginx (without restart — preserves connections)
docker exec swag nginx -s reload

# Or restart the container if needed
docker compose -f docker/swag/docker-compose.yml restart swag

# Check logs after reload
docker logs swag --tail=20
```

---

## Useful One-Liners

```bash
# Show all running containers with status
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Follow logs for a service
docker logs -f <container-name>

# Show last 50 nginx access log lines
docker exec swag tail -50 /config/log/nginx/access.log

# List all proxy network members
docker network inspect proxy --format '{{range .Containers}}{{.Name}} {{end}}'

# Check SWAG config for a specific service
cat docker/swag/config/nginx/proxy-confs/<service>.subdomain.conf

# Test nginx config then reload
docker exec swag nginx -t && docker exec swag nginx -s reload

# Full restart of a service stack
docker compose -f docker/<service>/docker-compose.yml down && docker compose -f docker/<service>/docker-compose.yml up -d
```
