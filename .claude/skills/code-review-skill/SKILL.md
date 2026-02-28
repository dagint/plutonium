---
name: infra-code-review
description: >
  Security-first code review for infrastructure-as-code deployments to VPS environments.
  Covers GitHub Actions CI/CD pipelines, Ansible playbooks, Docker/Docker Compose,
  shell scripts, and general IaC. Produces structured review reports with severity-rated
  findings across security, coding standards, and performance dimensions.
  Use when reviewing PRs, auditing repos, or evaluating deployment code quality.
---

# Infrastructure Code Review Skill

Perform security-focused, standards-aware code reviews on infrastructure deployment code
targeting VPS environments. Reviews cover GitHub Actions workflows, Ansible playbooks and
roles, Dockerfiles and Compose files, shell scripts, and supporting IaC.

---

## When to Use This Skill

Trigger this skill when the user asks you to:

- Review a pull request or repo containing infrastructure/deployment code
- Audit the security posture of a deployment pipeline
- Check Docker, Ansible, GitHub Actions, or shell scripts for best practices
- Evaluate whether deployment code meets production-readiness standards
- Migrate shell scripts toward more maintainable alternatives
- Harden a VPS deployment workflow

---

## Reference Files

Before starting any review, read the relevant reference files for detailed patterns:

| Reference | Path | Use When |
|-----------|------|----------|
| Docker & Compose | `references/docker.md` | Any Dockerfile or docker-compose.yml present |
| GitHub Actions | `references/github-actions.md` | Any `.github/workflows/` files present |
| Ansible Hardening | `references/ansible-hardening.md` | Any Ansible playbooks or roles present |
| Shell Scripts | `references/shell-scripts.md` | Any `.sh` files present; also consult for migration recommendations |
| Secrets Management | `references/secrets-management.md` | Always — secrets review is cross-cutting |
| Severity Guide | `references/severity-guide.md` | Always — use for consistent severity classification |

Read ALL applicable reference files before writing the review report. The reference
files contain concrete vulnerable/fixed code patterns that should be matched against
the code under review.

---

## Review Process

Follow this sequence for every review:

### 1. Inventory

Before reviewing any file, inventory the full codebase to understand the deployment architecture:

```
Scan for:
  .github/workflows/*.yml          → CI/CD pipelines
  *.yml / *.yaml (Ansible)         → Playbooks, roles, inventories
  Dockerfile / Dockerfile.*        → Container images
  docker-compose*.yml              → Service orchestration
  *.sh / *.bash                    → Shell scripts
  .env* / *.env                    → Environment files (should NOT be committed)
  secrets/ / vault/ / *vault*.yml  → Secrets management
  terraform/ / *.tf                → Terraform (if present)
  Makefile                         → Build automation
  nginx/ / caddy/ / traefik/       → Reverse proxy configs
  fail2ban/ / ufw/ / iptables/     → Firewall configs
```

Build a mental map: what gets deployed, how it gets there, what runs on the VPS, how
secrets flow from source to runtime.

### 2. Review by Domain

Review each file through all three lenses (security, standards, performance) but
use the domain-specific checklists below as your primary guide.

### 3. Produce the Report

Output a structured report (format defined in the Report Format section below).

---

## Domain: GitHub Actions Workflows

### Security

- **Secrets exposure**: Secrets must NEVER appear in logs. Check for `echo ${{ secrets.* }}`,
  debug mode enabling with secrets in env, or secrets passed as command-line arguments
  (visible in /proc). Prefer passing secrets via environment variables or stdin.
- **Pin actions by SHA, not tag**: `uses: actions/checkout@v4` is vulnerable to tag
  hijacking. Require full SHA: `uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11`.
  The only exception is first-party GitHub actions (actions/*) which are lower risk but
  still best pinned.
- **Limit permissions**: Every workflow and job should declare explicit `permissions` with
  minimum scope. Default `permissions: {}` at workflow level, then grant per-job.
  Flag any workflow missing the `permissions` key.
- **Avoid `pull_request_target` with checkout of PR code**: This is a critical injection
  vector. If used, the workflow must NOT checkout or execute PR branch code.
- **Expression injection**: Flag any use of `${{ github.event.*.title }}`,
  `${{ github.event.*.body }}`, `${{ github.event.*.email }}`, or similar user-controlled
  inputs directly in `run:` blocks. These enable arbitrary command injection. Require
  passing through an environment variable instead.
- **Self-hosted runner isolation**: If self-hosted runners are used, verify they are
  ephemeral (spun up/destroyed per job) or at minimum have no persistent credentials.
  Flag shared, long-lived self-hosted runners as HIGH severity.
- **OIDC over long-lived credentials**: For cloud provider auth, prefer OIDC
  (`aws-actions/configure-aws-credentials` with `role-to-assume`) over stored
  access keys.
- **Workflow dispatch inputs**: Validate and sanitize any `workflow_dispatch` inputs
  before use in scripts.
- **Third-party action audit**: Any non-GitHub-official action should be reviewed.
  Flag actions from unknown publishers or with low star counts. Prefer well-known,
  actively-maintained actions.
- **Deployment credentials**: SSH keys, API tokens, and deployment credentials must come
  from GitHub Secrets (or an external vault) — never hardcoded, never in repo.

### Standards

- **Naming**: Workflows should have a descriptive `name:`. Jobs and steps should also
  have `name:` fields for readability.
- **DRY**: Repeated step sequences across workflows should be extracted into composite
  actions or reusable workflows (`workflow_call`).
- **Conditional logic**: Complex `if:` conditions should be commented or extracted.
- **Timeouts**: Every job should have `timeout-minutes` set to prevent hung jobs consuming
  runner minutes.
- **Concurrency**: Deployment workflows should use `concurrency` groups to prevent
  parallel deploys to the same environment.
- **Environment protection**: Production deploys should use GitHub Environments with
  required reviewers and/or wait timers.

### Performance

- **Cache dependencies**: Use `actions/cache` or built-in caching (e.g.,
  `actions/setup-node` with `cache: 'npm'`) for package managers.
- **Minimize checkout depth**: Use `fetch-depth: 1` for shallow clones unless full
  history is needed.
- **Parallel jobs**: Independent tasks (lint, test, build) should run as separate
  parallel jobs, not sequential steps.
- **Conditional runs**: Use path filters (`paths:`, `paths-ignore:`) to skip workflows
  when irrelevant files change.

---

## Domain: Ansible Playbooks & Roles

### Security — VPS Hardening Baseline

Every Ansible-managed VPS should enforce these controls. Flag any that are missing:

- **SSH hardening**:
  - `PermitRootLogin no`
  - `PasswordAuthentication no` (key-only)
  - `Port` changed from 22 (or justified if kept)
  - `AllowUsers` or `AllowGroups` restricting SSH access
  - `MaxAuthTries` set to a low value (3-5)
  - `LoginGraceTime` reduced
  - SSH host keys regenerated from provider defaults
- **Firewall**: UFW or iptables/nftables configured with default-deny ingress.
  Only explicitly required ports open. Flag any rule allowing 0.0.0.0/0 on non-web ports.
- **fail2ban**: Installed and configured for SSH at minimum. Ideally also covering
  any exposed web services.
- **Automatic security updates**: `unattended-upgrades` (Debian/Ubuntu) or equivalent
  configured for security patches.
- **User management**: Dedicated deploy user with sudo access (NOPASSWD only for
  specific deployment commands, not blanket). No shared accounts.
- **Filesystem**: `/tmp` and `/var/tmp` mounted noexec where possible. Sensitive
  directories have restrictive permissions.
- **Kernel hardening**: sysctl settings for `net.ipv4.conf.all.rp_filter`,
  `net.ipv4.icmp_echo_ignore_broadcasts`, `kernel.randomize_va_space`, etc.
- **Audit logging**: auditd or equivalent installed and logging auth events.
- **Time sync**: NTP/chronyd configured for accurate log timestamps.

### Security — Ansible-Specific

- **Ansible Vault**: Any secrets (passwords, API keys, private keys) must be encrypted
  with `ansible-vault`. Flag plaintext secrets in variables, inventories, or group_vars.
  Vault password should come from a file or environment variable, never committed.
- **become/sudo**: `become: yes` should be used only on tasks that require it, not
  at the play level unless the entire play genuinely requires root.
- **No shell/command for package management**: Use `ansible.builtin.apt`,
  `ansible.builtin.yum`, etc. instead of `shell: apt-get install`. The `shell` and
  `command` modules bypass Ansible's idempotency guarantees.
- **Idempotency**: Every task should be safe to run multiple times. Flag tasks using
  `shell`/`command` without `creates`, `removes`, or `changed_when`.
- **Check mode support**: Playbooks should work with `--check` (dry run). Flag tasks
  that would fail in check mode without `when: not ansible_check_mode`.
- **No `ignore_errors: yes`** unless there's a documented, legitimate reason and
  subsequent error handling.
- **Template security**: Jinja2 templates should not construct shell commands from
  variables without validation.

### Standards

- **FQCN (Fully Qualified Collection Names)**: Use `ansible.builtin.copy` not `copy`.
  This is the modern Ansible standard and avoids ambiguity with custom modules.
- **Role structure**: Follow standard role directory layout
  (`tasks/`, `handlers/`, `templates/`, `defaults/`, `vars/`, `meta/`).
- **Variable naming**: Prefix role variables with the role name to avoid collisions
  (e.g., `ssh_port` not `port`).
- **Tags**: All tasks should be tagged for selective execution.
- **Handlers**: Use handlers for service restarts/reloads, not inline `shell: systemctl restart`.
- **Linting**: Playbooks should pass `ansible-lint` with no errors. Recommend adding
  ansible-lint to CI.

### Performance

- **Gather facts selectively**: Use `gather_facts: no` when facts aren't needed, or
  `gather_subset` to limit collection.
- **Free strategy**: For independent host operations, consider `strategy: free`.
- **Async tasks**: Long-running tasks (large package installs, file transfers) should
  use `async` with `poll`.
- **Pipelining**: Enable `pipelining = True` in ansible.cfg (after confirming `requiretty`
  is disabled in sudoers).

---

## Domain: Docker & Docker Compose

### Security

- **Non-root user**: Dockerfiles must create and switch to a non-root user via `USER`.
  Flag any image that runs as root in production.
- **Base image provenance**: Use official images or verified publishers. Pin to a
  specific digest or at minimum a specific version tag — never `latest`.
  Example: `FROM python:3.12.1-slim-bookworm@sha256:abcd...`
- **Multi-stage builds**: Build dependencies (compilers, dev headers, build tools) must
  not be present in the final runtime image. Use multi-stage builds to separate
  build and runtime stages.
- **No secrets in images**: Flag any `COPY` of `.env` files, private keys, or credentials
  into images. Use Docker secrets, runtime environment variables, or mounted volumes.
  Check for secrets in `ENV` instructions, `ARG` instructions (visible in image history),
  and `RUN` commands that fetch credentials.
- **Read-only root filesystem**: Production containers should use `read_only: true` in
  Compose with explicit `tmpfs` mounts for directories that need writes.
- **Capability dropping**: Use `cap_drop: [ALL]` and selectively add only needed
  capabilities with `cap_add`.
- **No privileged mode**: Flag `privileged: true` as CRITICAL unless there's an
  extremely well-documented reason.
- **Security options**: Apply `no-new-privileges:true` via `security_opt`.
- **Network segmentation**: Services should be on isolated Docker networks. Only
  services that need to communicate should share a network. The database should NOT
  be on the same network as the public-facing reverse proxy.
- **Exposed ports**: Only expose ports that need host binding. Use `expose` (inter-container)
  vs `ports` (host-bound) appropriately. Bind to `127.0.0.1:port:port` instead of
  `0.0.0.0:port:port` unless the service needs external access.
- **Health checks**: All services should have `HEALTHCHECK` in Dockerfile or
  `healthcheck` in Compose.
- **Resource limits**: Set `mem_limit`, `cpus`, and `pids_limit` in Compose to prevent
  container resource exhaustion.
- **No `host` network mode** for application containers (breaks network isolation).

### Standards

- **`.dockerignore`**: Must exist and exclude `.git`, `node_modules`, `*.env`, secrets,
  build artifacts, documentation, and tests.
- **Layer optimization**: Order Dockerfile instructions from least-frequently-changed
  to most-frequently-changed. Copy dependency manifests before source code.
- **One process per container**: Each container should run one primary process.
  Flag containers running multiple services via supervisord or similar.
- **Labels**: Use OCI-standard labels (`org.opencontainers.image.*`) for image metadata.
- **Compose file version**: Use Compose Specification (no `version:` key) for modern
  Docker Compose. Flag `version: "2"` or `version: "3"` as outdated.
- **Named volumes**: Use named volumes for persistent data, not bind mounts to
  random host paths.
- **Restart policy**: Production services should have `restart: unless-stopped` or
  `restart: always`.

### Performance

- **Image size**: Flag images based on full OS distributions (ubuntu, debian) when
  slim or alpine alternatives exist. Smaller images = faster pulls, less attack surface.
- **Layer caching**: Ensure dependency installation (pip install, npm install) happens
  before source code copy to maximize cache hits.
- **Build args for cache busting**: Use `ARG` for version-specific cache invalidation
  rather than disabling cache entirely.
- **Compose startup order**: Use `depends_on` with `condition: service_healthy` for
  proper startup sequencing.
- **Logging driver**: Configure appropriate logging driver and set `max-size` and
  `max-file` options to prevent log-driven disk exhaustion.

---

## Domain: Shell Scripts

### Shell Script Migration Guidance

Shell scripts are appropriate for simple glue tasks (< 50 lines, no complex logic).
For anything more complex, recommend migration to one of these alternatives based
on the use case:

| Use Case | Recommended Alternative | Why |
|----------|------------------------|-----|
| Server provisioning / config | **Ansible** | Idempotent, declarative, handles state |
| Build / task automation | **Makefile** or **Taskfile (go-task)** | Dependency graphs, incremental builds |
| Deployment orchestration | **GitHub Actions** or **Ansible** | Audit trail, rollback, approvals |
| Complex scripting (parsing, API calls, data) | **Python** | Error handling, libraries, testability |
| Container entrypoints | **Shell (bash/sh)** | Acceptable — keep minimal |
| Simple wrappers (< 20 lines) | **Shell (bash/sh)** | Acceptable — not worth migrating |

When shell scripts ARE used (entrypoints, simple wrappers), enforce these standards:

### Security

- **No secrets in scripts**: Flag any hardcoded passwords, API keys, tokens, or
  private key material. Use environment variables or a secrets manager.
- **Validate all inputs**: Flag scripts that use `$1`, `$2`, etc. without validation.
  All user/external input must be validated before use.
- **Quote all variables**: `"$variable"` not `$variable`. Unquoted variables enable
  word splitting and glob expansion attacks.
- **No `eval`**: Flag any use of `eval` as HIGH severity. It enables arbitrary code
  execution from variable content.
- **Avoid `curl | bash`**: Flag piping remote scripts directly to bash. Download,
  verify checksum, then execute.
- **Temporary files**: Use `mktemp` for temp files, not predictable paths like
  `/tmp/myapp.tmp` (symlink attacks). Clean up with `trap`.
- **umask**: Set restrictive `umask 077` at script start for any script creating files.
- **Path injection**: Use absolute paths for critical binaries (`/usr/bin/curl` not `curl`)
  or set `PATH` explicitly at script start.

### Standards

- **Shebang**: Every script must start with `#!/usr/bin/env bash` (or `#!/bin/sh` for
  POSIX scripts). Flag missing shebangs.
- **Strict mode**: Every bash script should begin with:
  ```bash
  set -euo pipefail
  ```
  - `set -e`: Exit on error
  - `set -u`: Error on undefined variables
  - `set -o pipefail`: Catch pipeline failures
  Flag any script missing this as MEDIUM severity.
- **ShellCheck compliance**: All scripts should pass ShellCheck with no warnings.
  Recommend adding ShellCheck to CI. Specific SC codes to watch for:
  - SC2086: Double-quote to prevent globbing
  - SC2046: Quote to prevent word splitting
  - SC2006: Use `$()` not backticks
  - SC2164: Use `cd ... || exit` in case cd fails
- **Functions**: Scripts over 30 lines should use functions with descriptive names.
  A `main()` function pattern is preferred.
- **Error handling**: Use `trap` for cleanup. Provide meaningful error messages with
  context (what failed, what to do about it).
- **Logging**: Use a consistent logging function that writes to stderr with timestamps
  and severity levels, not scattered `echo` statements.
- **Exit codes**: Use meaningful exit codes, not just 0/1. Document expected exit
  codes in script header comments.
- **No bashisms in sh scripts**: If the shebang is `#!/bin/sh`, the script must be
  POSIX-compliant. No arrays, `[[`, `(( ))`, `local`, etc.

### Performance

- **Avoid subshells in loops**: `$(command)` inside loops creates a subshell per
  iteration. Batch operations where possible.
- **Use built-in string operations**: Prefer `${var%pattern}`, `${var#pattern}` over
  spawning `sed`/`awk` for simple substitutions.
- **Prefer `printf` over `echo`**: `printf` is more portable and predictable.

---

## Domain: Secrets Management (Cross-Cutting)

This applies across ALL domains. Review the full secrets lifecycle:

### Storage

- **No plaintext secrets in repos**: Scan for `.env` files, hardcoded passwords,
  API keys, private keys, tokens in ANY file. Flag as CRITICAL.
- **`.gitignore` coverage**: Verify `.env`, `*.pem`, `*.key`, `id_rsa*`, `*.p12`,
  `vault_password*` are gitignored.
- **Git history**: If secrets were ever committed, flag that rotating them is required —
  removing from HEAD is insufficient.

### Transit

- **Encrypted channels only**: Secrets must reach the VPS via encrypted channels
  (SSH, TLS, Ansible Vault). Flag any mechanism that transmits secrets in the clear.
- **GitHub Secrets → Runner → VPS**: The chain should be
  `GitHub Secrets → env var in workflow → SSH/SCP with key → env var on VPS`.
  Flag any step where secrets are written to files on the runner or logged.

### Runtime

- **Environment variables or mounted secrets**: Secrets at runtime should come from
  environment variables (via Compose `env_file` or Docker secrets) — not baked into
  images and not stored in files inside containers.
- **Docker secrets**: For Swarm or containers that support it, prefer Docker secrets
  (`/run/secrets/`) over environment variables (which can leak via `/proc`,
  `docker inspect`, or error messages).
- **Rotation plan**: Flag if there's no evidence of credential rotation capability.
  Deployment credentials, API keys, and TLS certificates should all be rotatable
  without downtime.

---

## Domain: Networking & TLS (VPS)

- **TLS termination**: Verify TLS is terminated at the reverse proxy (nginx, Caddy,
  Traefik). All public endpoints must be HTTPS-only.
- **TLS configuration**: TLS 1.2+ only. No SSLv3, TLS 1.0, or TLS 1.1.
  Strong cipher suites. HSTS header configured.
- **Certificate management**: Prefer automated ACME/Let's Encrypt via Certbot or
  Caddy's built-in. Flag manual certificate management.
- **Reverse proxy headers**: `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`
  properly set. `Host` header validated.
- **Rate limiting**: Some form of rate limiting on public endpoints (nginx `limit_req`,
  Traefik middleware, application-level).
- **Internal communication**: Services behind the reverse proxy should communicate
  over Docker's internal network, not via the public interface.

---

## Report Format

Structure every review report as follows. Use severity ratings consistently:

**Severity Levels:**
- **CRITICAL**: Exploitable vulnerability, secret exposure, or misconfiguration that
  could lead to immediate compromise. Must fix before deploy.
- **HIGH**: Significant security weakness or serious standards violation that materially
  increases risk. Fix before production use.
- **MEDIUM**: Best practice violation that increases attack surface or reduces
  maintainability. Should fix in near term.
- **LOW**: Minor improvement opportunity. Nice to have.
- **INFO**: Observation, suggestion, or compliment. No action required.

### Report Structure

```markdown
# Infrastructure Code Review

## Summary
<!-- 2-3 sentence overview: what was reviewed, overall assessment, top concern -->

## Architecture Overview
<!-- Brief description of the deployment flow as understood from the code:
     Source → CI/CD → Build → Deploy → Runtime
     Note any gaps in the chain that couldn't be reviewed -->

## Critical & High Findings
<!-- These go first — they block deployment -->

### [CRITICAL] Finding Title
- **File**: `path/to/file:line`
- **Category**: Security | Standards | Performance
- **Issue**: What's wrong and why it matters
- **Impact**: What could happen if this isn't fixed
- **Fix**: Specific remediation with code example
```suggestion
# Before (vulnerable)
...
# After (fixed)
...
```

## Medium & Low Findings
<!-- Same format as above, grouped by domain -->

## Shell Script Migration Candidates
<!-- List shell scripts that should be migrated, with recommended target -->
| Script | Lines | Complexity | Recommended Migration | Priority |
|--------|-------|-----------|----------------------|----------|
| deploy.sh | 200 | High (API calls, error handling) | Ansible playbook | HIGH |
| backup.sh | 45 | Medium (cron, rotation) | Ansible role | MEDIUM |
| entrypoint.sh | 15 | Low (env setup) | Keep as shell | — |

## Positive Observations
<!-- What's done well — reinforces good practices -->

## Recommended Improvements Roadmap
<!-- Prioritized list of improvements beyond the specific findings:
     1. Immediate (pre-deploy blockers)
     2. Short-term (next sprint)
     3. Medium-term (next quarter)
-->
```

---

## Review Behavior

- **Be specific**: Always cite file paths and line numbers. Show the problematic code
  and the fix side by side.
- **Assume adversarial context**: A VPS on the public internet is under constant
  automated attack. Review with that threat model.
- **Don't just flag — fix**: Every finding must include a concrete remediation,
  preferably with a code snippet.
- **Acknowledge tradeoffs**: Not everything needs to be perfect. If something is
  lower risk in context, say so. A personal project on a $5 VPS has different risk
  tolerance than a payment processor.
- **Check for missing things**: The absence of security controls is itself a finding.
  If there's no firewall config in the repo, that's a finding. If there's no TLS
  config, that's a finding.
- **Cross-reference**: Secrets in GitHub Actions should match what Ansible expects.
  Docker Compose port mappings should match firewall rules. Find inconsistencies
  across the stack.
- **Read the full file before reviewing**: Don't review line by line. Read the whole
  file, understand intent, then review. Context matters.
