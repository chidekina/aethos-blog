# News pipeline — runbook

Weekly AI/dev digest. Pulls RSS/Atom feeds, scores items for relevance,
summarizes each with a **local** Ollama model, and writes two MDX posts (EN and
PT) as **drafts**. Nothing reaches the site without a human flipping
`draft: false`.

```
sources.json ──▶ fetch ──▶ age + seen filter ──▶ keyword score ──▶ shortlist
                                                                     │
                                              Ollama (llama3.2:3b) ──┤
                                                                     ▼
                            src/content/blog/YYYY-MM-DD-radar-ai-dev{,-pt}.mdx
                                          (draft: true)
```

## Commands

```bash
node scripts/news/fetch-news.mjs --check-sources   # probe every feed, write nothing
node scripts/news/fetch-news.mjs --dry-run         # show the shortlist, write nothing
node scripts/news/fetch-news.mjs                   # write both drafts
node scripts/news/fetch-news.mjs --no-llm          # feed excerpts instead of summaries
bash  scripts/news/fetch-news.test.sh              # 19 assertions, 8 arms
```

## Exit codes — read them, do not chain with `&&`

| code | meaning | what to do |
|---:|---|---|
| 0 | drafts written | review them |
| 1 | reachable feeds, nothing cleared the filters | nothing; a genuinely quiet week |
| 2 | **broken instrument** — no network, every feed down, Ollama unusable, config unreadable | fix the tool; this is never a verdict about the news |

The 1-vs-2 split is the whole point. A dead Ollama and a quiet news week both
end in "no post today", and telling them apart afterwards is impossible if the
script collapses them into one code. `run-digest.sh` writes the distinction into
`scripts/news/digest.log` as `RESULT=ok|no-new-items|BROKEN`.

## Weekly cron

```bash
crontab -e
# Monday 08:00 — writes drafts, never publishes
0 8 * * 1 /home/hidekina/projetos/aethos/aethos-ideas/aethos-blog/scripts/news/run-digest.sh
```

`run-digest.sh` prepends the real PATH before doing anything and **checks that
`node` resolves**, exiting 2 with a logged `FATAL` if it does not. Cron runs
with `PATH=/usr/bin:/bin`; a node installed by brew or a version manager is not
on it. Measured on this machine 2026-08-31: a different daily job died at exit
127 for exactly this reason and produced roughly 540 runs with **zero log
lines** — the failure was indistinguishable from "nothing to do".

Verify the job is alive by its log, never by the crontab entry:

```bash
tail -20 scripts/news/digest.log
grep -c 'RESULT=' scripts/news/digest.log     # runs that actually reached a verdict
```

An empty or absent log after a Monday means the job did not run at all — a
different problem from `RESULT=no-new-items`.

## Tuning what gets picked

Everything lives in `scripts/news/sources.json`:

- `sources[]` — feed URL, `tag` (lands on the post), `weight` (baseline score).
- `keywords` — term → points added when it appears in title or excerpt.
- `blocklist` — any hit drops the item outright (funding rounds, crypto, layoffs).
- `minScore` — the bar an item must clear. Raise it if digests feel noisy.
- `maxItems` — cap per digest (default 8). No single feed contributes more than 3.
- `maxAgeDays` — window. Items with no parseable date are **kept**, not dropped,
  so a feed with broken timestamps does not silently vanish.

After editing, always:

```bash
node scripts/news/fetch-news.mjs --check-sources   # is the new feed reachable and parseable?
node scripts/news/fetch-news.mjs --dry-run         # does the shortlist look right?
```

A feed that 404s prints `FEED FAILED` and the run continues on the rest. Only
*every* feed failing is exit 2. Feeds rot: `--check-sources` is the periodic
check, and it is how the original Anthropic feed in this config was caught
returning 404 on day one.

## Reviewing a digest before publishing

The summaries come from `llama3.2:3b` running locally. It is fast and free and
it **does get things wrong** — it will confidently restate a benchmark number
from the excerpt without checking it. Review is not a formality:

1. Open both `src/content/blog/2026-*-radar-ai-dev.mdx` and `...-pt.mdx`.
2. Read each one-liner against the linked source. Rewrite anything that
   overstates, hedges wrongly, or invents a number.
3. Check the PT file is actually Portuguese throughout — the translation step is
   a second model call and can echo the English sentence back.
4. Fix the title/description if the week has an obvious theme.
5. Set `draft: false` in both files.
6. `bun run build` — the schema is the gate.
7. Land both languages in the same commit.

`CONTRACT.md` invariant 2 keeps the *generated* files at `draft: true`; that
rule is about the pipeline's output, and flipping the flag by hand as part of
review is the intended path — update the contract's glob if you rename the
series.

## State

`scripts/news/seen.json` holds the last 800 emitted links so a story is not
repeated week to week. It is written **only after the drafts exist**, so a crash
mid-run leaves the items available for the next one. It is versioned on purpose:
the dedupe memory belongs to the repo, not to one machine.

To force a re-run of the same week, delete the two draft files and remove their
links from `seen.json`.

## Configuration

| env | default | purpose |
|---|---|---|
| `OLLAMA_URL` | `http://localhost:11434` | where the model lives |
| `OLLAMA_MODEL` | `llama3.2:3b` | must be pulled; the script checks and exits 2 if not |
| `NEWS_FETCH_TIMEOUT_MS` | `20000` | per feed |
| `NEWS_LLM_TIMEOUT_MS` | `120000` | per model call |
| `NEWS_CONFIG` / `NEWS_SEEN` / `NEWS_POSTS_DIR` | repo paths | test-only overrides |
| `NEWS_DIGEST_LOG` | `scripts/news/digest.log` | cron log location |
