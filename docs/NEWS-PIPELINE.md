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
| 1 | nothing was produced — either nothing cleared the filters, or the target files already existed | read the `[news]` lines; they say which |
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

**Installed 2026-09-02.** `crontab -l | grep aethos-blog` confirms it.

`run-digest.sh` resolves node itself. Cron runs with `PATH=/usr/bin:/bin`, and
on this machine node is installed by **nvm**, under
`~/.nvm/versions/node/<version>/bin/` — on no fixed PATH at all. Prepending the
usual directories was not enough; the wrapper walks the nvm versions directory,
picks the newest with `sort -V` (plain sort puts v9 above v22), and verifies the
binary answers `-v` with Node 18+ before running anything.

🔴 **This was measured, not assumed.** The first run under a real cron
environment (`env -i PATH=/usr/bin:/bin`) exited 2 with
`FATAL: node not found`. The guard behaved exactly as designed — and the job
would still never have produced a digest. A guard that fails loudly is not the
same as a job that works; only running it the way cron will runs proves the
second.

Reproduce that check any time:

```bash
env -i HOME=$HOME PATH=/usr/bin:/bin SHELL=/bin/sh \
  NEWS_DIGEST_LOG=/tmp/cron-sim.log scripts/news/run-digest.sh; echo "exit=$?"
cat /tmp/cron-sim.log
```

Covered by `scripts/news/run-digest.test.sh` (12 assertions, 5 arms, 2
mutations), which runs the real wrapper under `env -i` with stub nvm trees.

Verify the job is alive by its log, never by the crontab entry:

```bash
tail -20 scripts/news/digest.log
grep -c 'RESULT=' scripts/news/digest.log     # runs that actually reached a verdict
```

An empty or absent log after a Monday means the job did not run at all — a
different problem from `RESULT=nothing-produced`.

🔴 **A run that writes no file must not report success.** Measured 2026-09-02:
re-running on a day whose digest already existed skipped both files and still
logged `DIGEST_OK ... drafts written`. It now logs `NOTHING_WRITTEN` and exits
1. That was exactly the false-green this pipeline exists to avoid, sitting in
the pipeline itself.

## Tuning what gets picked

Everything lives in `scripts/news/sources.json`:

- `sources[]` — feed URL, `tag` (lands on the post), `weight` (baseline score).
- `keywords` — term → points added when it appears in title or excerpt.
- `blocklist` — any hit drops the item outright (funding rounds, crypto, layoffs).
- `minScore` — the bar an item must clear. Raise it if digests feel noisy.
- `maxItems` — cap per digest (default 8). No single feed contributes more than 3.
- `maxAgeDays` — window. Items with no parseable date are **kept**, not dropped,
  so a feed with broken timestamps does not silently vanish.
- `maxUndated` — how many dateless items may reach one digest (default 2).

🔴 **A dateless item cannot age out, so "kept" once meant "immortal".** Measured
2026-09-02: the Google Developers Blog feed is RSS 2.0 with **no date element at
all** on its items, and a post from August 4th reached the first digest as this
week's news. The generator now names every such feed on stdout (`NO DATES  <feed>`)
and caps them. When you see that line, treat those items' recency as unknown and
check the page before publishing — the cap limits the damage, it does not date
anything.

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
   Also translate the **headings**: the generator reuses the source's English
   title verbatim in both files.
4. For any item under a `NO DATES` feed, open the page and find its real
   publication date. That is the check that would have caught the month-old item
   in the first digest.
5. Fix the title/description if the week has an obvious theme.
6. Set `draft: false` in both files.
7. `bun run build` — the schema is the gate.
8. Land both languages in the same commit.

What review actually costs, measured on the first digest: eight machine-written
summaries, **five rewritten and one removed entirely**. None of the errors were
invented facts — the numbers the model quoted all checked out. They were
confident vagueness ("provides valuable insight into how language models learn"
for a post about diffing published prompts) and omitted the one detail a
developer needed (that the new Copilot model requires data retention). Budget
real time for this step; skimming it produces plausible text that says nothing.

Invariant 2 is enforced by `fetch-news.test.sh` ARM 8, **not** by `CONTRACT.md` —
see the note in the contract for why two grep-shaped versions of that rule were
worthless.

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
