# Severity Classification Guide

Consistent severity ratings are essential for actionable reviews. Use this decision
tree and reference table to classify every finding.

---

## Decision Tree

```
Is there a plaintext secret exposed?
  └─ YES → CRITICAL

Could an external attacker exploit this without authentication?
  └─ YES → Is it remotely exploitable right now?
       └─ YES → CRITICAL
       └─ NO (requires additional conditions) → HIGH

Does it weaken a security boundary?
  └─ YES → Does it affect the production environment?
       └─ YES → HIGH
       └─ NO (dev/staging only) → MEDIUM

Is it a deviation from established best practices?
  └─ YES → Does it increase attack surface or reduce auditability?
       └─ YES → MEDIUM
       └─ NO → LOW

Is it a suggestion for improvement with no security impact?
  └─ YES → INFO
```

---

## Severity Reference Table

### CRITICAL — Blocks Deployment

| Finding | Category | Why |
|---------|----------|-----|
| Plaintext password/key/token in repo | Security | Immediately compromisable |
| Secrets in Docker image layers | Security | Anyone with image access has credentials |
| `PermitRootLogin yes` on public VPS | Security | Root SSH brute-force target |
| `privileged: true` on application container | Security | Container escape → full host access |
| Docker socket mounted in application container | Security | Container escape → full host access |
| No firewall configured on VPS | Security | All services directly exposed |
| GitHub Actions expression injection (user input in run:) | Security | Arbitrary code execution in CI |
| `pull_request_target` with PR code checkout + execution | Security | Arbitrary code execution with secrets |
| Blanket `NOPASSWD: ALL` in sudoers | Security | Any compromise → root |
| Database port exposed to 0.0.0.0 without auth | Security | Public database access |

### HIGH — Fix Before Production

| Finding | Category | Why |
|---------|----------|-----|
| GitHub Actions not pinned by SHA | Security | Supply chain attack vector |
| `PasswordAuthentication yes` for SSH | Security | Brute-force target |
| Container running as root (non-system containers) | Security | Expanded blast radius |
| No network segmentation (DB on same network as proxy) | Security | Lateral movement |
| Ports bound to 0.0.0.0 for internal services | Security | Unnecessary exposure |
| Missing `permissions` in GitHub Actions workflow | Security | Excessive default permissions |
| `ignore_errors: yes` without justification | Standards | Silent failures mask real issues |
| Self-hosted runner with persistent state | Security | Cross-job credential leakage |
| Shell script > 100 lines with no migration plan | Standards | Maintenance and security risk |
| Secrets in CI logs (echo, -x flag, command args) | Security | Credential exposure |
| Host paths mounted into containers (/, /etc, /var) | Security | Host filesystem access |
| `eval` in shell scripts | Security | Arbitrary code execution |
| No TLS or TLS 1.0/1.1 on public endpoints | Security | Data interception |

### MEDIUM — Should Fix (Next Sprint)

| Finding | Category | Why |
|---------|----------|-----|
| Using `latest` tag for Docker images | Security | Unpredictable, unreproducible |
| Missing Docker HEALTHCHECK | Standards | Orchestrator can't detect failures |
| Shell script missing `set -euo pipefail` | Standards | Silent failures |
| Ansible using short module names (no FQCN) | Standards | Ambiguity, future deprecation |
| `become: yes` at play level (not task level) | Security | Unnecessary privilege escalation |
| No resource limits on containers | Performance | Resource exhaustion risk |
| Shell/command module used instead of proper Ansible module | Standards | Idempotency loss |
| Missing `.dockerignore` | Security/Perf | Secrets in build context, slow builds |
| No `timeout-minutes` on GitHub Actions jobs | Performance | Hung jobs waste resources |
| Compose file using `version:` key (outdated) | Standards | Deprecated syntax |
| No fail2ban configured | Security | No brute-force protection |
| Unquoted variables in shell scripts | Security | Word splitting, glob expansion |
| Missing log rotation (`max-size`, `max-file`) | Performance | Disk exhaustion |
| `.env` file with broad permissions (not 600) | Security | Other users can read secrets |
| No `concurrency` group on deploy workflows | Standards | Parallel deploys possible |
| Bind mounts without `:ro` where writes aren't needed | Security | Unnecessary write access |

### LOW — Nice to Have

| Finding | Category | Why |
|---------|----------|-----|
| Ansible tasks missing tags | Standards | Can't selectively run tasks |
| Docker image could use slimmer base | Performance | Larger attack surface, slower pulls |
| Missing OCI labels on Docker images | Standards | Poor metadata |
| Shell script functions not in `main()` pattern | Standards | Readability |
| Ansible gather_facts enabled when not needed | Performance | Slower playbook execution |
| Missing comments on complex conditionals | Standards | Maintainability |
| No named volumes (using anonymous volumes) | Standards | Harder to manage/backup |
| Compose services missing `restart` policy | Standards | No auto-recovery |
| GitHub Actions not using cache for dependencies | Performance | Slower CI |

### INFO — Observations

| Finding | Category | Why |
|---------|----------|-----|
| Good use of multi-stage Docker builds | Positive | Acknowledged best practice |
| Ansible Vault properly used for all secrets | Positive | Reinforcement |
| Well-structured role directory layout | Positive | Acknowledged |
| Suggestion to add monitoring/alerting | Suggestion | Not a deficiency, an enhancement |
| Alternative tool suggestion (e.g., Caddy over nginx) | Suggestion | For consideration |

---

## Context Modifiers

Severity may be adjusted based on context. Document the adjustment and reasoning:

### Upgrade Severity When:

- The VPS is processing payments or PII → upgrade MEDIUM → HIGH for any data-exposure risk
- Multiple findings compound (e.g., no firewall + DB port exposed + no fail2ban = CRITICAL)
- The deployment is fully automated with no human review gate
- The VPS is multi-tenant

### Downgrade Severity When:

- The VPS is a personal project / hobby server with no sensitive data
- The finding is in a staging/dev environment only
- There's a documented compensating control (note it in the finding)
- The code is in active migration (note timeline)

Always document adjustments:
```
### [HIGH → MEDIUM] Container running as root
- **File**: `Dockerfile:1`
- **Adjusted because**: This is the official PostgreSQL image which requires
  root for initialization. The container has cap_drop: ALL and is on an
  internal-only network. Recommend tracking upstream rootless PostgreSQL support.
```

---

## Counting & Summarizing

At the end of the report, provide a severity summary:

```
## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2     |
| HIGH     | 5     |
| MEDIUM   | 8     |
| LOW      | 3     |
| INFO     | 4     |

**Verdict**: NOT READY for production deployment.
2 CRITICAL findings must be resolved before any deployment.
```

Verdict guidelines:
- Any CRITICAL → "NOT READY for production deployment"
- 3+ HIGH with no CRITICAL → "REQUIRES remediation before production"
- Only MEDIUM and below → "ACCEPTABLE with improvements recommended"
- Only LOW/INFO → "GOOD — minor improvements suggested"
