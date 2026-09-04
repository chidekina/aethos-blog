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

## `bun --cwd DIR run <script>` runs NOTHING and exits 0 (measured 2026-09-04)

The flag order is load-bearing. `bun --cwd "$R" run check` prints the list of
available scripts and **exits 0** — a false green indistinguishable from a
passing typecheck. The working form puts `--cwd` after `run`:

```bash
bun run --cwd "$R" check    # real: ends with `Result (14 files): - 0 errors`
bun --cwd "$R" run check    # fake: lists `$ bun run build`, exits 0, checked nothing
```

Tell them apart by the OUTPUT, never the exit code: a real `check` names the file
count it swept, a real `build` names pages built. This matters here because
`cd X && cmd` is silently blocked in the Claude Code harness, so every gate run
from outside the repo needs an explicit target — and the wrong flag order turns
that into a gate that guards nothing.

## Search

`src/pages/search-index.json.ts` emits `dist/search-index.json` at build time;
the homepage fetches it lazily on first focus and matches over full post bodies.
Metadata-only search was measured and rejected — 9 of 20 plausible terms appear
only in bodies. Details and the recompute command: `docs/ARCHITECTURE.md` §Search.

🔴 A narrowed index fails **silently** — queries just stop matching. The CI gate
derives a body-only word per post and asserts it reached the index; it is
mutation-verified, so do not weaken it to a presence check.

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
bash scripts/news/fetch-news.test.sh
bash scripts/news/check-entities.test.sh          # + .mutate.sh
bash scripts/news/capture-published.test.sh       # + .mutate.sh
python3 ~/.claude/hooks/contract-validate.py CONTRACT.md
```

🔴 Assertion counts are deliberately not written here. A count in prose goes
stale on the next commit and nothing recomputes it — run the suite.

**The eval pair.** Every run that writes a draft also writes
`scripts/news/editions/<date>.json` (tracked): the link, score, the exact
700-char prompt excerpt, and both model lines. After publishing, fill the other
half with `capture-published.mjs` — it REFUSES while `draft: true`, because
recording the model's output as the human's would make every later measurement
the model grading itself. `NEWS_EDITIONS_DIR` redirects it for tests; a suite
that forgets to writes fixture editions into the tracked tree.

🔴 `fetch-news.mjs` exit **2 is a broken instrument** (network down, Ollama
unusable, config unreadable), never a verdict about the news. Exit 1 is a real
quiet week. Do not chain it with `&&` as if 0/1 were the only outcomes.

🔴 The site is **static — no adapter, no server routes, no DB**. Reader input
arrives as GitHub issues and becomes content files. `CONTRACT.md` enforces this.

🔴 Generated digests carry `draft: true`. Publishing is a human reading each
one-liner against its source — the local model does invent numbers.
