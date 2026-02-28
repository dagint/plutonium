# Astro + Cloudflare Pages: Framework-Specific Patterns

## Astro Gotchas

### Server vs Client Boundary
The most common class of Astro bugs is confusing server and client contexts.

- **Frontmatter (`---`)**: Runs at build time (static) or request time (SSR). Has access to `Astro.request`, env vars, databases. Does NOT run in the browser.
- **`<script>` tags**: Run in the browser. No access to server resources. Only `PUBLIC_*` env vars via `import.meta.env`.
- **Component props**: Serialized across the boundary. Only serializable data (strings, numbers, plain objects, arrays) can be passed as props to hydrated islands. Functions, classes, Maps, Sets will fail silently or error.

**Review pattern**: Any time you see data flowing from frontmatter to a `client:*` component, verify the data is serializable.

### Hydration Directives
- `client:load` — Hydrates immediately. Use only for above-the-fold interactive elements.
- `client:idle` — Hydrates when browser is idle. Good default for most interactive components.
- `client:visible` — Hydrates when the component enters the viewport. Best for below-the-fold content.
- `client:media` — Hydrates when a CSS media query matches. Good for responsive interactivity.
- `client:only` — Renders only on client, no SSR. Use sparingly; it breaks SSR and produces empty HTML.

**Review pattern**: Flag `client:load` on below-the-fold components. Flag `client:only` unless there's a specific reason (e.g., a library that can't run in Node/Workers).

### Content Collections
- Schema changes to content collections (`src/content/config.ts`) affect all content. Validate that existing content still conforms after schema changes.
- The `slug` field is auto-generated from filenames. Custom slug logic in `getStaticPaths` should handle edge cases (Unicode, special characters, collisions).

### Dynamic Routes
- `[...slug].astro` catch-all routes must handle 404 cases explicitly
- `getStaticPaths()` must return all valid paths at build time for static sites. Missing paths = 404.
- In SSR mode, dynamic params come from the URL and must be validated/sanitized.

## Cloudflare Runtime Gotchas

### Node.js Compatibility
Cloudflare Workers uses the V8 runtime, not Node.js. Many Node.js APIs are not available:

- **No `fs` module** — There is no filesystem. Use KV, R2, or D1 for storage.
- **Limited `crypto`** — Web Crypto API is available, but Node.js `crypto` module is not (unless compatibility flags are set).
- **No `process`** — `process.env` doesn't exist. Use `env` parameter passed to the handler, or `import.meta.env` for Astro env vars.
- **`node_compat`/`nodejs_compat`** — The `nodejs_compat` compatibility flag enables some Node.js APIs but not all. Check the compatibility matrix in Cloudflare docs for specific APIs.

**Review pattern**: Any new `import` from a Node.js built-in module should be flagged and checked against Cloudflare's compatibility list. Common offenders: `fs`, `path`, `net`, `child_process`, `os`.

### Wrangler Configuration
- **Compatibility date**: Determines which Workers runtime features are available. Should be updated periodically but not to a future date. Updating compatibility date can change behavior.
- **Bindings**: D1, KV, R2, DO, Queues, etc. bindings must be declared in `wrangler.toml`/`wrangler.json`. Code referencing a binding that isn't configured will crash at runtime.
- **Routes**: Misconfigured routes can cause Pages Functions to not trigger, or to trigger on the wrong paths.

**Review pattern**: If code references `env.MY_KV` or `context.env.DB`, verify the corresponding binding exists in wrangler config. Missing bindings are a runtime crash, not a build error.

### D1 (SQLite on the Edge)
- D1 is SQLite — it supports a subset of SQL. No stored procedures, no `RETURNING *` with complex queries, limited `ALTER TABLE`.
- Transactions are supported but have limits. Long-running transactions in a request handler will hit CPU limits.
- `PRAGMA` statements work for read operations but some are restricted.
- Schema migrations should use `wrangler d1 migrations` for reproducibility.

### KV (Key-Value Store)
- **Eventually consistent**: Reads after writes may return stale data for up to 60 seconds. Code that writes and immediately reads back must account for this.
- **No atomic operations**: No read-modify-write atomicity. If two Workers write to the same key concurrently, last write wins with no conflict detection.
- **Value size**: Max 25MB per value. Large values should use R2 instead.
- **List performance**: `list()` returns keys in lexicographic order with pagination. Not suitable for complex queries — use D1 for that.

### R2 (Object Storage)
- **No directory listing**: R2 is a flat keyspace with prefix-based listing. Code that assumes directory structure may behave unexpectedly.
- **Multipart upload**: Large files (>5MB) should use multipart upload. Code that uses `put()` for large files will work but is inefficient.
- **Conditional requests**: R2 supports ETags and conditional headers. Use them for caching.

## Astro + Cloudflare Integration Points

### The Adapter
`@astrojs/cloudflare` connects Astro's SSR to Cloudflare Workers. Key config:

```js
// astro.config.mjs
export default defineConfig({
  adapter: cloudflare({
    platformProxy: {
      enabled: true // Enables local dev with wrangler bindings
    }
  }),
  output: 'server' // or 'hybrid' for mixed static/SSR
});
```

**Review pattern**: If the project uses `output: 'hybrid'`, verify that pages that should be static have `export const prerender = true`. The default in hybrid mode is SSR, which has cost/performance implications.

### Accessing Bindings in Astro
```js
// In .astro frontmatter or API routes:
const runtime = Astro.locals.runtime;
const db = runtime.env.DB;        // D1 binding
const kv = runtime.env.MY_KV;     // KV binding
const bucket = runtime.env.BUCKET; // R2 binding
```

**Review pattern**: Verify that binding names match between code and `wrangler.toml`. A mismatch crashes at runtime, not build time.

### Environment Variables
- `PUBLIC_*` prefixed vars: Available in both server and client code
- Non-prefixed vars: Server-only in Astro. Available via `import.meta.env.VAR_NAME` in frontmatter.
- Cloudflare secrets: Set via `wrangler secret put`, available in Workers env — not via `import.meta.env`.

**Review pattern**: If code accesses `import.meta.env.SOMETHING` in a `<script>` tag, it will be `undefined` unless the var is `PUBLIC_` prefixed. This is a silent failure that's easy to miss.
