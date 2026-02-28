# Security Audit Reference

## Priority Order

Review security concerns in this order — the top items are the most dangerous and most commonly missed:

### 1. Secrets and Credentials
- Hardcoded API keys, tokens, passwords, or connection strings in source code
- Secrets in client-side code (anything in Astro `<script>` tags, client-side components, or `public/`)
- `.env` files committed to version control
- Secrets logged to console or error tracking
- API keys in URL query parameters (logged by servers, proxies, and browsers)
- Secrets in comments ("TODO: rotate this key") that reveal valid credentials

**Astro-specific**: In `.astro` files, code in the frontmatter (`---`) runs server-side and can safely access secrets. Code in `<script>` tags runs client-side and must NEVER access secrets directly. Watch for `import.meta.env.SECRET_*` leaking to client bundles — only `PUBLIC_*` prefixed env vars are safe for client-side.

**Cloudflare-specific**: Secrets should be in Workers/Pages secrets (via `wrangler secret put`), not in `wrangler.toml`. Bindings for D1, KV, R2, etc. are safe as they're resolved at runtime, but connection strings to external databases are secrets.

### 2. Injection Vulnerabilities
- **XSS**: Rendering user input as HTML without sanitization. In Astro, using `set:html` with user-supplied content is dangerous. React components using `dangerouslySetInnerHTML` with unsanitized input.
- **SQL Injection**: String concatenation in D1 queries instead of parameterized queries. Look for template literals in `.prepare()` calls.
- **Command Injection**: User input passed to `exec`, `spawn`, or similar (rare in web apps but check API routes).
- **Path Traversal**: User input used in file paths without validation (e.g., serving files from R2 based on user-supplied keys).
- **Header Injection**: User input used in HTTP headers without validation (especially `Location` for redirects).

### 3. Authentication & Authorization
- API routes missing authentication checks
- Authorization bypass — checking auth but not checking if the user has permission for the specific resource
- JWT validation issues: not verifying signature, not checking expiration, not validating issuer/audience
- Session tokens in URLs (will appear in logs, referrer headers, browser history)
- Missing CSRF protection on state-changing endpoints

### 4. Data Exposure
- API endpoints returning more data than needed (over-fetching). An endpoint that returns a full user object including `passwordHash` when only `name` was needed.
- Error messages exposing internal details (stack traces, SQL queries, file paths in production)
- Debug/development endpoints or logging left in production code
- CORS misconfiguration: `Access-Control-Allow-Origin: *` on authenticated endpoints
- Source maps deployed to production revealing server-side code

### 5. Dependency Risks
- New dependencies with known vulnerabilities (check if the project uses `npm audit` in CI)
- Dependencies with excessive permissions or install scripts
- Pinning dependencies to exact versions vs ranges (tradeoff: security patches vs stability)
- Using unmaintained packages (no commits in >1 year, many open security issues)

### 6. Cloudflare Runtime Security
- Workers/Pages Functions have no filesystem access — but check for attempts to use `fs` which would indicate confusion about the runtime
- D1 is SQLite — ensure queries use parameter binding, not string interpolation
- KV values are strings — validate and sanitize when parsing stored data
- R2 presigned URLs: check expiration times and ensure they don't grant excessive access
- Rate limiting: API routes without rate limiting are vulnerable to abuse (Cloudflare offers built-in rate limiting rules)

## Severity Assessment

Rate security findings as:

- **🔴 Critical**: Exploitable vulnerability (secret in client code, SQL injection, auth bypass)
- **🟡 Warning**: Defense-in-depth issue (missing CSP header, overly broad CORS, no rate limiting)
- **🟢 Suggestion**: Hardening opportunity (dependency pinning, security headers, input validation depth)

## Remediation Patterns

When flagging a security issue, always include:

1. What's wrong (the vulnerability)
2. How it could be exploited (the attack scenario)
3. How to fix it (specific code change)

Example:
```
🔴 SQL Injection in src/pages/api/users.ts:14

The D1 query uses string interpolation:
  db.prepare(`SELECT * FROM users WHERE id = '${params.id}'`)

An attacker could pass: ' OR '1'='1 as the ID to dump all users.

Fix — use parameterized queries:
  db.prepare('SELECT * FROM users WHERE id = ?').bind(params.id)
```
