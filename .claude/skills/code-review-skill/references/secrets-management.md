# Secrets Management Reference

End-to-end patterns for how secrets should flow through the deployment pipeline,
from development to runtime on the VPS.

---

## Secret Types & Classification

| Secret Type | Example | Rotation Frequency | Compromise Impact |
|------------|---------|-------------------|-------------------|
| SSH deploy key | `id_ed25519` | Quarterly or on personnel change | Full server access |
| Database password | `POSTGRES_PASSWORD` | Quarterly | Data breach |
| API keys (external) | `STRIPE_SECRET_KEY` | On suspicion of compromise | Financial, data |
| API keys (internal) | `INTERNAL_SERVICE_KEY` | Quarterly | Lateral movement |
| TLS private key | `server.key` | With certificate renewal | MITM attacks |
| Docker registry token | `GHCR_TOKEN` | Annually | Supply chain |
| Ansible Vault password | `vault_password` | On personnel change | All encrypted secrets |
| JWT signing key | `JWT_SECRET` | Quarterly | Auth bypass |
| Encryption keys | `DATA_ENCRYPTION_KEY` | Annually (with re-encryption) | Data exposure |

---

## Secrets Flow: Source → CI/CD → VPS → Runtime

### Correct Flow

```
┌─────────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  GitHub Secrets  │────▶│  GH Actions  │────▶│   VPS Host   │────▶│  Container   │
│  (encrypted at  │     │  (env vars,  │     │  (.env file  │     │  (env vars   │
│   rest in GH)   │     │  never logged│     │  or docker   │     │  or mounted  │
│                 │     │  or in args) │     │  secrets)    │     │  secrets)    │
└─────────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
         │                                            │
         │              ┌──────────────┐              │
         └─────────────▶│ Ansible Vault│──────────────┘
                        │ (encrypted   │
                        │  in repo)    │
                        └──────────────┘
```

### Anti-Patterns to Flag

```
CRITICAL: Plaintext in repo
  .env committed to git
  Passwords in docker-compose.yml
  Keys in ansible vars (unencrypted)
  Credentials in shell scripts

CRITICAL: Secrets in build artifacts
  COPY .env /app/.env in Dockerfile
  ARG PASSWORD → ENV PASSWORD
  RUN echo "$SECRET" > config.ini

HIGH: Secrets in CI logs
  echo ${{ secrets.TOKEN }}
  curl -u user:${{ secrets.PASS }} ...  (visible in process listing)
  set -x with secrets in env

HIGH: Secrets in transit (unencrypted)
  FTP deployment
  HTTP webhook with credentials
  Unencrypted rsync

MEDIUM: Overly broad secret access
  All jobs have access to all secrets
  Single secret for all environments
  Shared credentials across services
```

---

## GitHub Secrets Best Practices

### Organization

```
Repository secrets (per-repo):
  DEPLOY_SSH_KEY_STAGING
  DEPLOY_SSH_KEY_PRODUCTION

Environment secrets (per-environment, requires approval):
  DB_PASSWORD          (in "production" environment)
  API_KEY              (in "production" environment)

Organization secrets (shared across repos):
  DOCKER_REGISTRY_TOKEN
  SLACK_WEBHOOK_URL
```

### Scoping

```yaml
# HIGH — all jobs get all secrets (default behavior)
jobs:
  test:
    runs-on: ubuntu-latest
    # Has access to all repo secrets, including production ones

  deploy:
    runs-on: ubuntu-latest
    # Same secrets as test job

# FIXED — use environments to scope secrets
jobs:
  test:
    runs-on: ubuntu-latest
    # Only has access to repo-level secrets (non-sensitive)

  deploy:
    runs-on: ubuntu-latest
    environment: production  # Has access to production environment secrets
    # Requires reviewer approval before running
```

---

## Ansible Vault Patterns

### File-Level Encryption

```bash
# Encrypt an entire vars file
ansible-vault encrypt group_vars/production/vault.yml

# Decrypt for editing
ansible-vault edit group_vars/production/vault.yml

# Encrypt a string inline
ansible-vault encrypt_string 'supersecret' --name 'db_password'
# Output:
# db_password: !vault |
#   $ANSIBLE_VAULT;1.1;AES256
#   61626364...
```

### Vault Password Management

```bash
# CRITICAL — vault password in repo
echo "myvaultpass" > .vault_password
# If .vault_password is committed, ALL encrypted secrets are exposed

# FIXED — vault password from environment
# In ansible.cfg:
[defaults]
vault_password_file = /path/to/vault_password_file
# The file should be outside the repo and restricted:
# chmod 600 /path/to/vault_password_file

# Or pass via environment in CI:
# ansible-playbook site.yml --vault-password-file <(echo "$ANSIBLE_VAULT_PASSWORD")
```

### Vault Variable Convention

```yaml
# Use a naming convention to make vault usage clear:

# group_vars/production/vault.yml (encrypted)
vault_db_password: "actual_secret_here"
vault_api_key: "sk-abc123"

# group_vars/production/vars.yml (unencrypted, references vault)
db_password: "{{ vault_db_password }}"
api_key: "{{ vault_api_key }}"
db_host: "localhost"
db_port: 5432

# This pattern makes it clear which values are secrets
# and allows referencing the friendly name everywhere
```

---

## Docker Secrets at Runtime

### Compose with env_file

```yaml
# Minimum viable approach for VPS deployments
# .env.prod (on the VPS, NOT in repo, restricted permissions)
DB_PASSWORD=supersecret
API_KEY=sk-abc123
JWT_SECRET=randomstring

services:
  app:
    env_file:
      - .env.prod
```

The `.env.prod` file on the VPS should be:
- Owned by root: `chown root:root .env.prod`
- Restricted: `chmod 600 .env.prod`
- Deployed via Ansible (encrypted in vault, decrypted on deploy)

### Docker Secrets (More Secure)

```yaml
# Secrets mounted as files, not environment variables
services:
  app:
    secrets:
      - db_password
      - api_key
    environment:
      # App reads from /run/secrets/db_password instead
      DB_PASSWORD_FILE: /run/secrets/db_password

secrets:
  db_password:
    file: /opt/secrets/db_password.txt  # On VPS, not in repo
  api_key:
    file: /opt/secrets/api_key.txt
```

Why files are better than env vars:
- Env vars visible via `docker inspect`
- Env vars visible in `/proc/<pid>/environ`
- Env vars can leak into error messages and crash dumps
- File secrets are mounted at `/run/secrets/` (tmpfs, never on disk)

---

## Secret Rotation Checklist

Every deployment should support rotating secrets without downtime:

```
[ ] Database passwords: Can be rotated by updating .env and restarting containers
[ ] API keys: Application handles key rotation (dual-key support or graceful reload)
[ ] SSH keys: New key can be added before old key is removed
[ ] TLS certificates: Auto-renewed via ACME/Let's Encrypt
[ ] JWT signing keys: Application supports key rollover (verify with old, sign with new)
[ ] Docker registry tokens: Can be refreshed in GitHub Secrets without pipeline changes
[ ] Ansible vault password: Can be rekeyed: ansible-vault rekey
```

If any of these require downtime to rotate, flag as MEDIUM finding.

---

## Scanning for Leaked Secrets

Recommend these tools in the review report:

| Tool | Purpose | Integration |
|------|---------|-------------|
| `gitleaks` | Scan git history for secrets | GitHub Actions, pre-commit |
| `trufflehog` | Deep git history scanning | CI, one-time audit |
| `detect-secrets` (Yelp) | Pre-commit secret detection | pre-commit hook |
| GitHub secret scanning | Automatic for public repos | Built-in |
| GitHub push protection | Block pushes containing secrets | Built-in (enable in settings) |

GitHub Actions integration:
```yaml
- name: Scan for secrets
  uses: gitleaks/gitleaks-action@SHA
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## .gitignore Requirements

Every infra repo must gitignore these:

```gitignore
# Secrets & credentials
.env
.env.*
!.env.example
*.pem
*.key
*.p12
*.pfx
id_rsa*
id_ed25519*
*.pub          # Debatable — public keys are less sensitive
vault_password*
.vault_pass*

# Ansible
*.retry

# Terraform (if present)
*.tfstate
*.tfstate.*
.terraform/
*.tfvars       # May contain secrets
!*.tfvars.example

# OS & editor
.DS_Store
*.swp
*~
.idea/
.vscode/
```

Flag if `.gitignore` is missing or doesn't cover secret file patterns.
