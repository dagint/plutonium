# Build & Test Prediction Reference

## Build Failure Patterns

These patterns frequently cause CI failures. Check for them systematically.

### Import/Export Mismatches
- A file renames or removes a named export, but consumers still import the old name
- Default export changed to named export (or vice versa) without updating imports
- Circular dependencies introduced by new imports
- Importing a server-only module in a client component (Astro: `import` in a `.astro` component's frontmatter is server-side, but if it leaks to client-side `<script>` tags, it breaks)

### TypeScript Compilation
- New code uses `any` to sidestep a type error that will surface elsewhere
- Interface changes that don't propagate (changed a field name in a type but not all usages)
- `strict` mode violations when the project has `strict: true` in tsconfig
- Missing type imports (using `import type` when a value import is needed, or vice versa)

### Dependency Issues
- Added a runtime dependency as a devDependency (works locally, fails in production build)
- Peer dependency version conflicts
- Using Node.js built-in modules in a Cloudflare Workers/Pages runtime (e.g., `fs`, `path`, `crypto` without polyfill)
- `package.json` modified but lockfile not updated

### Build Config
- Environment variables referenced in code but not in `.env.example` or CI config
- Build output directory mismatch between framework config and deploy config
- New file not matching expected file patterns in build pipeline (e.g., a `.ts` file in a directory that only processes `.js`)

## Test Failure Prediction

### Direct Breakage
- Changed function signature (new required param, removed param, changed return type)
- Changed module export structure
- Renamed file that tests import directly
- Changed error messages that tests assert on (brittle, but common)
- Modified database schema/API response shape that fixtures depend on

### Indirect Breakage
- Changed shared utility that multiple test suites depend on
- Modified environment setup (e.g., changed a default config value)
- Race condition introduced in async code that tests run concurrently
- Side effects added to a previously pure function

### Missing Coverage
Look for new code paths that have no corresponding test:
- New API endpoint with no integration test
- New error handling branch with no test for the error case
- New conditional rendering path with no component test
- New utility function with no unit test

## Pre-Merge Validation Checklist

When predicting whether CI will pass:

1. Are all imports resolvable? Trace each new `import` to confirm the target exists and exports what's expected.
2. Does the TypeScript compile? Look for type errors in changed files and their dependents.
3. Do existing tests still pass? Check for interface changes that break test expectations.
4. Are new features tested? Flag untested happy paths and error paths.
5. Does the build command succeed? Check for config mismatches, missing env vars, unsupported APIs.
6. Are lockfile and dependencies in sync? If `package.json` changed, the lockfile should too.
