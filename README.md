# Kina Tech Blog

Technical blog by [Kina Tech](https://kinatech.com.br) — articles on micro-SaaS, AI tooling, full-stack engineering, and building in Brazil.

Built with **Astro** + **TypeScript**. Bilingual: EN 🇺🇸 / PT-BR 🇧🇷.

## Features

- EN/PT-BR language toggle with localStorage persistence
- Animated background and smooth theme transitions
- Dark/light mode
- Collapsed tag system on post listings
- SEO: OpenGraph, Twitter meta, sitemap, robots.txt
- Mobile-responsive navbar
- MDX posts with frontmatter

## Structure

```
src/
├── content/blog/        # MDX posts (YYYY-MM-DD-slug.mdx)
├── layouts/
│   └── BaseLayout.astro # Main layout with theme + i18n
├── pages/
│   ├── index.astro      # Post listing
│   ├── about.astro
│   └── blog/[...slug].astro
└── styles/global.css
```

**Post naming convention:**
- `YYYY-MM-DD-slug.mdx` → English
- `YYYY-MM-DD-slug-pt.mdx` or `YYYY-MM-DD-slug-ptbr.mdx` → Portuguese

## Commands

```bash
bun install       # Install dependencies
bun dev           # Dev server at localhost:4321
bun build         # Build to ./dist/
bun preview       # Preview production build
```

## Agent-friendly Markdown

Each published post has a static `/blog/<slug>.md` twin, linked from its HTML
head. It contains the title, date, language, tags, description, and raw body
with MDX module statements removed (code examples are preserved).
Negotiation is configured via `vercel.json` routes and is **to be verified on a
Vercel preview**: `Accept: text/markdown` should serve the twin at the post URL,
with HTML for default and `text/html` requests and `Vary: Accept` on both variants.

```bash
curl -i -H 'Accept: text/markdown' https://blog.aethostech.com.br/blog/2026-02-20-hello-world
curl -i https://blog.aethostech.com.br/blog/2026-02-20-hello-world
curl -i -H 'Accept: text/html' https://blog.aethostech.com.br/blog/2026-02-20-hello-world
bash scripts/agent-md/verify.sh dist
bash scripts/agent-md/verify.test.sh
bash scripts/agent-md/verify.sh https://blog.aethostech.com.br
```

Preview SSO requires `VERCEL_AUTOMATION_BYPASS_SECRET` in the environment for
live verification. The script sends it as the protection bypass header.
Astro dev/preview does not honor `vercel.json`; request the `.md` URL directly there.

## Writing Posts

Create a new `.mdx` file in `src/content/blog/`:

```mdx
---
title: "Post Title"
description: "Short description for SEO and listing"
pubDate: 2026-02-21
tags: ["astro", "tutorial"]
lang: "en"
---

Post content here...
```

Required frontmatter: `title`, `description`, `pubDate`, `lang`.
Optional: `tags`, `heroImage`, `draft`.
