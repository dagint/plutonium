# Docker & Docker Compose Reference

Concrete patterns for reviewing Dockerfiles and Compose files. Each section shows
the vulnerable/bad pattern and the corrected version.

---

## Dockerfile Patterns

### Base Image Pinning

```dockerfile
# CRITICAL — never use latest, vulnerable to supply chain attacks
FROM node:latest
FROM python:3.12

# FIXED — pin to specific version + digest
FROM node:22.11.0-slim@sha256:abc123...
FROM python:3.12.1-slim-bookworm@sha256:def456...
```

How to get the digest:
```bash
docker pull python:3.12.1-slim-bookworm
docker inspect --format='{{index .RepoDigests 0}}' python:3.12.1-slim-bookworm
```

Prefer `-slim` or `-alpine` variants. Full images contain compilers, package managers,
and tools that expand attack surface.

### Non-Root User

```dockerfile
# CRITICAL — running as root
FROM node:22-slim
WORKDIR /app
COPY . .
RUN npm ci --production
CMD ["node", "server.js"]

# FIXED — create and switch to non-root user
FROM node:22-slim
RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser
WORKDIR /app
COPY --chown=appuser:appuser . .
RUN npm ci --production
USER appuser
CMD ["node", "server.js"]
```

For Alpine-based images:
```dockerfile
RUN addgroup -S appuser && adduser -S appuser -G appuser
```

### Multi-Stage Builds

```dockerfile
# HIGH — build tools in production image
FROM node:22
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
CMD ["node", "dist/server.js"]

# FIXED — multi-stage separates build from runtime
FROM node:22 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-slim
RUN groupadd -r app && useradd -r -g app -d /app -s /sbin/nologin app
WORKDIR /app
COPY --from=builder --chown=app:app /app/dist ./dist
COPY --from=builder --chown=app:app /app/node_modules ./node_modules
COPY --from=builder --chown=app:app /app/package.json ./
USER app
CMD ["node", "dist/server.js"]
```

### Secrets in Images

```dockerfile
# CRITICAL — secret baked into image layer (visible via docker history)
ARG DB_PASSWORD
ENV DB_PASSWORD=$DB_PASSWORD
RUN echo "db_pass=${DB_PASSWORD}" > /app/config.ini

# CRITICAL — copying env file into image
COPY .env /app/.env

# CRITICAL — fetching secrets during build
RUN curl -H "Authorization: Bearer ${TOKEN}" https://api.example.com/config > /app/config.json

# FIXED — secrets provided at runtime only
# Dockerfile has NO secrets — they come from Compose env_file or Docker secrets
ENV DB_HOST=db \
    DB_PORT=5432
# App reads DB_PASSWORD from environment variable at runtime
CMD ["node", "server.js"]
```

For build-time secrets (e.g., private npm registry auth):
```dockerfile
# Use BuildKit secrets — never visible in image layers
# syntax=docker/dockerfile:1
FROM node:22-slim
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
```

Build with: `docker build --secret id=npmrc,src=.npmrc .`

### HEALTHCHECK

```dockerfile
# MEDIUM — no health check, orchestrator can't detect unhealthy container
FROM node:22-slim
CMD ["node", "server.js"]

# FIXED — health check enables orchestrator to restart unhealthy containers
FROM node:22-slim
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["node", "-e", "require('http').get('http://localhost:3000/health', (r) => { process.exit(r.statusCode === 200 ? 0 : 1) })"]
CMD ["node", "server.js"]
```

For non-HTTP services:
```dockerfile
# PostgreSQL
HEALTHCHECK CMD ["pg_isready", "-U", "postgres"]

# Redis
HEALTHCHECK CMD ["redis-cli", "ping"]

# Generic TCP check
HEALTHCHECK CMD ["bash", "-c", "echo > /dev/tcp/localhost/8080"]
```

### Layer Optimization

```dockerfile
# SLOW — source code change invalidates dependency cache
FROM node:22-slim
WORKDIR /app
COPY . .
RUN npm ci --production
CMD ["node", "server.js"]

# FIXED — dependencies cached separately from source
FROM node:22-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --production
COPY . .
CMD ["node", "server.js"]
```

### RUN Instruction Hygiene

```dockerfile
# MEDIUM — each RUN creates a layer, apt cache left behind
RUN apt-get update
RUN apt-get install -y curl
RUN apt-get install -y wget

# FIXED — single layer, cache cleaned
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        wget && \
    rm -rf /var/lib/apt/lists/*
```

### .dockerignore

Every project with a Dockerfile must have a `.dockerignore`. Missing or insufficient
`.dockerignore` is a MEDIUM finding.

Minimum contents:
```
.git
.github
.gitignore
node_modules
npm-debug.log
*.md
!README.md
.env
.env.*
*.pem
*.key
id_rsa*
docker-compose*.yml
Dockerfile*
.dockerignore
__pycache__
*.pyc
.pytest_cache
.coverage
.vscode
.idea
tests/
docs/
```

---

## Docker Compose Patterns

### Security Hardening

```yaml
# CRITICAL — no security controls
services:
  app:
    image: myapp
    ports:
      - "3000:3000"
    privileged: true
    network_mode: host

# FIXED — hardened service definition
services:
  app:
    image: myapp:1.2.3@sha256:abc123
    ports:
      - "127.0.0.1:3000:3000"  # Bind to localhost only — reverse proxy handles public
    read_only: true
    tmpfs:
      - /tmp
      - /var/run
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE  # Only if binding to ports < 1024
    user: "1000:1000"
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
          pids: 100
        reservations:
          cpus: '0.25'
          memory: 128M
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks:
      - frontend
```

### Network Segmentation

```yaml
# HIGH — all services on default network, DB exposed
services:
  nginx:
    ports:
      - "80:80"
      - "443:443"
  app:
    ports:
      - "3000:3000"
  db:
    ports:
      - "5432:5432"  # DB exposed to host!

# FIXED — isolated networks, DB not exposed
services:
  nginx:
    ports:
      - "80:80"
      - "443:443"
    networks:
      - frontend

  app:
    # No host ports — only reachable via nginx
    expose:
      - "3000"
    networks:
      - frontend
      - backend

  db:
    # No host ports — only reachable by app
    expose:
      - "5432"
    networks:
      - backend
    volumes:
      - db_data:/var/lib/postgresql/data

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true  # No external access at all

volumes:
  db_data:
```

### Secrets Handling

```yaml
# CRITICAL — secrets inline in compose file
services:
  app:
    environment:
      - DB_PASSWORD=supersecret123
      - API_KEY=sk-abc123

# MEDIUM — .env file (OK for dev, not for prod)
services:
  app:
    env_file:
      - .env  # Must be in .gitignore!

# BEST — Docker secrets (requires swarm or compose v2 secrets support)
services:
  app:
    secrets:
      - db_password
      - api_key
    environment:
      - DB_PASSWORD_FILE=/run/secrets/db_password

secrets:
  db_password:
    file: ./secrets/db_password.txt  # This file must not be committed
  api_key:
    external: true  # Managed outside compose
```

### Port Binding

```yaml
# HIGH — binds to all interfaces, DB accessible from internet
services:
  db:
    ports:
      - "5432:5432"       # 0.0.0.0:5432 — public!
  redis:
    ports:
      - "6379:6379"       # 0.0.0.0:6379 — public!
  app:
    ports:
      - "3000:3000"       # 0.0.0.0:3000 — public (maybe OK if no reverse proxy)

# FIXED — localhost only for services behind reverse proxy
services:
  db:
    # No ports — only accessible via Docker network
    expose:
      - "5432"
  redis:
    expose:
      - "6379"
  app:
    ports:
      - "127.0.0.1:3000:3000"  # Only accessible from host, reverse proxy forwards
```

### Volume Security

```yaml
# HIGH — host docker socket mounted (container escape vector)
services:
  app:
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock  # CRITICAL — full host access

# HIGH — sensitive host paths mounted
services:
  app:
    volumes:
      - /etc:/host-etc           # Access to host /etc/shadow, /etc/passwd
      - /:/host-root             # Full host filesystem

# MEDIUM — bind mount with no read-only where possible
services:
  app:
    volumes:
      - ./config:/app/config     # Writable — should it be?

# FIXED — minimal, explicit, read-only where possible
services:
  app:
    volumes:
      - ./config:/app/config:ro          # Read-only config
      - app_data:/app/data               # Named volume for persistent data
      - type: tmpfs                       # Temp storage in memory
        target: /tmp

volumes:
  app_data:
    driver: local
```

### Compose File Version & Structure

```yaml
# OUTDATED — legacy version key
version: "3.8"
services:
  app:
    build: .

# CURRENT — Compose Specification (no version key needed)
# Docker Compose v2+ uses Compose Specification by default
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        - BUILD_ENV=production
```

### Complete Hardened Compose Example

A reference template for a typical web application stack:

```yaml
# docker-compose.prod.yml
services:
  reverse-proxy:
    image: caddy:2.7.6-alpine@sha256:...
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    read_only: true
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: [no-new-privileges:true]
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 256M
    restart: unless-stopped
    networks:
      - frontend
    healthcheck:
      test: ["CMD", "caddy", "version"]
      interval: 30s
      timeout: 5s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  app:
    image: myapp:1.2.3@sha256:...
    expose:
      - "3000"
    read_only: true
    tmpfs:
      - /tmp
    user: "1000:1000"
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    env_file:
      - .env.prod
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
          pids: 100
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - frontend
      - backend
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"

  db:
    image: postgres:16.1-alpine@sha256:...
    expose:
      - "5432"
    volumes:
      - db_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    security_opt: [no-new-privileges:true]
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
    shm_size: 256m
    restart: unless-stopped
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  redis:
    image: redis:7.2.4-alpine@sha256:...
    expose:
      - "6379"
    command: >
      redis-server
      --maxmemory 128mb
      --maxmemory-policy allkeys-lru
      --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 256M
    restart: unless-stopped
    networks:
      - backend
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "3"

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true

volumes:
  caddy_data:
  caddy_config:
  db_data:
  redis_data:

secrets:
  db_password:
    file: ./secrets/db_password.txt
```

---

## Docker Security Scanning

Recommend these tools in the review report when relevant:

| Tool | What It Does | Integration Point |
|------|-------------|-------------------|
| `docker scout` | Image vulnerability scanning | CI or local |
| `trivy` | Image + filesystem + IaC scanning | GitHub Actions |
| `hadolint` | Dockerfile linting | GitHub Actions, pre-commit |
| `dockle` | Container image security audit | CI |
| `docker-bench-security` | CIS Docker Benchmark checks | Runtime audit |

GitHub Actions integration example:
```yaml
- name: Lint Dockerfile
  uses: hadolint/hadolint-action@v3.1.0  # Pin by SHA in real usage
  with:
    dockerfile: Dockerfile

- name: Scan image
  uses: aquasecurity/trivy-action@master  # Pin by SHA in real usage
  with:
    image-ref: myapp:${{ github.sha }}
    severity: CRITICAL,HIGH
    exit-code: 1
```
