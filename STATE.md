# aethos-blog — STATE

**status:** live · https://blog.aethostech.com.br
**last updated:** 2026-09-02

## What exists

| area | state |
|---|---|
| Blog | 42 published posts (21 EN + 21 PT-BR), including the first Radar digest |
| Stack | Astro 5, Tailwind v4, MDX, Shiki, Satori OG images, RSS + sitemap |
| Deploy | Vercel, static build from `main` on push — **merging is deploying** |
| CI | `.github/workflows/ci.yml` on every PR: build + 3 suites + static/draft output assertions. Vercel preview is a second independent check |
| Recommendations | `/recommendations`, reader submissions via GitHub issue form, 6 seed entries |
| News digest | `scripts/news/` — weekly, 9 feeds, local Ollama summaries. **Cron installed** (Mon 08:00) |
| Tests | news 22 · cron wrapper 12 · recommendations 19, all mutation-verified |
| Docs | `docs/` (architecture, content, news pipeline, recommendations) + `CONTRACT.md` |

## Open

- **Branch protection is not enabled.** The CI workflow exists and runs, but
  nothing yet *requires* it to pass before merge. Making it required is a repo
  setting, not a file: Settings → Branches → require the `gate` check. Until
  then CI reports, it does not block.
- `swarmvault.config.json` and `swarmvault.schema.md` sit untracked in the repo
  root. They were not created by this work; decide whether they belong here.
- `src/pages/og/[slug].png.ts:136` has a TS2345 (Buffer vs BodyInit) dating to
  the initial commit. Not blocking — the build does not typecheck — but the
  pre-commit hook reports it on every commit.

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

1. Require the CI check in branch protection (turns a report into a gate).
2. Client-side search across posts — the corpus is small enough to need no index.
3. Decide the fate of the two untracked `swarmvault.*` files.
