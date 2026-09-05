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

# the eval pair (docs/DIGEST-EVAL.md items 1-2)
node scripts/news/check-entities.mjs scripts/news/editions/<date>.json
node scripts/news/capture-published.mjs scripts/news/editions/<date>.json

# suites — run them, do not cite their assertion counts here: a count in prose
# goes stale on the next commit and nothing recomputes it
bash scripts/news/fetch-news.test.sh
bash scripts/news/check-entities.test.sh
bash scripts/news/capture-published.test.sh
bash scripts/news/excerpt.test.sh
bash scripts/news/check-entities.mutate.sh        # each mutation must turn the suite red
bash scripts/news/capture-published.mutate.sh
bash scripts/news/excerpt.mutate.sh
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

> **Open decision:** whether this should run here at all, or move to a hosted
> scheduler with a paid API, is recorded — undecided — in
> [`docs/adr/ADR-001-digest-inference-host.md`](adr/ADR-001-digest-inference-host.md).
> It is deliberately gated on evidence from the first real Monday runs.

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

### Is 8 still the right size? — measured 2026-09-04

The handoff carried "`maxItems` is still 8 while 133 candidates now clear
`minScore`", read as evidence the digest was starved. **`maxItems` is not the
binding constraint**, and the 133 never described a reachable pool.

`minScore` and the per-source cap are two different gates, and only the second
one is close to binding. One run, all 36 feeds, `--dry-run` so nothing is written:

| stage | items |
|---|---:|
| fetched | 2772 |
| within `maxAgeDays` (8) | 155 |
| unseen | 148 |
| **clears `minScore`** | **140** |
| **reachable after `maxPerSource: 3`** | **42** |
| shipped (`maxItems: 8`) | 8 |

So the choice is 8 out of 42, not 8 out of 140. Raising `maxItems` to 12 reaches
score 12; to 20, score 10. The head is thin — three items score 15+ above the
rest — and every extra line is a line a human must check against its source, at
a measured first-edition rate of 7 of 7 summaries rewritten and 1 item dropped
— **zero** model sentences reached the published post, in either language. Review
is the bottleneck, not supply. (Recompute per edition; see ADR-001.)

**Lowering `maxPerSource` to 2 was tried and rejected on the same run.** It
looks like a diversity win (one feed held ranks 1-3, 37.5% of the digest) and
measured as neither: distinct sources stayed at 5 either way, and the digest
traded a score-17 item for a score-12 one. Cap stays at 3.

Both numbers stand as they are. What would reopen the question: distinct sources
in the shipped 8 dropping to 3 or fewer, or the reachable pool (`42` here)
falling near `maxItems`, which would mean the caps — not the editor — are
choosing the digest.

🔴 **Recompute rather than citing these numbers.** The feeds are live; every row
above changes weekly. Both runs below write nothing and leave `seen.json`
untouched, and the second is the control — without it, a wide config that
silently failed to load would look like "the cap is not binding".

```bash
node scripts/news/fetch-news.mjs --dry-run          # what ships: the `shortlist` count

# the reachable pool: same config, caps lifted (writes nothing)
node -e 'const f=require("fs"),c=JSON.parse(f.readFileSync("scripts/news/sources.json","utf8"));
c.maxItems=500;c.maxUndated=500;f.writeFileSync("/tmp/wide.json",JSON.stringify(c))'
NEWS_CONFIG=/tmp/wide.json node scripts/news/fetch-news.mjs --dry-run | grep shortlist
```

A wide run whose `shortlist` equals the narrow run's is the instrument failing to
read `NEWS_CONFIG`, never a genuine result.

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
summaries, **one removed entirely and all seven survivors rewritten** — zero of
the model's sentences reached the published post in either language.

🔴 This paragraph said "five rewritten" until 2026-09-04. ADR-001 corrected the
number to 7 of 7 when it was accepted, and **this doc was not updated in the same
pass**, so the stale figure stayed in circulation in the file an operator actually
reads before reviewing. Recompute rather than trust either number:

```bash
node --input-type=module -e "
import { readFileSync } from 'node:fs';
const parse=(f)=>{const m=new Map();
  for(const x of readFileSync(f,'utf8').matchAll(/^### \[([^\]]*)\]\(([^)]+)\)\s*\n+([\s\S]*?)(?=\n+<small>)/gm))
    m.set(x[2],x[3].trim().replace(/\s+/g,' ')); return m;};
const d=parse(process.argv[1]), p=parse(process.argv[2]);
if(!d.size||!p.size) { console.log('BLIND PARSER'); process.exit(2); }  // control
let kept=0,verbatim=0;
for(const [l,dl] of d){ const pl=p.get(l); if(pl===undefined) continue; kept++; if(pl===dl) verbatim++; }
console.log('kept='+kept+' cut='+(d.size-kept)+' verbatim='+verbatim);
" <draft.mdx> <published.mdx>
```

From 2026-09-07 the pair is captured on purpose — see **The eval pair** below —
so this stops needing git archaeology. None of the errors were
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

## The eval pair

Every run that writes a draft also writes `scripts/news/editions/<date>.json` —
the DRAFT half: each item's link, its score, the **exact 700-char excerpt the
prompt carried**, and both model lines. That excerpt is the ground the entity
check measures against, so the model is judged on what it was shown and not on
material it never saw.

The same run prints advisory `ENTITY_CHECK` lines for any identifier or number a
summary asserts that its source does not, and for any identifier the PT line
dropped. Advisory on purpose: these are drafts, a human reads every line anyway,
and a blocking gate here would stop an edition over a token the reviewer was
about to fix. The point is that the check is **invoked** — a check nobody runs is
the prose it was meant to replace.

After publishing (`draft: false` on both files, both committed):

```bash
node scripts/news/capture-published.mjs scripts/news/editions/<date>.json
```

It fills the published half in place, keyed by **link** rather than by position —
a human may reorder or drop items, and matching by index would pair one item's
prose with another's source. Two refusals matter more than the capture:

- **Still a draft → exit 1, nothing written.** Recording the model's own output
  as the human's would make every later measurement the model grading itself.
- **Zero links matched → exit 2, a broken instrument.** "The human cut every
  item" and "the post body shape changed" look identical otherwise.

`scripts/news/editions/` is versioned. That is the whole point: an eval set that
lives only on one machine is not an eval set. **Edition 1 (2026-09-02) is in
there, backfilled from `d44b785`/`e8d6510`** so the set starts with a real row
instead of a doc describing an empty directory. Its `sourceExcerpt` is `null` and
not recoverable — the feeds moved on — so the two grounding lanes report
`no-ground` on it. That is a lane not applicable, not a fault, and inventing an
excerpt would produce a confident verdict about text the model never saw.

### What the check can and cannot see — measured 2026-09-04

Stated so nobody reads a zero as coverage:

| corpus | items | items with nothing checkable | tokens checked |
|---|---:|---:|---:|
| edition 1, LLM draft | 8 | 1 | 19 |
| edition 1, published | 7 | 3 | 17 |
| a `--no-llm` run | 8 | **8 — the check has no power at all** | 0 |

🔴 **Under `--no-llm` the check is powerless by construction**, and it now says so
with an `ENTITY_CHECK VACUOUS` line instead of a reassuring zero. The PT line is a
copy of the EN line, so the EN→PT lane is not applicable; and each summary is a
slice of its own excerpt, so the grounding lanes are a tautology. Before this was
caught, the same run logged *"0 ungrounded finding(s) … 42 tokens checked"* — and
not one of those 42 could ever have been missing.

The lesson generalises past this script: **a lane that cannot fail must not report
a pass.** `no-tokens`, `no-ground`, `not-translated` and `tautological` are four
different ways of having nothing to say, and all four are distinct from `pass`.

## 🔴 RETRACTED — the two models DO fit; what varies is how long a load takes

**This section's original claim was measured false on 2026-09-04.** It said a
4096 MiB GPU "cannot hold" `llama3.2:3b` (2.8 GB) alongside `nomic-embed-text`
(595 MB) and that ollama "waits for a slot rather than evicting". Both halves
fell to direct measurement, and the corrected account is at the end of this
section under **What was actually measured**. The original text is kept below
rather than deleted, because a retraction that erases what it retracts leaves the
next reader unable to tell which version they are holding.

### The original claim, as written

The digest hung for a whole session, and none of the three obvious diagnoses was
right. Recorded because the wrong ones all *looked* right.

| what it looked like | what it was |
|---|---|
| a stale runner from a previous run | `systemctl restart ollama` cleared it and the hang **reproduced from cold** |
| a corrupt model blob | intact — 2 019 377 376 bytes, exactly what the manifest declares, reading at 581 MB/s |
| the server saturated by embedding traffic | the flood was real but incidental; the hang persisted with the server idle |

The actual cause, with numbers:

```
GPU total                                  4096 MiB
llama3.2:3b   @ ctx 4096                   2.8 GB
nomic-embed-text:latest                    595 MB
```

They do not fit together, and **ollama waits for a slot rather than evicting**.
The runner spawns, answers its own `/health` with `{"status":2,"progress":0}`,
sits at ~200 MB RSS, and never advances. `ollama ps` does not list it, so it is
invisible from the obvious place to look.

**A cold load with the slot free takes 7 s.** The probe budget is 30 s, so the
timeout was never the problem and raising it only makes the hang longer.

### What was actually measured — 2026-09-04, three runs plus a poll

| measurement | result |
|---|---|
| both models resident at once | **3345 MB of 4096** — `/api/ps` listed both, `nvidia-smi` agreed at 3323 MiB |
| load with `nomic` resident, run A | **~35 s**, and afterwards **both** were loaded — it coexisted |
| load with `nomic` resident, run B | **4.6 s**, and afterwards only ours — it **evicted** |
| cold load, GPU at 0 MiB | **8.7 s** |
| `/api/ps` polled every ~0.4 s through that cold load | **empty for 8.5 s of the 8.7 s**, while the GPU climbed to 2743 MiB |

Two claims fall and one stands.

- ❌ *"They do not fit."* They do, with 750 MB to spare.
- ❌ *"Ollama waits rather than evicting."* Run A coexisted, run B evicted. The
  behaviour is **not stable between runs**, so neither verb belongs in a rule.
- ✅ **A model being LOADED is not listed by `/api/ps` until it finishes.** That is
  reproducible, and it is the one fact that explains what the digest saw.

**So the failure signature reads differently now.** "Generation timed out AND
`/api/ps` is empty" is a **load in progress**, not an idle server and not a wedged
runner. And since observed loads span 4.6 s to ~35 s, a 30 s probe budget sat
**inside** that spread — which is how an ordinary slow load became
`RESULT=BROKEN`. `NEWS_PROBE_TIMEOUT_MS` now defaults to **60 s**.

🔴 The retracted version had already reached three places before it was checked:
this section, a comment block in `fetch-news.mjs`, and two test-arm assertions.
It was retracted in all four in the same change — a corrected source with a stale
derivative in circulation is worse than not correcting at all.

**Recompute, and it is cheap** (the numbers above are from one machine on one
day; VRAM pressure from other processes moves them):

```bash
ollama stop llama3.2:3b; ollama stop nomic-embed-text:latest
nvidia-smi --query-gpu=memory.used --format=csv,noheader     # CONTROL: must be ~0
S=$(date +%s.%N)
curl -s localhost:11434/api/generate -H 'content-type: application/json' \
  -d '{"model":"llama3.2:3b","prompt":"hi","stream":false}' >/dev/null
python3 -c "print(f'{$(date +%s.%N)-$S:.1f}s')"
# and, in a second shell DURING that call, the fact that matters:
curl -s localhost:11434/api/ps      # empty while the GPU is already climbing
```


```bash
curl -s localhost:11434/api/ps | python3 -m json.tool   # who holds the slots
ollama stop <the OTHER model>                           # the fix
```

🔴 **Stopping `llama3.2:3b` does nothing in this state** — it is not wedged, it is
queued. The model to stop is the one holding the slot. `fetch-news.mjs` now says
so: on a probe timeout it reads `/api/ps` and names the actual holder, because
the message it printed before sent the reader to the wrong model.

🔴 **`ollama stop` returns 0 whether or not it stopped anything.** It returned 0
against a runner it could not touch. Verify by `ollama ps` or by the GPU, never
by the exit code.

Durable fix, not applied here because it needs root and changes behaviour for
every other ollama client on the machine: `OLLAMA_MAX_LOADED_MODELS=1` in the
service environment makes ollama evict instead of wait.

### An EMPTY `/api/ps` identifies no cause — measured 2026-09-04, cron rehearsal

The section above is written for the case where `/api/ps` **names a holder**. It
does not always. The first rehearsal of the cron entry, fired from a real
crontab rather than simulated with `env -i`, produced:

```
[news] INSTRUMENT: Ollama unusable — catalogue answers but generation did not
       respond within 30000ms. Nothing is reported loaded, so this looks like a
       genuinely wedged runner: `ollama stop llama3.2:3b`.
RESULT=BROKEN
```

Three facts measured on the same machine within ten minutes:

| | |
|---|---|
| `/api/ps` at the moment of the timeout | **empty** |
| generation during the run | **outlived 30 000 ms** |
| cold load minutes later, GPU at 0 MiB of 4096 | **8 s**, `curl` status 0 |

Together those identify **no cause**. The 8 s cold load rules out the budget;
the empty `/api/ps` rules nothing in, because **a load queued waiting for a slot
is invisible there by construction** — the same property this document already
records one section up. So "the runner is wedged" and "something held the card
and released it" render identically, and the message picked the first, whose
prescribed fix (`ollama stop` our own model) is the one measurement had already
refuted.

🔴 **And `loadedModels()` returned `[]` for three different states**: nothing
loaded, `/api/ps` answering non-200, and `/api/ps` unreachable. An unreadable
reader and an empty subject were the same value, so a broken instrument was
reported as a finding about the server. It now returns `queried` separately, and
the message says which of the two it is.

What the pipeline reports today, per reading:

| `/api/ps` | message |
|---|---|
| names another model | free the **other** model, with its name and size |
| names only ours | wedged rather than blocked, stop ours |
| answers, empty | states plainly that this identifies no cause, and why |
| cannot be read | names it unreadable, never as empty |

The rehearsal is what surfaced this: the wrapper itself is sound — it resolved
node through nvm under cron's `PATH`, fetched 2779 items, shortlisted 8, and
wrote its `RESULT=` line. Only the diagnosis was wrong, and only a real firing
showed it.

### Rehearsing the cron entry — the procedure, and the two ways it bites

`env -i PATH=/usr/bin:/bin` **simulates** cron. It does not exercise cron's
shell, its signal handling, or the fact that a leftover line keeps firing. The
digest entry ran for the first time on 2026-09-04 through a temporary crontab
line, and that is the only thing that showed the diagnosis was wrong.

```bash
R=/home/hidekina/projetos/aethos/aethos-ideas/aethos-blog
S=$HOME/.aria/state/news-rehearsal        # DURABLE, not a session scratchpad
mkdir -p "$S/posts" "$S/editions"
cp "$R/scripts/news/seen.json" "$S/seen.json"
crontab -l > "$S/crontab.backup.txt"      # BEFORE anything else

# fire two minutes out; env vars inline, cron runs the line under /bin/sh
T=$(date -d '+2 minutes' '+%M %H'); MIN=$((10#${T% *})); HR=$((10#${T#* }))
{ cat "$S/crontab.backup.txt"; echo "# REHEARSAL-TEMP"; \
  echo "$MIN $HR * * * NEWS_DIGEST_LOG=$S/digest.log NEWS_SEEN=$S/seen.json \
NEWS_POSTS_DIR=$S/posts NEWS_EDITIONS_DIR=$S/editions $R/scripts/news/run-digest.sh"; \
} | crontab -                              # STDIN — see the 99-char trap below

# wait, then read the RESULT= line — never the exit code
: > "$S/digest.log"
bash ~/.claude/hooks/wait-for-line.sh "$S/digest.log" 'RESULT=' 600

# REMOVE IT, and verify by effect with a positive control
crontab - < "$S/crontab.backup.txt"
crontab -l | grep -c 'REHEARSAL-TEMP'      # must be 0
crontab -l | grep -c 'run-digest.sh'       # must be 1 — the Monday entry survived
```

🔴 **A leftover rehearsal line fires DAILY.** The removal is verified by effect,
and the positive control is what makes the zero mean something: a `crontab -r`
typo would also produce zero, having removed everything.

🔴 **`crontab FILE` silently truncates the path at 99 characters.** Measured
2026-09-04 on this machine — a 154-char scratchpad path came back
`… : No such file or directory` with the printed path 99 chars long, while an
identical file at a short path validated fine. The threshold is exact: **≤99
works, ≥100 fails**, and the error names a missing file rather than a truncated
argument, so it reads as "the backup is gone".

| path length | `crontab -n <path>` |
|---:|---|
| 99 | syntax checked |
| 100 and above | `No such file or directory` |

**Use `crontab - < file`.** Stdin carries no path.

🔴 And `crontab -T` does not exist here; the dry-run flag is **`-n`**. The wrong
flag prints usage and exits 1 for *every* input, so a three-arm check with it
returns three identical failures — a blind instrument reading as a finding.

## Configuration

| env | default | purpose |
|---|---|---|
| `OLLAMA_URL` | `http://localhost:11434` | where the model lives |
| `OLLAMA_MODEL` | `llama3.2:3b` | must be pulled; the script checks and exits 2 if not |
| `NEWS_FETCH_TIMEOUT_MS` | `20000` | per feed |
| `NEWS_LLM_TIMEOUT_MS` | `120000` | per model call |
| `NEWS_CONFIG` / `NEWS_SEEN` / `NEWS_POSTS_DIR` / `NEWS_EDITIONS_DIR` | repo paths | test-only overrides |
| `NEWS_DIGEST_LOG` | `scripts/news/digest.log` | cron log location |
