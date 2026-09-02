# aethos-blog — STATE

**status:** live · https://blog.aethostech.com.br
**last updated:** 2026-09-02

## What exists

| area | state |
|---|---|
| Blog | 40 published posts (20 EN + 20 PT-BR), latest 2026-03-31 |
| Stack | Astro 5, Tailwind v4, MDX, Shiki, Satori OG images, RSS + sitemap |
| Deploy | Vercel, static build from `main`. No CI status check — the pre-merge gate is manual (`bun run build`) |
| Recommendations | `/recommendations`, reader submissions via GitHub issue form, 6 seed entries |
| News digest | `scripts/news/` — weekly draft generator, 9 feeds, local Ollama summaries, 19-assertion suite |
| Docs | `docs/` (architecture, content, news pipeline, recommendations) + `CONTRACT.md` |

## In flight

- **Two Radar drafts pending review** — `src/content/blog/2026-09-02-radar-ai-dev.mdx`
  and `...-pt.mdx`, both `draft: true`. They are the pipeline's first real output;
  read them against their sources before publishing. See `docs/NEWS-PIPELINE.md`.
- **Weekly cron not installed yet.** `scripts/news/run-digest.sh` is ready and tested;
  installing the crontab line is an operator step (the harness cannot edit crontab).

## Known limits, stated rather than left implicit

- **No CI.** Nothing runs the build on a PR. Until a status check exists, running
  `bun run build` on the merged result before landing is the whole gate.
- **The digest depends on this machine.** Local Ollama, local cron. Machine off
  means no digest that week — a missed Monday, not a broken pipeline. The log
  distinguishes the two (`RESULT=BROKEN` vs no log line at all).
- **Recommendations need a GitHub account.** Deliberate trade for zero infra and
  zero spam surface. Reconsider only if real submissions get turned away by it.
- **Feeds rot.** `node scripts/news/fetch-news.mjs --check-sources` is the periodic
  check; one feed shipped 404 on day one and was swapped.

## Next candidates

1. Review and publish the two Radar drafts.
2. Install the weekly cron line.
3. GitHub Actions build check on PRs, so the Ship-Safe gate stops being manual.
4. Search across posts (client-side; the corpus is small enough for no index).
