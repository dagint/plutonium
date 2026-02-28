# Nginx Proxy Config Templates for New Services

All proxy configs live in `services/vps/` and are generated to `docker/swag/config/nginx/proxy-confs/` by `build-proxy-confs.sh`. Never edit the proxy-confs directory directly.

## Template: Standard Service with Authentik

```nginx
# <Service Name> - VPS Docker container
# Upstream: <container-name>:<port> (Docker container on proxy network)
# Auth: Authentik forward auth (enabled)
# URL: https://<service>.dagint.com

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name <service>.*;

    include /config/nginx/ssl.conf;
    include /config/nginx/proxy.conf;

    # Authentik auth endpoint
    include /config/nginx/authentik-server.conf;

    location / {
        # Require Authentik SSO before access
        include /config/nginx/authentik-location.conf;

        include /config/nginx/resolver.conf;
        set $upstream_app <container-name>;
        set $upstream_port <port>;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;
    }
}
```

## Template: Service with WebSocket + Authentik

For services using Socket.IO, WebSocket, or SSE (Uptime Kuma, Homarr, n8n, code-server):

```nginx
# <Service Name> - VPS Docker container
# Upstream: <container-name>:<port>
# Auth: Authentik forward auth (enabled)
# WebSocket: enabled (Socket.IO / live updates)

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name <service>.*;

    include /config/nginx/ssl.conf;
    include /config/nginx/proxy.conf;

    include /config/nginx/authentik-server.conf;

    location / {
        include /config/nginx/authentik-location.conf;

        include /config/nginx/resolver.conf;
        set $upstream_app <container-name>;
        set $upstream_port <port>;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;

        # WebSocket / Socket.IO upgrade support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

`$connection_upgrade` is defined in SWAG's `proxy.conf` — that include is what makes this variable available.

## Template: Service Without Authentik (Own Auth)

For services that manage their own authentication (Vaultwarden, Plex, Jellyseerr):

```nginx
# <Service Name> - VPS Docker container
# Upstream: <container-name>:<port>
# Auth: None - <Service> handles its own authentication
# URL: https://<service>.dagint.com

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name <service>.*;

    include /config/nginx/ssl.conf;
    include /config/nginx/proxy.conf;

    location / {
        include /config/nginx/resolver.conf;
        set $upstream_app <container-name>;
        set $upstream_port <port>;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;
    }
}
```

## Template: Service Reaching Tailscale Remote Host

For services running on the homelab media server (Zelda, homelab) — reached via Tailscale MagicDNS:

```nginx
# <Service Name> - Homelab server via Tailscale
# Upstream: <hostname>.tail147f1.ts.net:<port>
# Auth: Authentik forward auth (enabled)

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name <service>.*;

    include /config/nginx/ssl.conf;
    include /config/nginx/proxy.conf;

    include /config/nginx/authentik-server.conf;

    location / {
        include /config/nginx/authentik-location.conf;

        include /config/nginx/resolver.conf;
        set $upstream_app <hostname>.tail147f1.ts.net;
        set $upstream_port <port>;
        set $upstream_proto http;
        proxy_pass $upstream_proto://$upstream_app:$upstream_port;
    }
}
```

Note: No `HOST_*_IP` variable needed — use the stable MagicDNS name directly.

## Rules for This Repo

1. **Filename**: `<service>.subdomain.conf` in `services/vps/`
2. **server_name**: `<service>.*;` — wildcard matches all domains (dagint.com, wopr.net, biffco.net)
3. **`http2 on;`** must be on both listen lines
4. **Always include `proxy.conf`** — provides standard proxy headers, `$connection_upgrade`, and `proxy_buffering off`
5. **`resolver.conf` + `set $upstream_*`** — LSIO's pattern for dynamic upstream resolution; avoids nginx startup failures when containers aren't up
6. **Multiple locations** — each content-serving location block needs its own `authentik-location.conf` include. Don't rely on inheritance.
7. **After editing**: run `./scripts/build-proxy-confs.sh` to deploy to proxy-confs/, then `docker exec swag nginx -t` to validate syntax.
