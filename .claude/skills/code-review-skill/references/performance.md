# Performance Review Reference

## Rendering Path Analysis

### Astro-Specific Rendering
Astro's strength is shipping zero JavaScript by default. Performance regressions in Astro projects usually come from:

- **Unnecessary client hydration**: Using `client:load` when `client:visible` or `client:idle` would suffice. Every `client:*` directive adds JS to the bundle. If a component doesn't need interactivity, don't hydrate it.
- **Wrong island boundaries**: Making a large parent component interactive when only a small child needs interactivity. Prefer smaller islands.
- **Importing heavy libraries in frontmatter**: Large modules imported server-side slow the build but not the client. However, if they're also referenced client-side, they'll ship to the browser.
- **Blocking data fetches in pages**: Sequential `await` calls in Astro frontmatter block rendering. Use `Promise.all()` for independent fetches.

### Static vs SSR
- Pages that could be static but are using SSR unnecessarily. Static pages are served from Cloudflare's CDN edge cache — SSR pages require a Workers invocation.
- SSR pages that don't actually use any dynamic data (no cookies, no user-specific content). These should be prerendered.
- Missing `export const prerender = true` on pages that can be statically generated in hybrid mode.

## Bundle Size

### JavaScript Budget
- New dependencies: check the bundle size impact. Use `bundlephobia.com` as reference — flag any dependency adding >50KB gzipped.
- Tree-shaking failures: importing the entire library when only specific functions are needed (`import _ from 'lodash'` vs `import debounce from 'lodash/debounce'`)
- Duplicate dependencies: different versions of the same library pulled in by different deps
- Dead code: exported functions that are no longer imported anywhere

### Image Optimization
- Unoptimized images in `public/` — Astro's `<Image>` component handles optimization, but raw images in `public/` bypass this
- Missing `width` and `height` on images (causes layout shift, hurts CLS)
- Large hero images without responsive `srcset`
- Images served as PNG when JPEG/WebP/AVIF would be appropriate

### CSS
- Unused CSS shipped to production (especially with utility frameworks — Tailwind purges unused classes, but custom CSS may not)
- CSS-in-JS adding runtime overhead when static CSS would work
- Large CSS imports that aren't code-split

## Runtime Performance

### Cloudflare Workers/Pages Functions
- **CPU time limits**: Workers have a 10ms CPU time limit on the free plan (50ms on paid). Heavy computation in request handlers risks hitting this. Look for: complex regex, large JSON parsing, image processing, cryptographic operations.
- **Subrequest limits**: Workers can make up to 50 subrequests (1000 on paid) per invocation. API routes that fan out to many external services risk hitting this.
- **Memory**: Workers have 128MB memory limit. Building large data structures in memory (e.g., processing a large CSV) can cause OOM.
- **Cold starts**: Workers generally don't have cold starts (unlike Lambda), but initial execution after a deploy can be slightly slower. Not typically a concern but worth noting for latency-sensitive endpoints.

### Data Access Patterns
- **N+1 queries**: Fetching a list, then making individual queries for each item. Batch queries or joins are better.
- **Missing pagination**: Endpoints that return all records. D1 queries without LIMIT.
- **KV read patterns**: KV is eventually consistent for reads. If the code depends on read-after-write consistency, this is a bug, not just a performance issue.
- **R2 operations**: Large file uploads/downloads should use multipart and streaming, not loading the entire file into memory.
- **Cache utilization**: Are responses being cached appropriately? Cloudflare's Cache API is available in Workers. Static assets should have appropriate cache headers.

## Network Waterfall

- **Sequential requests**: Client-side code making sequential API calls that could be parallelized
- **Missing preloading**: Critical resources not preloaded (`<link rel="preload">`)
- **Third-party scripts**: External scripts blocking render (analytics, fonts, embeds). Should be loaded `async` or `defer`.
- **Font loading**: Custom fonts without `font-display: swap` cause invisible text flash. Consider using Cloudflare Fonts or self-hosting with preloading.

## Review Checklist

1. Does this change add client-side JavaScript? Is that JavaScript necessary?
2. Does this change add a new dependency? What's the bundle cost?
3. Are data fetches parallelized where possible?
4. Are images optimized and properly sized?
5. Could any SSR page be prerendered instead?
6. Are Workers functions within CPU/memory/subrequest limits?
7. Is caching being used effectively?
8. Are there N+1 query patterns?
