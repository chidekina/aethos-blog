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

## Search

Client-side, over the full text of every post. Two pieces:

- `src/pages/search-index.json.ts` — a build-time endpoint emitting
  `dist/search-index.json`: one row per published post, `{slug, lang, text}`,
  with `text` pre-lowercased and stripped of code fences and JSX.
- the homepage script — a substring match over that index, folded into the same
  `applyFilters()` the tag and language filters already use.

**The index is a separate file, fetched lazily on first focus, and that is the
whole design.** Post bodies total ~281 KB against a ~142 KB homepage; inlining
them would roughly triple the page for every visitor to serve the few who
search. Measured after the change: the homepage grew 142010 → 145980 bytes
(+4 KB, the markup and slugs), and `search-index.json` is 224 KB that only a
searcher downloads.

🔴 **Metadata-only search was built, measured, and thrown away.** Indexing just
titles, descriptions and tags is free — that text is already in the DOM — but of
20 plausible query terms, **9 appear only in post bodies**: `typescript`,
`deploy`, `migration`, `cache`, `webhook`, `neon`, `rss`, `stripe`, `benchmark`.
A search that answers "no posts match" for `typescript` on this blog is worse
than no search, because the reader cannot tell a missing post from a narrow
index. Recompute before assuming it is still 9:

```bash
bun run build
python3 - <<'PY'
import json, glob, re
rows = json.load(open('dist/search-index.json', encoding='utf-8'))
meta = ' '.join(re.match(r'^---\n(.*?)\n---', open(f, encoding='utf-8').read(), re.S).group(1)
                for f in glob.glob('src/content/blog/*.mdx')).lower()
terms = ['typescript','deploy','migration','cache','webhook','neon','rss','stripe','benchmark']
body_only = [t for t in terms if t not in meta and any(t in r['text'] for r in rows)]
assert any(t in ' '.join(r['text'] for r in rows) for t in terms), 'CONTROL: index reads empty'
print(len(body_only), 'terms reachable only because bodies are indexed:', body_only)
PY
```

**A narrowed index fails silently** — queries simply stop matching, with no error
anywhere. The CI gate therefore derives, per post, a word that appears in the
body but not in the frontmatter and asserts it is in that post's indexed text.
Verified by mutation: deleting `toPlainText(post.body)` from the endpoint turns
the step red (`body word "hackers" from 2026-03-02-docker-cheap-vps is not in
the search index`), and the step is green on the restored file.

### States the reader can be in

Body text is not in the page markup, so a query cannot be answered before the
index arrives. Rather than filtering on titles in the meantime — which produces
confident false "no results" — the status line names the state: `Loading
search…`, a result count, or `Search unavailable` if the fetch fails, with tag
filters still working. `?q=` in the URL is shareable and loads the index without
waiting for a focus that will never come.

### Verified by driving it

Fourteen checks in headless Chromium at a 390px viewport, including the two that
a build cannot answer: the index is **not** fetched on page load, and a nonsense
query shows the empty state rather than everything. Playwright is deliberately
**not** a CI dependency — the build-time index gate is what runs on every PR;
the browser pass is a manual check when the homepage script changes.

## Build and deploy

```bash
bun install
bun dev          # localhost:4321
bun run build    # dist/ — this is the gate
bun preview
```

Vercel builds from `main` on push, so **merging is deploying**. The gate is
therefore on the pull request, not on the push: `.github/workflows/ci.yml` runs
`astro check`, the build (which is the content-schema validation), all three
test suites, and two output assertions — that the build produced no server functions, and that
no `draft: true` post reached the homepage.

That second assertion carries its own vacuity guard: it fails if `dist/blog` is
empty, because "no draft leaked" from a build that published nothing is not a
result. Verified 2026-09-02 on all three ends — green on the real tree, red
against a post forged to `draft: true` while still in `dist`, and refusing to
run when the output was emptied.

**`main` is protected** (since 2026-09-02): the `gate` check is required,
branches must be up to date before merging (`strict`), force-pushes and branch
deletion are refused, and the rule applies to admins too. Direct pushes to
`main` are rejected — the docs-only carve-out that lets prose skip a PR does
not survive that, and prose changes now go through a PR here like everything
else. To lift it in an emergency:
`gh api -X DELETE repos/chidekina/aethos-blog/branches/main/protection/enforce_admins`.

Vercel's own preview deployment is a second, independent check on every PR. It
has already caught a real defect that the local build could not: see the note on
`readExact()` above.

🔴 **Typechecking is `astro check`, never bare `tsc`.** This `src/` is 6 `.astro`
files to 3 `.ts`, and `tsc` does not parse `.astro` at all — measured: a forged
type error in `recommendations.astro` left `tsc --noEmit` reporting zero errors.
`typescript` is pinned to `^6` because 7.x is the native compiler and does not
expose the programmatic API `astro check` needs; bumping it breaks the CI step.

## Documentation map

| file | answers |
|---|---|
| `docs/ARCHITECTURE.md` | how the site is put together (this file) |
| `docs/CONTENT.md` | how to write and publish a post |
| `docs/NEWS-PIPELINE.md` | how the automated digest works and how to operate it |
| `docs/RECOMMENDATIONS.md` | how a reader suggestion becomes a page entry |
| `docs/adr/` | architectural decisions, including the ones still open |
| `CONTRACT.md` | the invariants a machine enforces |
| `STATE.md` | current status and what is in flight |
