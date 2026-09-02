# Writing a post

Posts are MDX files in `src/content/blog/`, one file per language. There is no
`/en/` or `/pt/` route — language is a reader preference, so the pair is linked
by frontmatter rather than by path.

## Naming and pairing

```
src/content/blog/2026-03-31-building-polaris.mdx      lang: en
src/content/blog/2026-03-31-construindo-polaris.mdx   lang: pt
```

The slug is the filename. The two files point at each other:

```yaml
# in the EN file
translationSlug: "2026-03-31-construindo-polaris"
# in the PT file
translationSlug: "2026-03-31-building-polaris"
```

That pairing drives the header language toggle and the `hreflang` tags. A post
without it still builds — the toggle just switches UI chrome instead of jumping
to the translation.

## Frontmatter

```yaml
---
title: "Short and concrete"
description: "One sentence. Used in listings, meta tags, RSS and the OG image."
date: 2026-09-02
lang: "en"              # en | pt
tags: ["ai", "astro"]   # lowercase; the homepage shows the top 8 as filters
series: "Radar"         # optional
translationSlug: "2026-09-02-..."  # the other language's slug
draft: false            # true hides it from listings, RSS and sitemap
---
```

`bun run build` validates every field against the zod schema in
`src/content/config.ts`. A failing build is the rejection; there is no other
check.

## Publishing

```bash
bun dev            # localhost:4321 — check both languages and both themes
bun run build      # the gate: schema, OG image generation, sitemap, RSS
```

Land both languages together. A post merged in one language reads as finished
work and is easy to forget.

## Things that bite

- **OG images** are rendered at build time from `public/fonts/*.ttf`. A very
  long title overflows the card rather than wrapping — check `/og/<slug>.png`
  in the dev server before publishing.
- **Tags are the homepage filter.** Inventing a near-duplicate (`ai` vs `AI` vs
  `artificial-intelligence`) splits the filter. Look at what exists first.
- **Code blocks** are highlighted by Shiki at build time; keep wide blocks
  narrow enough to scroll rather than stretch the page on mobile.
- **Reading time** is computed from the body, so there is no field to maintain.

## Generated posts

The weekly `Radar` digests under `2026-*-radar-ai-dev*.mdx` are produced by
`scripts/news/` as drafts. They are reviewed and published like any other post,
except that the review is where the value is added — see
[`NEWS-PIPELINE.md`](NEWS-PIPELINE.md).
