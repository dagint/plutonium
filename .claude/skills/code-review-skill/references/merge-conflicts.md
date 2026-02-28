# Merge Conflict Risk Reference

## Why This Matters

Merge conflicts waste time, introduce bugs during resolution, and slow down team velocity. The best way to handle merge conflicts is to avoid creating them in the first place. This reference helps identify changes that are likely to conflict with parallel work and suggests structural patterns to reduce that risk.

## High-Risk Conflict Patterns

### Shared Configuration Files
These files are edited by many features and are the #1 source of merge conflicts:
- `package.json` — especially `dependencies` and `scripts` sections
- `astro.config.mjs` / `astro.config.ts` — integrations array, adapter config
- `wrangler.toml` / `wrangler.json` — bindings, routes, compatibility settings
- `tsconfig.json` — paths, compiler options
- Tailwind config — theme extensions, plugins
- CI/CD config files (`.github/workflows/*.yml`, etc.)
- Route manifests or middleware chains

**Mitigation**: When adding items to arrays or objects in config files, add to the end rather than inserting in the middle. Use alphabetical ordering only if the project already enforces it. Avoid reordering existing entries.

### Large File Modifications
- Touching more than ~30% of a file's lines virtually guarantees a conflict if anyone else edits that file
- Reformatting or linting an entire file creates conflicts with every parallel branch
- Moving large blocks of code within a file

**Mitigation**: Separate refactoring from feature work. If a file needs reformatting, do it in a dedicated commit/PR before the feature work, and communicate with the team.

### Index and Barrel Files
- `index.ts` / `index.js` files that re-export from multiple modules
- Route definition files that aggregate many routes
- Central state/store definitions
- CSS/SCSS entry points that import partials

**Mitigation**: Use automatic barrel file generation or code-splitting patterns that don't require a central index. For routes, prefer file-based routing (Astro does this well) over manual route registration.

### Shared Layout and Component Files
- Global layout components (`Layout.astro`, `BaseHead.astro`)
- Navigation components (every feature adds a nav item)
- Shared UI components used across many pages

**Mitigation**: Use composition over modification. Instead of editing a shared nav component to add a link, consider data-driven navigation where links come from a config array or content collection.

### Database Schema and Migration Files
- Schema files that multiple features need to modify
- Migration files with sequential numbering
- Seed data files

**Mitigation**: Coordinate schema changes. Use a migration tool that handles ordering. Avoid modifying existing migrations — create new ones.

## Structural Patterns That Reduce Conflicts

### File-Based Routing (Astro Default)
Astro's `src/pages/` routing means adding a page is adding a new file, not editing a route config. This naturally avoids conflicts. If the project has deviated from this pattern (e.g., a custom routing layer), flag it as a conflict risk.

### Content Collections
Using Astro content collections lets contributors add content as new files rather than editing existing ones. New blog posts, docs, or data entries are new files — zero conflict risk.

### Component Composition
Prefer creating new components over modifying shared ones. If a review shows edits to a widely-used component, ask: could this be a new component that the caller composes instead?

### Feature Flags / Config-Driven
Features behind flags can be added without touching the same files other features touch. The flag definition is the only shared touchpoint.

## Review Checklist for Conflict Risk

When reviewing a change, assess:

1. **How many shared files are touched?** Files edited by 2+ branches in the last month are high-risk.
2. **Are config files modified?** These are the most common conflict source.
3. **Is there reformatting mixed with logic changes?** Separate these.
4. **Are barrel/index files edited?** Prefer adding new files over editing aggregators.
5. **How large are the file-level diffs?** Larger diffs = higher conflict probability.
6. **Is this PR long-lived?** Branches open for >3 days have exponentially higher conflict risk. Recommend splitting into smaller, faster-merging PRs.

## Recommendations Template

When you find merge conflict risks, recommend specific actions:

- "This PR modifies `astro.config.mjs` to add an integration. If any parallel branch also modifies this file, you'll conflict. Consider merging this change first, or coordinate with the team."
- "The changes to `Layout.astro` touch 40% of the file. If other branches modify the layout, this will conflict. Can the new section be extracted to a separate component and composed in?"
- "Adding to the barrel export in `components/index.ts` — this is a frequent conflict source. Prefer direct imports (`from './components/Button'`) over barrel imports."
