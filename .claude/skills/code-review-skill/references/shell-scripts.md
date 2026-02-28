# Shell Script Standards & Migration Reference

When to keep shell, when to migrate, and how to write safe shell when it stays.

---

## Migration Decision Framework

Ask these questions about each shell script:

```
1. Is it under 30 lines with no complex logic?        → Keep as shell
2. Does it manage server/system configuration?         → Migrate to Ansible
3. Does it orchestrate builds or task dependencies?    → Migrate to Makefile / Taskfile
4. Does it make API calls, parse JSON/YAML, or        → Migrate to Python
   handle complex error recovery?
5. Does it deploy code to servers?                     → Migrate to GitHub Actions + Ansible
6. Is it a Docker entrypoint doing env setup?          → Keep as shell (keep minimal)
```

### Migration Priority Matrix

| Signal | Priority |
|--------|----------|
| Script > 100 lines | HIGH — almost certainly should migrate |
| Script installs packages or configures services | HIGH → Ansible |
| Script has `curl` + JSON parsing with `jq`/`grep` | HIGH → Python |
| Script has retry logic, error recovery | HIGH → Python or Ansible |
| Script is a `cron` job doing data work | MEDIUM → Python |
| Script wraps a single command with env setup | LOW — keep as shell |
| Script is a container entrypoint | LOW — keep as shell |

### Migration Examples

#### Shell → Ansible (Server Config)

```bash
# BEFORE: setup-server.sh (150 lines, fragile, not idempotent)
#!/bin/bash
apt-get update
apt-get install -y nginx certbot docker.io
useradd -m deploy
mkdir -p /opt/app
chown deploy:deploy /opt/app
cp nginx.conf /etc/nginx/sites-available/default
systemctl restart nginx
ufw allow 80
ufw allow 443
ufw allow 22
ufw --force enable
```

```yaml
# AFTER: roles/server-setup/tasks/main.yml
- name: Install required packages
  ansible.builtin.apt:
    name:
      - nginx
      - certbot
      - docker.io
    state: present
    update_cache: true

- name: Create deploy user
  ansible.builtin.user:
    name: deploy
    create_home: true

- name: Create application directory
  ansible.builtin.file:
    path: /opt/app
    state: directory
    owner: deploy
    group: deploy
    mode: '0755'

- name: Deploy nginx config
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/sites-available/default
  notify: Restart nginx

- name: Configure firewall
  community.general.ufw:
    rule: allow
    port: "{{ item }}"
  loop: ["80", "443", "22"]

- name: Enable firewall
  community.general.ufw:
    state: enabled
```

Benefits: idempotent, testable with `--check`, self-documenting, handles errors properly.

#### Shell → Makefile/Taskfile (Build Automation)

```bash
# BEFORE: build.sh
#!/bin/bash
echo "Linting..."
npm run lint
echo "Testing..."
npm test
echo "Building..."
docker build -t myapp:latest .
echo "Pushing..."
docker push myapp:latest
```

```makefile
# AFTER: Makefile
.PHONY: lint test build push deploy

IMAGE := myapp
TAG := $(shell git rev-parse --short HEAD)

lint:
	npm run lint

test:
	npm test

build: lint test
	docker build -t $(IMAGE):$(TAG) .

push: build
	docker push $(IMAGE):$(TAG)

deploy: push
	ssh deploy@server "cd /opt/app && IMAGE_TAG=$(TAG) docker compose up -d"
```

Or with Taskfile (go-task):
```yaml
# Taskfile.yml
version: '3'

vars:
  IMAGE: myapp
  TAG:
    sh: git rev-parse --short HEAD

tasks:
  lint:
    cmds:
      - npm run lint

  test:
    cmds:
      - npm test

  build:
    deps: [lint, test]
    cmds:
      - docker build -t {{.IMAGE}}:{{.TAG}} .

  push:
    deps: [build]
    cmds:
      - docker push {{.IMAGE}}:{{.TAG}}

  deploy:
    deps: [push]
    cmds:
      - ssh deploy@server "cd /opt/app && IMAGE_TAG={{.TAG}} docker compose up -d"
```

Benefits: dependency graphs, incremental execution, parallel tasks, self-documenting.

#### Shell → Python (Complex Logic)

```bash
# BEFORE: backup.sh (80 lines, brittle, hard to debug)
#!/bin/bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/${TIMESTAMP}"
mkdir -p "${BACKUP_DIR}"

# Dump database
docker exec db pg_dump -U postgres mydb > "${BACKUP_DIR}/db.sql"
if [ $? -ne 0 ]; then
  echo "DB backup failed"
  # Try to send alert... with curl and json...
  curl -X POST https://hooks.slack.com/... \
    -H 'Content-Type: application/json' \
    -d "{\"text\": \"Backup failed at ${TIMESTAMP}\"}"
  exit 1
fi

# Compress
tar czf "${BACKUP_DIR}.tar.gz" "${BACKUP_DIR}"
rm -rf "${BACKUP_DIR}"

# Rotate old backups (keep last 7)
ls -t /backups/*.tar.gz | tail -n +8 | xargs rm -f

# Upload to S3
aws s3 cp "${BACKUP_DIR}.tar.gz" "s3://backups/db/"
```

```python
# AFTER: backup.py
"""Database backup with rotation, compression, and alerting."""

import subprocess
import sys
from datetime import datetime
from pathlib import Path
import json
import urllib.request
import shutil

BACKUP_ROOT = Path("/backups")
RETENTION_COUNT = 7
S3_BUCKET = "s3://backups/db/"
SLACK_WEBHOOK = None  # Set via environment variable

def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Run a command with error handling."""
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs)

def dump_database(output_path: Path) -> None:
    """Dump PostgreSQL database from Docker container."""
    result = run(["docker", "exec", "db", "pg_dump", "-U", "postgres", "mydb"])
    output_path.write_text(result.stdout)

def compress(source: Path, target: Path) -> None:
    """Compress directory to tar.gz."""
    shutil.make_archive(str(target.with_suffix("")), "gztar", source.parent, source.name)

def rotate_backups(directory: Path, keep: int) -> None:
    """Remove oldest backups, keeping the most recent `keep` files."""
    backups = sorted(directory.glob("*.tar.gz"), key=lambda p: p.stat().st_mtime, reverse=True)
    for old_backup in backups[keep:]:
        old_backup.unlink()

def upload_to_s3(local_path: Path, s3_path: str) -> None:
    """Upload file to S3."""
    run(["aws", "s3", "cp", str(local_path), s3_path])

def notify_slack(message: str) -> None:
    """Send Slack notification."""
    webhook = os.environ.get("SLACK_WEBHOOK_URL")
    if not webhook:
        return
    data = json.dumps({"text": message}).encode()
    req = urllib.request.Request(webhook, data=data, headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req)

def main() -> int:
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_dir = BACKUP_ROOT / timestamp
    backup_dir.mkdir(parents=True, exist_ok=True)

    try:
        dump_database(backup_dir / "db.sql")
        archive = BACKUP_ROOT / f"{timestamp}.tar.gz"
        compress(backup_dir, archive)
        shutil.rmtree(backup_dir)
        upload_to_s3(archive, S3_BUCKET)
        rotate_backups(BACKUP_ROOT, RETENTION_COUNT)
        return 0
    except subprocess.CalledProcessError as e:
        notify_slack(f"Backup failed: {e.stderr}")
        return 1
    except Exception as e:
        notify_slack(f"Backup error: {e}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
```

Benefits: proper error handling, testable functions, type hints, maintainable, no quoting issues.

---

## Shell Standards (When Shell Is Kept)

### Required Header

Every bash script must start with:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Description: Brief description of what this script does
# Usage: script.sh [options] <arguments>
# Dependencies: docker, jq (list external dependencies)
```

### Variable Quoting

```bash
# CRITICAL — unquoted variables enable injection
rm -rf $DEPLOY_DIR/*        # If DEPLOY_DIR is empty: rm -rf /*
cd $SOME_PATH               # Word splitting on spaces in path

# FIXED — always double-quote
rm -rf "${DEPLOY_DIR:?}"/*  # :? fails if unset instead of expanding to /
cd "${SOME_PATH}"
```

### Input Validation

```bash
# HIGH — no input validation
deploy_to() {
    local target=$1
    ssh root@"${target}" "rm -rf /opt/app && tar xzf -"
}
deploy_to "$1"  # What if $1 is "; rm -rf /"?

# FIXED — validate inputs
deploy_to() {
    local target="${1:?Error: target host required}"

    # Validate hostname format
    if [[ ! "${target}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Error: invalid hostname '${target}'" >&2
        return 1
    fi

    ssh "deploy@${target}" "cd /opt/app && docker compose up -d"
}
```

### Error Handling with trap

```bash
# Template: cleanup on exit
cleanup() {
    local exit_code=$?
    # Remove temp files
    rm -f "${TEMP_FILE:-}"
    # Remove SSH key if we created one
    rm -f "${SSH_KEY_FILE:-}"
    exit "${exit_code}"
}
trap cleanup EXIT

TEMP_FILE="$(mktemp)"
# ... script body ...
```

### Logging Function

```bash
# Instead of scattered echo statements:
log() {
    local level="${1}"
    shift
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [${level}] $*" >&2
}

log INFO "Starting deployment"
log ERROR "Connection failed to ${HOST}"
log WARN "Retrying in 5 seconds"
```

### Function Pattern

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

usage() {
    cat << EOF >&2
Usage: ${SCRIPT_NAME} <environment>

Deploy application to the specified environment.

Arguments:
    environment    Target environment (staging|production)

Environment variables:
    DEPLOY_HOST    Target host (required)
    SSH_KEY_FILE   Path to SSH key (default: ~/.ssh/id_ed25519)
EOF
    exit 1
}

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >&2
}

validate_environment() {
    local env="${1}"
    case "${env}" in
        staging|production) return 0 ;;
        *) log "ERROR: Invalid environment '${env}'"; return 1 ;;
    esac
}

deploy() {
    local environment="${1}"
    local host="${DEPLOY_HOST:?DEPLOY_HOST is required}"
    local ssh_key="${SSH_KEY_FILE:-${HOME}/.ssh/id_ed25519}"

    log "Deploying to ${environment} on ${host}"
    ssh -i "${ssh_key}" "deploy@${host}" \
        "cd /opt/app && docker compose pull && docker compose up -d"
    log "Deployment complete"
}

main() {
    [[ $# -lt 1 ]] && usage
    validate_environment "${1}"
    deploy "${1}"
}

main "$@"
```

---

## ShellCheck Integration

Add to CI:
```yaml
# GitHub Actions
- name: ShellCheck
  uses: ludeeus/action-shellcheck@SHA
  with:
    scandir: './scripts'
    severity: warning

# Or in Makefile
lint-shell:
	find . -name '*.sh' -exec shellcheck {} +
```

Critical ShellCheck codes to always fix:

| Code | Issue | Severity |
|------|-------|----------|
| SC1091 | Not following sourced file | INFO |
| SC2006 | Use `$()` instead of backticks | MEDIUM |
| SC2034 | Variable appears unused | LOW |
| SC2046 | Quote to prevent word splitting | HIGH |
| SC2086 | Double quote to prevent globbing | HIGH |
| SC2091 | Remove surrounding `$()` | MEDIUM |
| SC2115 | Use `"${var:?}"` to avoid empty rm -rf | CRITICAL |
| SC2155 | Declare and assign separately | MEDIUM |
| SC2164 | Use `cd ... || exit` | HIGH |
| SC2181 | Check exit code directly, not via `$?` | LOW |
| SC2312 | Consider invoking separately to check exit codes | MEDIUM |
