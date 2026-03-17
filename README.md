# Aethos Tech Blog

Technical blog by [Aethos Tech](https://aethos.com.br) — articles on micro-SaaS, AI tooling, full-stack engineering, and building in Brazil.

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
