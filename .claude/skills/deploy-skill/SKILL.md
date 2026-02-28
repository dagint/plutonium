---
name: deploy
description: Deploy changes to the VPS following this repo's mandatory PR workflow. Use this skill when the user wants to deploy changes, push code to the server, merge a PR, or trigger the deployment pipeline. Also trigger when the user says "deploy", "push this to the VPS", "merge and deploy", "ship it", or asks how to get changes live. IMPORTANT: Direct commits to main are not allowed. All changes require a PR. This skill covers the full flow from branch → PR → merge → watching the deploy.
---

# Deploy Changes to VPS

All changes require a PR — direct commits to main are blocked. The deploy pipeline triggers automatically on merge.

## Full Deployment Flow

### 1. Validate Locally First

```bash
# Regenerate nginx proxy configs from services/
./scripts/build-proxy-confs.sh

# Run validation checks
./scripts/validate.sh

# Check for ShellCheck errors (CI will catch these anyway)
shellcheck scripts/*.sh
```

If `validate.sh` fails, fix the issues before creating the PR.

### 2. Create a Branch

```bash
# Branch naming convention:
git checkout -b feat/<description>      # New feature / new service
git checkout -b fix/<description>       # Bug fix
git checkout -b chore/<description>     # Maintenance, dependency updates
```

### 3. Commit Changes

```bash
git add <specific files>   # Prefer specific files over git add -A
git commit -m "feat: add Homarr dashboard service"

# Commit message conventions:
# feat:   new feature or service
# fix:    bug fix
# chore:  maintenance (deps, CI, config)
# docs:   documentation only
```

### 4. Push and Open PR

```bash
git push -u origin <branch-name>

# Create PR with gh CLI
gh pr create --title "feat: add Homarr dashboard service" --body "$(cat <<'EOF'
## Summary
- Add Homarr dashboard container (`docker/homarr/`)
- Add nginx proxy config (`services/vps/homarr.subdomain.conf`)
- Register in Authentik and backup script

## Test plan
- [ ] CI validate passes
- [ ] After deploy: https://homarr.dagint.com → Authentik → Homarr dashboard
- [ ] Backup dry-run includes homarr
EOF
)"
```

### 5. Wait for CI

```bash
# Watch the validate workflow on the PR
gh pr checks <PR-number> --watch

# Or open the PR in browser
gh pr view <PR-number> --web
```

The validate workflow runs:
- ShellCheck on all `.sh` files
- Proxy config generation + validation
- Test suite (`tests/test-proxy-configs.sh`)
- Gitleaks secret scanning

Fix any failures before merging.

### 6. Merge

```bash
# Squash merge (preferred — keeps main history clean)
gh pr merge <PR-number> --squash

# Auto-merge after CI passes (if CI is still running)
# Note: --auto requires GitHub branch protection to be configured
gh pr merge <PR-number> --squash --auto
```

**Do not force-push to main.** If you need to update the branch, add commits and push.

### 7. Watch the Deploy

Merge triggers the deploy workflow automatically.

```bash
# Find and watch the deploy run
gh run list --workflow=deploy.yml --limit=3
gh run watch <run-id>

# Or follow in browser
gh run view <run-id> --web
```

The deploy workflow:
1. SSH to VPS as `flux-deploy`
2. `git pull` on the VPS
3. Rsync repo files (excluding data directories)
4. Run `deploy-remote.sh` — pulls new images, `docker compose up -d` for all services
5. Fix permissions

Typical deploy time: 3–6 minutes.

### 8. Verify After Deploy

```bash
# Check all containers are running
ssh flux-deploy@<vps-ip> "docker ps --format 'table {{.Names}}\t{{.Status}}'"

# Test the new/changed service
curl -I https://<service>.dagint.com

# Check nginx loaded the new config without errors
ssh flux-deploy@<vps-ip> "docker logs swag --tail=20"
```

---

## Emergency: Rollback

If a deploy breaks something, the fastest fix is usually another PR that reverts or fixes the issue — not a rollback. But if you need to:

```bash
# SSH to VPS and manually revert
ssh flux-deploy@<vps-ip>
cd ~/flux
git log --oneline -10   # find the good commit
git checkout <good-sha> -- <specific-file>  # revert a specific file
docker exec swag nginx -t && docker exec swag nginx -s reload
```

---

## GitHub Actions Reference

| Workflow | Trigger | What It Does |
|---------|---------|-------------|
| `deploy.yml` | Push to `main` | Deploys to VPS via SSH |
| `validate.yml` | PR open/update | Runs tests, ShellCheck, gitleaks |
| `update-cloudflare-ips.yml` | Weekly (Mon 1 AM UTC) | Creates PR to update Cloudflare IPs in firewall script |
| `claude-code-review.yml` | PR open/`@claude` mention | AI code review on infrastructure PRs |
| `sync-dns.yml` | Push to `main` | Syncs Cloudflare DNS records |

---

## Common Issues

**CI fails with ShellCheck errors**: Run `shellcheck scripts/<file>.sh` locally. Fix the errors (or add `# shellcheck disable=SC####` with a comment explaining why if there's a false positive).

**Deploy workflow fails at SSH step**: Check that the VPS Tailscale node is online. The deploy uses Tailscale IP `100.70.122.42`.

**`docker compose up` fails on VPS**: SSH in and check `docker logs <container>`. Most often: missing env var, data dir permission issue, or image pull failure.

**nginx fails to start after deploy**: Config syntax error. Run `docker exec swag nginx -t` on VPS to identify the broken config.

**New service deploys but 502**: Container not on `proxy` network, or wrong upstream port. See `debug-service` skill.
