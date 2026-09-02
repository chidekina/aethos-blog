# Architecture — aethos-blog

Bilingual (EN/PT-BR) engineering blog for Aethos Tech. Astro 5, statically
built, deployed on Vercel from `main`.

## The one decision everything else follows from

**The site has no server.** No Astro adapter, no API routes, no database. Every
page is HTML produced at build time. That is invariant 1 in
[`CONTRACT.md`](../CONTRACT.md) and the machine enforces it.

The consequence worth stating plainly: *reader input cannot be written by the
site*. Recommendations therefore arrive as GitHub issues and become content
files in a commit. The build is the moderation queue. Adding an adapter to
accept form posts is a real option, but it is an architecture change — a new
runtime, a database, spam handling, and a deploy that can fail at request time
rather than at build time.

## Layout

```
src/
  content/
    config.ts              # zod schemas — the only content validation layer
    blog/*.mdx             # posts, one file per language
    recommendations/*.json # one file per reader recommendation
  layouts/BaseLayout.astro # shell: head, nav, i18n dictionary, theme, starfield
  pages/
    index.astro            # post list + tag/language filter
    recommendations.astro  # category-filtered recommendation list
    about.astro
    blog/[...slug].astro   # post page
    og/[slug].png.ts       # OG image, rendered with Satori + resvg
    rss.xml.ts             # feed
    404.astro
  styles/global.css        # CSS custom properties, light/dark, .prose
scripts/
  news/                    # news digest pipeline (see NEWS-PIPELINE.md)
  recommendations/         # issue -> content file helper (see RECOMMENDATIONS.md)
public/                    # fonts (Satori needs the .ttf), favicon, robots, rss.xsl
.github/ISSUE_TEMPLATE/    # the reader-facing submission form
```

There is no `src/components/`. Pages carry their own markup and inline styles;
shared concerns live in `BaseLayout.astro` and in the CSS custom properties in
`global.css`. Keep it that way until a third page needs the same block — a
component extracted for two callers costs more than it saves here.

## How the two languages work

Language is a **client-side preference**, not a route prefix. There is no
`/en/` or `/pt/`.

- Each post declares `lang: 'en' | 'pt'` and a `translationSlug` pointing at its
  pair. `translationSlug` is what makes the header toggle jump between the two
  versions of the same article, and what feeds the `hreflang` tags.
- Chrome (nav labels, section headings, empty states) is translated at runtime
  from the `i18n` dictionary inside `BaseLayout.astro`, keyed by `data-i18n`
  attributes. Adding a UI string means adding the key in **both** `en` and `pt`
  objects — a key present in one and missing in the other silently keeps the
  English text.
- The choice persists in `localStorage['aethos-lang']` and is broadcast as the
  `aethos:lang-change` DOM event, which the homepage post filter listens to.

A page that renders both languages at once (like `/about`) uses
`data-lang-block="en|pt"` on wrapper elements; the layout shows one and hides
the other.

## Content schemas are the gate

`src/content/config.ts` defines two collections:

| collection        | type      | shape                                                      |
|-------------------|-----------|------------------------------------------------------------|
| `blog`            | `content` | MDX with frontmatter: title, description, date, lang, tags, optional series/translationSlug/draft |
| `recommendations` | `data`    | JSON: title, url, category, description (≤280), lang, tags, recommendedBy, addedAt |

**`bun run build` failing IS the validation.** A malformed recommendation or a
post with a bad `lang` stops the build; there is no second checking layer and
none should be added. `draft: true` excludes a post from every listing, the RSS
feed and the sitemap.

`category` in the recommendation schema and `CATEGORIES` in
`src/pages/recommendations.astro` are two lists that must agree — a category
accepted by the schema but missing from the page renders no tab, so the entry
becomes unreachable while the build stays green.

## Rendering details worth knowing before you touch them

- **OG images** are generated per post by `src/pages/og/[slug].png.ts` using
  Satori (HTML→SVG) and `@resvg/resvg-js` (SVG→PNG). Satori cannot read system
  fonts, so the route loads a `.woff` straight out of
  `node_modules/@fontsource/inter/files/` at build time — **not** from
  `public/fonts/`, whose `.ttf` files are unreferenced leftovers (measured:
  zero matches for `fonts/` under `src/`, with a positive control proving the
  search was not blind).
  🔴 That font must be read with `readExact()`, never `readFileSync(p).buffer`.
  A Node Buffer can be a view into a shared allocation pool, so `.buffer` hands
  back the whole pool and Satori parses whatever sits at offset 0. It broke the
  Vercel build with `Unsupported OpenType signature 'use` while the same commit
  built clean locally, because the failure depends on allocation order and
  therefore moves with unrelated changes.
- **Syntax highlighting** is Shiki, configured through Astro's markdown
  pipeline; no client-side highlighter ships.
- **Theme** is a `light` class on `<html>` plus CSS custom properties, restored
  from `localStorage['aethos-theme']`.
- **The starfield** is a `<canvas>` painted by the inline script at the bottom
  of `BaseLayout.astro`. It is decorative, `aria-hidden`, and pointer-events
  none.

## Build and deploy

```bash
bun install
bun dev          # localhost:4321
bun run build    # dist/ — this is the gate
bun preview
```

Vercel builds from `main` on push, so **merging is deploying**. The gate is
therefore on the pull request, not on the push: `.github/workflows/ci.yml` runs
the build (which is the content-schema validation), all three test suites, and
two output assertions — that the build produced no server functions, and that
no `draft: true` post reached the homepage.

That second assertion carries its own vacuity guard: it fails if `dist/blog` is
empty, because "no draft leaked" from a build that published nothing is not a
result. Verified 2026-09-02 on all three ends — green on the real tree, red
against a post forged to `draft: true` while still in `dist`, and refusing to
run when the output was emptied.

Vercel's own preview deployment is a second, independent check on every PR. It
has already caught a real defect that the local build could not: see the note on
`readExact()` above.

## Documentation map

| file | answers |
|---|---|
| `docs/ARCHITECTURE.md` | how the site is put together (this file) |
| `docs/CONTENT.md` | how to write and publish a post |
| `docs/NEWS-PIPELINE.md` | how the automated digest works and how to operate it |
| `docs/RECOMMENDATIONS.md` | how a reader suggestion becomes a page entry |
| `CONTRACT.md` | the invariants a machine enforces |
| `STATE.md` | current status and what is in flight |
