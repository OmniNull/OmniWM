---
title: Website Development
description: Run the website locally, edit documentation and demos, maintain credits, and understand deployment.
sidebar:
  order: 4
---

The OmniWM website: a landing page with animated feature demos and the knowledge base, built with [Astro](https://astro.build) + [Starlight](https://starlight.astro.build).

## Development

From a clone of the OmniWM repository, enter the website directory:

```sh
cd website
npm ci
npm run dev       # local dev server at localhost:4321
npm run build     # static build into dist/
npm run preview   # serve the built site
npm run check     # type-check content and components
```

Node 24 LTS required.

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

The full contributor guide is published at `/developers/contributing/`, and this website-development guide at `/developers/website/`. Keep their Markdown pages in sync with the repository copies in `CONTRIBUTING.md` and `website/README.md`; adapt navigation links to stay within the website.

The documentation follows `main`, which can include features newer than the latest release. Place an **Unreleased** note beside each unreleased feature or setting, stating that it is available when building from `main`. Check the feature against the latest release tag before removing the note. Keep download links and the displayed release version tied to the published release.

Keep facts in sync with the app: defaults belong to `Sources/OmniWM/Core/Config/SettingsExport.swift` and its `SettingsExport+*.swift` extensions; the domain settings types consume those defaults and map live values to/from the export. The TOML schema lives in `CanonicalTOMLConfig.swift`, and default hotkeys are assembled by `Core/Input/ActionCatalog.swift` from its `ActionCatalog+*.swift` extensions. The command palette uses substring matching with tiered ranking for its original four modes and Spotlight-style token matching for Applications and Files. The quake terminal's default position is Center, which fades rather than slides.

## Landing page

`src/pages/index.astro` composes the sections in `src/components/landing/`: hero, the twelve feature sections (ordered most-important-first by the tag sequence in `index.astro`, layouts leading), CLI panel, testimonials, control-panel grid, trust, install, credits, sponsors, footer. The release version shown in the hero badge, the install section, and the JSON-LD structured data comes from the single constant in `src/data/site.ts`; the release helper updates that file together with `Info.plist` and refuses to prepare a release if they already differ. Credits wording stays honest: contributors *work at* the listed companies; the companies themselves don't endorse OmniWM. The animated feature mockups live in `src/components/demos/` — each demo is scene markup plus a cue table driven by the shared runner in `src/scripts/demo-timeline.js`, with all motion done by CSS transitions on the tokens in `src/styles/demo-tokens.css`. Demos start when scrolled into view, loop with a rest, and honor `prefers-reduced-motion` by showing a static frame.

At the release that includes the new gestures and border effects, update the existing gesture blurb in `src/data/features.ts` to mention Overview, window move, and window resize, and expand the **Borders** tile to mention optional gradients and glow. Keep the current landing layout and release copy until those features ship.

## Data files

- `src/data/employers.ts`, `education.ts`, `contributors.ts` mirror the machine-generated credits block in the repository README (`<!-- contributors:start -->` … `<!-- contributors:end -->`). When crediting someone new, update both.
- `src/data/sponsors.ts` mirrors the rank-ordered list in `Sources/OmniWM/UI/SponsorsView.swift`; sponsor avatars in `public/credits/sponsors/` are copies of the app-bundled images in `Sources/OmniWM/Resources/`.
- Employer and education logos in `public/credits/` are self-hosted copies downloaded once from the README's logo URLs.

## Brand assets

Everything in `public/` named `favicon*`, `apple-touch-icon.png`, `safari-pinned-tab.svg`, and the files in `src/assets/brand/` are verbatim copies from `assets/brand/web/` — that directory is canonical. Never redraw, recolor, or re-space them; re-copy when the brand package updates. Use `omniwm-logo.svg` at 180 CSS px or wider and `omniwm-mark.svg` below that; on dark backgrounds the site renders the same untouched SVGs as a warm-ivory silhouette via a CSS filter (`brightness(0) invert(1) sepia(0.06) saturate(0.8)`) so the background stays transparent. The macOS status-bar PDF assets are app-only and never appear on the website.

## Deployment

The site deploys to DigitalOcean App Platform as a static site — see `.do/app.yaml` at the repository root (Source Directory `website`, Node 24, build script `npm run build`, output `dist`, error document `404.html`, domains `omniwm.app` + `www` alias). `www` and DigitalOcean's `${STARTER_DOMAIN}` placeholder permanently redirect to the apex while preserving paths. Bootstrap a fresh app with `doctl apps create --spec .do/app.yaml --wait`. The tracked app spec is the source of truth; validate it before updates and sync back any deliberate control-panel changes. DigitalOcean's native GitHub integration redeploys the site after every push to `main`.
