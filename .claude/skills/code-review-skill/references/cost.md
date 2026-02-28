# Cost Optimization Reference

## Cloudflare Pricing Model Awareness

Understanding the billing model helps catch cost issues in code review. The key principle: static/cached content is nearly free, dynamic compute and storage operations have per-request costs.

### Pages & Workers
- **Free tier**: 100,000 requests/day for Workers; unlimited static asset requests on Pages
- **Paid (Standard)**: $5/month includes 10M requests; $0.30 per additional million
- **CPU time**: 10ms free tier, 30ms (averaged) on paid. Code that hits the CPU limit will fail, not just cost more.
- **Key insight**: Converting an SSR page to a static page eliminates per-request compute cost entirely. Every page that can be prerendered should be.

### D1
- **Free tier**: 5M rows read/day, 100K rows written/day, 5GB storage
- **Paid**: $0.001 per million rows read, $1.00 per million rows written
- **Key insight**: Reads are 1000x cheaper than writes. Design schemas and queries to minimize writes. Batch writes where possible.

### KV
- **Free tier**: 100K reads/day, 1K writes/day
- **Paid**: $0.50 per million reads, $5.00 per million writes
- **Key insight**: KV writes are 10x the cost of reads. Use KV as a read-heavy cache, not a write-heavy store. If write volume is high, consider D1 instead.

### R2
- **Storage**: $0.015/GB-month (first 10GB free)
- **Class A ops (writes)**: $4.50 per million (first 1M free)
- **Class B ops (reads)**: $0.36 per million (first 10M free)
- **Egress**: Free (this is R2's main advantage over S3)
- **Key insight**: R2's free egress means it's excellent for serving user-generated content, images, and downloads. But write-heavy patterns (e.g., logging to R2) can add up.

### Build Minutes
- **Free tier**: 500 builds/month on Pages
- **Key insight**: Unnecessary rebuilds waste build minutes. Ensure CI isn't triggering builds on non-deployment branches, documentation-only changes, or irrelevant file changes.

## Common Cost Patterns to Flag

### Accidental SSR
A page that renders the same content for every user but uses SSR instead of static generation. This is the most common cost issue in Astro + Cloudflare projects.

**Signs**: A page in `src/pages/` without `export const prerender = true` (in hybrid mode) that doesn't use cookies, headers, or user-specific data.

**Cost**: Each page view costs Workers compute instead of being a free static asset serve.

**Fix**: Add `export const prerender = true` or move to static output mode if the entire site is static.

### Unbound Data Queries
Database queries without LIMIT clauses that could return unbounded result sets.

**Signs**: `SELECT * FROM table` without a WHERE that's guaranteed to limit results, or with a WHERE on a user-supplied parameter.

**Cost**: Row reads scale linearly with result size. An accidental full-table scan on a 1M row table costs $1 in D1 reads.

**Fix**: Always use LIMIT. Paginate results. Use covering indexes for frequently-queried columns.

### Write Amplification
Writing the same data to multiple stores or writing more often than necessary.

**Signs**: An API handler that writes to both D1 and KV on every request, or a real-time counter using KV writes per-event instead of batching.

**Cost**: KV writes at $5/million and D1 writes at $1/million add up fast with amplification.

**Fix**: Write to one primary store and populate caches lazily on read. Batch writes using Durable Objects or queued processing.

### Oversized KV Values
Storing large JSON blobs in KV that are re-read and re-written on every modification.

**Signs**: A KV value that's a large JSON object (>100KB) that gets read, modified, and re-written frequently.

**Cost**: Each read/write of a 1MB value is still one operation, but it wastes bandwidth and CPU parsing time.

**Fix**: Decompose large values into smaller, independently-updatable keys. Use D1 for structured data that needs partial updates.

### External API Fanout
API routes that make multiple calls to external services per request.

**Signs**: A page that calls 5+ external APIs in its frontmatter or API handler. Each subrequest adds latency and may have its own billing.

**Cost**: Not just Cloudflare costs — external API calls may be billed per-request (e.g., a geocoding API, a CMS API, an analytics API).

**Fix**: Cache external API responses using the Cache API or KV. Aggregate data at build time instead of request time where possible.

### Build Waste
CI/CD pipelines that run full builds on changes that don't affect the output.

**Signs**: No path filtering in GitHub Actions — building on README changes, documentation updates, or test-only changes.

**Fix**: Add path filters to CI config:
```yaml
on:
  push:
    paths-ignore:
      - '*.md'
      - 'docs/**'
      - 'tests/**'
```

## Review Checklist

1. Can any SSR page be converted to static/prerendered?
2. Do all database queries have appropriate LIMIT clauses?
3. Is write amplification minimized (one primary store, caches populated on read)?
4. Are external API calls cached?
5. Are KV values sized appropriately (<100KB for frequently-accessed data)?
6. Is the CI pipeline filtering out builds that don't need deployment?
7. Are R2 operations batched where possible?
8. Is the code taking advantage of Cloudflare's free tier limits?
