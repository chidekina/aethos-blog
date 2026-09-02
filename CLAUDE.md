# Aethos Tech Blog

Blog técnico da Aethos Tech. Bilíngue EN/PT-BR. Artigos sobre micro-SaaS, AI tooling, full-stack engineering e building in Brazil.

## Stack
- Astro + TypeScript
- Tailwind CSS v4
- MDX (artigos em markdown)
- Shiki (syntax highlighting)
- Satori + @resvg/resvg-js (OG images)
- `@astrojs/rss` (feed RSS)
- `@astrojs/sitemap`

## Structure
```
src/
  content/    # artigos MDX (EN + PT-BR)
  pages/      # rotas Astro
  components/ # componentes reutilizáveis
public/       # assets estáticos
```

## Commands
```bash
bun dev        # dev server (localhost:4321)
bun run build  # build produção em dist/
bun preview    # preview do build
```

## Content
- Artigos em `src/content/blog/*.mdx` — frontmatter: `title`, `description`, `date`,
  `lang`, `tags`, opcional `series`/`translationSlug`/`draft`. Ver `docs/CONTENT.md`.
- Bilíngue SEM prefixo de rota: idioma é preferência do leitor. O par EN/PT se liga
  pelo campo `translationSlug`, não pelo caminho.
- Imagens OG geradas automaticamente via Satori

## Deploy
- Vercel (inferir pelo `astro.config.mjs`)

## Automation & reader features (added 2026-09-02)

```
scripts/news/          # weekly AI/dev digest -> MDX drafts (never publishes)
scripts/recommendations/  # approved GitHub issue -> content JSON
docs/                  # ARCHITECTURE, CONTENT, NEWS-PIPELINE, RECOMMENDATIONS
CONTRACT.md            # machine-checked invariants; run before changing structure
```

```bash
node scripts/news/fetch-news.mjs --dry-run        # shortlist, writes nothing
node scripts/news/fetch-news.mjs --check-sources  # probe every feed
bash scripts/news/fetch-news.test.sh              # 19 assertions
python3 ~/.claude/hooks/contract-validate.py CONTRACT.md
```

🔴 `fetch-news.mjs` exit **2 is a broken instrument** (network down, Ollama
unusable, config unreadable), never a verdict about the news. Exit 1 is a real
quiet week. Do not chain it with `&&` as if 0/1 were the only outcomes.

🔴 The site is **static — no adapter, no server routes, no DB**. Reader input
arrives as GitHub issues and becomes content files. `CONTRACT.md` enforces this.

🔴 Generated digests carry `draft: true`. Publishing is a human reading each
one-liner against its source — the local model does invent numbers.
