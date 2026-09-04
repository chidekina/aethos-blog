# ADR-001 — Where the weekly digest runs its inference

- **Status:** Proposed — the operator has not decided. Recorded so the choice is
  made, not defaulted into.
- **Date:** 2026-09-04
- **Context:** the open question carried in `.planning/.continue-here.md`:
  *"Should the digest move off local inference?"*

## The question

The weekly digest runs on this machine: a `cron` entry invokes
`scripts/news/run-digest.sh`, which calls `fetch-news.mjs`, which summarizes
each shortlisted item through a local Ollama (`llama3.2:3b` at
`localhost:11434`). The proposal is to move it to a GitHub Actions `schedule`
plus a paid LLM API.

**Measured call volume:** 2 calls per item — `summarizeEn` then `translatePt`
(`fetch-news.mjs:429-430`) — against `maxItems: 8`. **16 calls per week.**

```bash
# the two call sites. Anchored on `await` so the function DEFINITIONS do not
# inflate the count — a bare name matches 3 lines here, not 2.
grep -nE 'await (summarizeEn|translatePt)\(' scripts/news/fetch-news.mjs
grep -n '"maxItems"' scripts/news/sources.json                        # items per digest
```

## What is actually wrong today

Not scheduling. Measured 2026-09-03: cron fires, and the wrapper resolves nvm
node correctly under `env -i PATH=/usr/bin:/bin`. What broke mid-session was
**inference** — the Ollama runner sat at 0.0% CPU for 51 minutes while every
`/api/generate` timed out at 600 s, cold and warm alike, and embeddings on a
different resident model answered instantly throughout. It cleared on its own.

Two mitigations already shipped, and they bound the damage rather than remove it:

- `fetch-news.mjs` probes with a **real generate call**, never `/api/tags`, and
  exits 2 (`INSTRUMENT`, not "quiet news week") when the runner is wedged.
- `run-digest.sh` wraps the run in `timeout(1)` and logs `RESULT=timeout`.

So a wedge is now **reported**. It is still a wedge, and it still means no digest
that week.

## Blast radius

Tracked files mentioning Ollama:

| file | what it is |
|---|---|
| `scripts/news/fetch-news.mjs` | the two call sites and the liveness probe |
| `scripts/news/fetch-news.test.sh` | 46 assertions, several stubbing the Ollama endpoint |
| `scripts/news/run-digest.sh` | the cron wrapper, 20 assertions |
| `docs/NEWS-PIPELINE.md` | the runbook |
| `CONTRACT.md` | **invariant 5** |

Nothing in `src/` touches inference — the site never talks to a model. The blast
radius is the pipeline and its two suites, not the blog.

## The consequences a cost comparison hides

**1. It breaks CONTRACT invariant 5.** The contract says, today truthfully,
*"No secrets in the repo. The news pipeline talks to a local Ollama over
`OLLAMA_URL`; nothing here needs an API key."* A paid API needs a key. That is
not a blocker — it is a contract amendment that must land **in the same commit**
as the change, or the contract starts lying.

**2. The digest writes files, and `main` is protected.** Today the generator
writes MDX into the working tree and a human reviews and commits. A GitHub
Actions run cannot push to `main` — protection is on with `enforce_admins`. It
would have to **open a pull request** carrying the drafts. That is arguably
better (review has a natural surface) but it is new machinery, not a lift-and-shift.

**3. `run-digest.sh` and its 20 assertions become dead weight.** The wrapper
exists to give cron a timeout, a log and a `RESULT=` line. Actions has its own
timeout and log. Keeping both means two schedulers; deleting it means discarding
work that was verified three days ago.

**4. GitHub Actions `schedule` is not a promise.** Scheduled workflows are
delayed under load and **skipped silently** on inactive repositories. Trading a
local runner that wedges loudly for a scheduler that skips quietly is not
obviously a win — it is the same failure class this pipeline keeps hitting: an
absence that reads as "nothing to report".

**5. A hosted model changes the review load, in both directions.** The local
model's failure mode is documented and consistent: confident vagueness and
mangled proper nouns ("Terminal-Bench-Science 0.1" → "Benchmark de Ciência do
Terminal 0,1"), which is why every digest ships `draft: true` and the first
edition needed 5 rewrites and 1 removal out of 8. A stronger model likely lowers
that rate — and lowering it is exactly what erodes the habit of checking, which
is the only thing standing between a hallucinated line and the published blog.

## Options

| | A — stay local | B — Actions + paid API | C — Actions + local-quality model, keep drafts |
|---|---|---|---|
| machine dependency | yes | **removed** | removed |
| CONTRACT invariant 5 | holds | **amended** | amended |
| publishing path | human commits | **PR from a bot** | PR from a bot |
| `run-digest.sh` | stays | dies | dies |
| silent-skip risk | none (cron is local) | **yes** | yes |
| cost | zero | per-call | per-call |

Pricing is deliberately **not** quoted here — it is a live number owned by the
provider, and a price in prose rots. Read it from the provider's current page
when the decision is taken; 16 calls/week of ~700-character prompts is the
volume to price.

## Recommendation

**Not urgent, and not obviously right.** The failure this would fix has been
observed **once**, was transient, and is now detected and reported by two
mechanisms shipped since. The change costs a contract amendment, a new
bot-authored PR path, the deletion of a verified wrapper, and it swaps a loud
failure for a quiet one.

The cheap thing to do first is **wait for evidence**: the cron has not yet fired
on its own schedule even once. One real Monday run says more about whether this
is a problem than any amount of reasoning here.

If it is taken up anyway, **C over B** — the argument for moving is the machine
dependency, not summary quality, and keeping quality roughly where it is
preserves the review habit that `draft: true` exists to enforce.

## Decision

**Open.** Revisit after the first three scheduled Monday runs, with
`scripts/news/digest.log` as the evidence: count `RESULT=ok` against
`RESULT=timeout` and `RESULT=BROKEN`.

```bash
grep -c 'RESULT=ok' scripts/news/digest.log
grep -cE 'RESULT=(timeout|BROKEN)' scripts/news/digest.log
# CONTROL: a log with no RESULT= line at all means the job never finished,
# which is a THIRD state and not a zero in either column above.
grep -c 'RESULT=' scripts/news/digest.log
```
