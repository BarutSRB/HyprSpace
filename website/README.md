# omniwm.app

The OmniWM website: a landing page with animated feature demos and the knowledge base, built with [Astro](https://astro.build) + [Starlight](https://starlight.astro.build).

## Development

```sh
npm ci
npm run dev       # local dev server at localhost:4321
npm run build     # static build into dist/
npm run preview   # serve the built site
npm run check     # type-check content and components
```

Node 22.12+ required.

## Adding or editing a knowledge-base page

Every docs page is a Markdown file under `src/content/docs/`, grouped by directory:

| Directory | Sidebar group |
|---|---|
| `guides/` | Getting Started |
| `features/` | Features |
| `config/` | Configuration |
| `reference/cli/` | CLI & IPC |
| `help/` | Help |
| `developers/` | Developers |

To add a page, drop a `.md` file into the right directory with this front matter:

```markdown
---
title: Page Title
description: One-sentence summary shown in search and link previews.
sidebar:
  order: 5
---

Content starts here — no `# H1`, Starlight renders the title.
```

The sidebar is generated automatically; `sidebar.order` controls position within the group. Use `:::note`, `:::tip`, and `:::caution` asides where helpful. Internal links are root-relative with a trailing slash (`/guides/install/`); links to repository files use absolute GitHub URLs. Every published page has an "Edit page" link that opens the file on GitHub, so small fixes can be PRed straight from the site.

Keep facts in sync with the app: defaults belong to `Sources/OmniWM/Core/Config/SettingsExport.swift`, the TOML schema to `CanonicalTOMLConfig.swift`, and default hotkeys to `Core/Input/ActionCatalog.swift`. The command palette uses substring matching with tiered ranking (not fuzzy search), and the quake terminal's default position is Center, which fades rather than slides.

## Landing page

`src/pages/index.astro` composes the sections in `src/components/landing/`: hero, contributor logo strip, featured switcher quote, the twelve feature sections (ordered most-important-first by the tag sequence in `index.astro`, layouts leading), CLI panel, testimonials, control-panel grid, trust, install, credits, sponsors, footer. The release version shown in the hero badge, the install section, and the JSON-LD structured data comes from the single constant in `src/data/site.ts`. Credits wording stays honest: contributors *work at* the listed companies; the companies themselves don't endorse OmniWM. The animated feature mockups live in `src/components/demos/` — each demo is scene markup plus a cue table driven by the shared runner in `src/scripts/demo-timeline.js`, with all motion done by CSS transitions on the tokens in `src/styles/demo-tokens.css`. Demos start when scrolled into view, loop with a rest, and honor `prefers-reduced-motion` by showing a static frame.

## Data files

- `src/data/employers.ts`, `education.ts`, `contributors.ts` mirror the machine-generated credits block in the repository README (`<!-- contributors:start -->` … `<!-- contributors:end -->`). When crediting someone new, update both.
- `src/data/sponsors.ts` mirrors the rank-ordered list in `Sources/OmniWM/UI/SponsorsView.swift`; sponsor avatars in `public/credits/sponsors/` are copies of the app-bundled images in `Sources/OmniWM/Resources/`.
- Employer and education logos in `public/credits/` are self-hosted copies downloaded once from the README's logo URLs.

## Brand assets

Everything in `public/` named `favicon*`, `apple-touch-icon.png`, `safari-pinned-tab.svg`, and the files in `src/assets/brand/` are verbatim copies from `assets/brand/web/` — that directory is canonical. Never redraw, recolor, or re-space them; re-copy when the brand package updates. Use `omniwm-logo.svg` at 180 CSS px or wider and `omniwm-mark.svg` below that; on dark backgrounds the site renders the same untouched SVGs as a warm-ivory silhouette via a CSS filter (`brightness(0) invert(1) sepia(0.06) saturate(0.8)`) so the background stays transparent. The macOS status-bar PDF assets are app-only and never appear on the website.

## Deployment

The site deploys to DigitalOcean App Platform as a static site — see `.do/app.yaml` at the repository root (Source Directory `website`, build `npm ci && npm run build`, output `dist`, error document `404.html`, domains `omniwm.app` + `www` alias). Bootstrap a fresh app with `doctl apps create --spec .do/app.yaml`; after creation the App Platform control panel is the source of truth, with the spec kept in sync as documentation. Pushing to `main` redeploys.
