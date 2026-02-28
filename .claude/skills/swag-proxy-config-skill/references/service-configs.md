# Service-Specific SWAG Configurations

Per-service proxy configs and gotchas. Read the relevant section when generating a config for that service.

## Table of Contents

1. [Vaultwarden](#vaultwarden)
2. [Plex](#plex)
3. [ConnectWise ScreenConnect](#connectwise-screenconnect)
4. [Authentik (as a proxied service)](#authentik)
5. [TeslaMate Grafana](#teslamate-grafana)
6. [Astro Static Sites](#astro-static-sites)
7. [Plex Media Streaming](#plex-media)

---

## Vaultwarden

**Risk level**: HIGHEST — contains all credentials.

**Upstream**: `vaultwarden:80`

**Key requirements**:
- Websockets required for live sync notifications
- Separate rate limiting for login vs API endpoints
- Strict fail2ban on the token endpoint
- Consider Cloudflare Access as an additional gate

**Specific locations**:

```nginx
# Vaultwarden notifications (websocket)
location /notifications/hub {
    include /config/nginx/authentik-location.conf;

    include /config/nginx/resolver.conf;
    set $upstream_app vaultwarden;
    set $upstream_port 80;
    set $upstream_proto http;
    proxy_pass $upstream_proto://$upstream_app:$upstream_port;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
}

# Vaultwarden login endpoint (strict rate limit)
location /identity/connect/token {
    include /config/nginx/authentik-location.conf;

    limit_req zone=auth_limit burst=3 nodelay;

    include /config/nginx/resolver.conf;
    set $upstream_app vaultwarden;
    set $upstream_port 80;
    set $upstream_proto http;
    proxy_pass $upstream_proto://$upstream_app:$upstream_port;
}
```

**Fail2ban filter** (`fail2ban/filter.d/vaultwarden.conf`):
```ini
[Definition]
failregex = ^<HOST> .* "POST /identity/connect/token.* HTTP/.*" (401|403) .*$
ignoreregex =
```

**Gotchas**:
- Vaultwarden's admin panel (`/admin`) should be disabled (`ADMIN_TOKEN=` empty) or restricted to Tailscale-only via a separate location block that returns 403
- The Bitwarden browser extension and mobile app send frequent sync requests — don't rate-limit `/api/` too aggressively or normal usage breaks
- If using Cloudflare proxy, Vaultwarden's websocket notifications work over Cloudflare but require the "Websockets" toggle enabled in Cloudflare dashboard for the domain

---

## Plex

**Risk level**: MEDIUM — media access, viewing history.

**Upstream**: `zelda-plex.tail147f1.ts.net:32450` (via nginx-plex sidecar on Zelda)

**Key requirements**:
- Large body size for poster uploads
- Streaming needs proxy_buffering off
- Plex has its own robust auth — Authentik forward auth is optional
- Disable Plex's built-in Remote Access when using SWAG
- Use the nginx-plex sidecar (port 32450) NOT port 32400 directly — the sidecar fixes real IP forwarding

**Specific config**:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name plex.*;

    include /config/nginx/ssl.conf;

    client_max_body_size 100m;

    location / {
        # Plex has strong native auth — Authentik optional here
        include /config/nginx/resolver.conf;
        set $upstream_app zelda-plex.tail147f1.ts.net;
        set $upstream_port 32450;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;

        proxy_set_header    X-Plex-Client-Identifier $http_x_plex_client_identifier;
        proxy_set_header    X-Plex-Device $http_x_plex_device;
        proxy_set_header    X-Plex-Device-Name $http_x_plex_device_name;
        proxy_set_header    X-Plex-Product $http_x_plex_product;
        proxy_set_header    X-Plex-Version $http_x_plex_version;
        proxy_set_header    X-Plex-Platform $http_x_plex_platform;
        proxy_set_header    X-Plex-Platform-Version $http_x_plex_platform_version;
        proxy_set_header    X-Plex-Features $http_x_plex_features;
        proxy_set_header    X-Plex-Model $http_x_plex_model;
        proxy_set_header    X-Plex-Language $http_x_plex_language;

        proxy_http_version  1.1;
        proxy_set_header    Upgrade $http_upgrade;
        proxy_set_header    Connection "upgrade";

        proxy_buffering     off;
        proxy_redirect      off;

        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
    }
}
```

**Gotchas**:
- Adding Authentik forward auth to Plex means every chunk of a video stream triggers an auth check — this adds noticeable latency. Plex's own auth is sufficient.
- Plex's custom `X-Plex-*` headers MUST be forwarded — Plex clients break without them
- Disable Plex's "Remote Access" in Settings → Network after setting up SWAG
- Set `proxy_read_timeout` high (86400s) — Plex streams are long-lived connections
- Use port 32450 (nginx-plex sidecar) not 32400 — the sidecar handles X-Forwarded-For so Tautulli logs real IPs
- The upstream uses MagicDNS name (`zelda-plex.tail147f1.ts.net`), not a host IP variable

---

## ConnectWise ScreenConnect

**Risk level**: HIGH — remote code execution on managed endpoints.

**Upstream**: Typically `screenconnect:8040` (web) and `:8041` (relay).

**Key requirements**:
- Authentik MUST protect the admin web console
- The relay port may need separate handling (client connections)
- Websocket support needed

**Specific config**:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name remote.*;

    include /config/nginx/ssl.conf;
    include /config/nginx/proxy.conf;

    client_max_body_size 100m;

    include /config/nginx/authentik-server.conf;

    location / {
        include /config/nginx/authentik-location.conf;

        limit_req zone=general_limit burst=20 nodelay;

        include /config/nginx/resolver.conf;
        set $upstream_app screenconnect;
        set $upstream_port 8040;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;

        proxy_http_version  1.1;
        proxy_set_header    Upgrade $http_upgrade;
        proxy_set_header    Connection $connection_upgrade;
        proxy_buffering     off;
    }

    location /Login {
        include /config/nginx/authentik-location.conf;

        limit_req zone=auth_limit burst=2 nodelay;

        include /config/nginx/resolver.conf;
        set $upstream_app screenconnect;
        set $upstream_port 8040;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;
    }
}
```

**Gotchas**:
- ScreenConnect's client relay port (typically 8041) is a separate TCP connection, not HTTP. It may need a separate `stream {}` block in nginx, or be exposed directly (not through SWAG)
- If clients can't connect for remote sessions, the relay port is likely the issue
- Strongly consider keeping the admin console Tailscale-only and only exposing the relay port through SWAG

---

## Authentik

Authentik itself needs a proxy config when it's the SSO provider for SWAG-exposed services. This is NOT the forward auth integration — this is Authentik's own web UI.

**Risk level**: HIGH — if Authentik is compromised, all SSO-protected services are exposed.

**Upstream**: `authentik-server:9000`

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name auth.*;

    include /config/nginx/ssl.conf;
    include /config/nginx/proxy.conf;

    # Do NOT put Authentik forward auth on Authentik itself — infinite loop
    # Authentik has its own authentication

    location / {
        include /config/nginx/resolver.conf;
        set $upstream_app authentik-server;
        set $upstream_port 9000;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
    }
}
```

**Gotchas**:
- NEVER put `authentik-server.conf` / `authentik-location.conf` on Authentik's own proxy config — this creates an infinite redirect loop
- Authentik's own login page handles its own auth and MFA
- Rate-limit Authentik's flow executor endpoint (`/api/v3/flows/executor/`) to prevent brute force
- Authentik handles CSRF protection internally — don't add nginx-level CSRF that conflicts

---

## TeslaMate Grafana

**Risk level**: MEDIUM — vehicle location and trip data is sensitive.

**Upstream**: `teslamate-grafana:3000`

Straightforward proxy with Authentik. TeslaMate's Grafana instance usually doesn't have strong auth configured, so Authentik is essential.

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name teslagraf.*;

    include /config/nginx/ssl.conf;
    include /config/nginx/proxy.conf;

    include /config/nginx/authentik-server.conf;

    location / {
        include /config/nginx/authentik-location.conf;

        include /config/nginx/resolver.conf;
        set $upstream_app teslamate-grafana;
        set $upstream_port 3000;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

**Gotchas**:
- TeslaMate Grafana is a separate Grafana instance — make sure the upstream points to `teslamate-grafana`, not a monitoring Grafana
- Some TeslaMate dashboards use iframe embeds — you may need to relax `X-Frame-Options` to `ALLOWALL` for TeslaMate specifically (security tradeoff — evaluate)
- `VIRTUAL_HOST` env var in TeslaMate's `.env` must match the subdomain for WebSocket origin checks

---

## Astro Static Sites

**Risk level**: LOW — static content only.

**Upstream**: Typically `astro-site:4321` (dev) or served from a static file server.

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name www.*;

    include /config/nginx/ssl.conf;
    include /config/nginx/proxy.conf;

    # No Authentik needed — public site

    # Aggressive caching for static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        include /config/nginx/resolver.conf;
        set $upstream_app astro-site;
        set $upstream_port 4321;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;

        expires             30d;
        add_header          Cache-Control "public, immutable";
    }

    location / {
        include /config/nginx/resolver.conf;
        set $upstream_app astro-site;
        set $upstream_port 4321;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;
    }
}
```

**Gotchas**:
- For SSR Astro sites, ensure the proxy forwards headers correctly — Astro's SSR needs the original host
- For static-only Astro sites, consider serving from SWAG's built-in nginx directly (copy build output to `/config/www/`) instead of running a separate container
- Add CSP headers appropriate for the site's content
