# aethos-blog — STATE

**status:** live · https://blog.aethostech.com.br
**last updated:** 2026-09-02

## What exists

| area | state |
|---|---|
| Blog | 42 published posts (21 EN + 21 PT-BR), including the first Radar digest |
| Stack | Astro 5, Tailwind v4, MDX, Shiki, Satori OG images, RSS + sitemap |
| Deploy | Vercel, static build from `main` on push — **merging is deploying** |
| CI | `.github/workflows/ci.yml` on every PR: `astro check` + build + 3 suites + static/draft output assertions. **Required** by branch protection on `main` |
| Recommendations | `/recommendations`, reader submissions via GitHub issue form, 6 seed entries |
| News digest | `scripts/news/` — weekly, 9 feeds, local Ollama summaries. **Cron installed** (Mon 08:00) |
| Tests | news 22 · cron wrapper 12 · recommendations 19, all mutation-verified |
| Docs | `docs/` (architecture, content, news pipeline, recommendations) + `CONTRACT.md` |

## Open

Nothing outstanding. The three items listed here on 2026-09-02 are closed:

- **Branch protection** — enabled. `gate` is required, `strict` is on,
  force-push and deletion refused, and it applies to admins. Consequence worth
  knowing: direct pushes to `main` are now rejected for everyone, so the
  docs-only carve-out (prose may skip a PR) no longer applies in this repo.
- **`swarmvault.*` and its five empty directories** — generic scaffolding from a
  global CLI, byte-identical to the one in `~/projetos`, referenced by nothing
  here. Gitignored rather than deleted; they belong to that tool.
- **TS2345 in the OG route** — fixed, and the reason it survived from the
  initial commit is now gated: the build does not typecheck, so `astro check`
  runs in CI.

## Known limits, stated rather than left implicit

- **The digest depends on this machine.** Local Ollama, local cron. Machine off
  on a Monday means no digest that week. The log distinguishes the cases:
  `RESULT=BROKEN` (instrument), `RESULT=nothing-produced` (real quiet result),
  no log line at all (the job never ran).
- **Recommendations require a GitHub account.** Deliberate trade for zero infra
  and zero spam surface. Reconsider only if real submissions get turned away.
- **Feeds rot, and some publish no dates.** The Google Developers Blog feed has
  no date element at all, so its items cannot age out; they are capped at 2 per
  digest and named in the log. `--check-sources` is the periodic check.
- **Reviewing a digest is real work, not a formality.** First edition: eight
  machine-written summaries in, five rewritten, one removed.

## Next candidates

1. Client-side search across posts — the corpus is small enough to need no index.
2. Watch the first real cron digest (Monday 08:00) and review it before publishing.
