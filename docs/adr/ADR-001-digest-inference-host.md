# ADR-001 — Where the weekly digest runs its inference

- **Status:** **Accepted — stay on local Ollama (option A).** Decided by the
  operator 2026-09-04, the same day this was raised.
- **Date:** 2026-09-04 (proposed and accepted)
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
edition is measured in "What the model actually contributed" below: **zero** of
its sentences reached the published post. A stronger model would raise that, and
raising it is what erodes the habit of checking — the only thing standing between
a hallucinated line and the published blog.

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

## What the model actually contributed (measured 2026-09-04, n=1)

Raised after this ADR was first written, and it changes the reasoning rather than
a number. The first edition survives in git as a labelled pair — the model's own
output at `d44b785` (`draft: true`) and the published post at `e8d6510`
(`draft: false`) — so the question is recomputable instead of remembered.

| | EN | PT |
|---|---:|---:|
| items the model produced | 8 | 8 |
| **URLs the human kept** | **7** | 7 |
| **model sentences surviving verbatim** | **0 of 7** | **0 of 7** |

The prose in three docs said "5 rewrites and 1 removal out of 8". The real figure
is 7 of 7 rewritten plus 1 item dropped. Corrected everywhere; recompute below
rather than citing these numbers.

**What this reframes.** Selection is what works, and selection uses **no LLM at
all** — it is keyword scoring in `score()`, applied before `summarizeEn` is ever
called. The LLM runs only after the shortlist exists, and 100% of that output was
discarded. So paying a hosted API to write better summaries would be buying
quality in the step whose output is thrown away, while the step that earns its
keep is deterministic and free.

🔴 **What this does NOT establish.** n=1, one edition. And "no sentence shipped"
is not "the step is worthless": a one-line summary may still earn its place as a
*reading aid* that lets a human triage 8 items quickly, even when none of the
text survives. That is a separate question from where inference runs, and it is
recorded as open in "Follow-up" below rather than settled here by implication.

```bash
# recompute against any edition: the model's draft vs what was published
git log --oneline --follow -- src/content/blog/<edition>.mdx
git show <draft-sha>:src/content/blog/<edition>.mdx > /tmp/d.mdx
git show <final-sha>:src/content/blog/<edition>.mdx > /tmp/f.mdx
# CONTROL: the parser must find items in BOTH, or "0 survivors" is just a blind
# parser reporting nothing rather than a measurement of what changed.
```

## Decision

**Accepted: stay on local Ollama.** Decided by the operator on 2026-09-04.

The measurement above is why this is not merely "wait and see". The case for
moving was to remove a machine dependency at the cost of a hosted summary; the
summaries are not what the digest ships. The wedge that motivated the question
was seen once, was transient, and is now reported by two mechanisms (`INSTRUMENT`
exit 2 on a wedged runner, `RESULT=timeout` from the wrapper).

Revisit if the operational evidence turns, with `scripts/news/digest.log`:

```bash
grep -c 'RESULT=ok' scripts/news/digest.log
grep -cE 'RESULT=(timeout|BROKEN)' scripts/news/digest.log
# CONTROL: a log with no RESULT= line at all means the job never finished,
# which is a THIRD state and not a zero in either column above.
grep -c 'RESULT=' scripts/news/digest.log
```

## Follow-up, deliberately left open

**Does the summarization step earn its place at all?** Measured contribution to
published prose is zero. It may still pay for itself as review scaffolding. The
honest test is to run one edition with summaries suppressed (`--no-llm` already
exists) and see whether reviewing a bare shortlist is harder. Recorded as a
question, not a plan — and explicitly NOT decided by this ADR.

```bash
grep -c 'RESULT=ok' scripts/news/digest.log
grep -cE 'RESULT=(timeout|BROKEN)' scripts/news/digest.log
# CONTROL: a log with no RESULT= line at all means the job never finished,
# which is a THIRD state and not a zero in either column above.
grep -c 'RESULT=' scripts/news/digest.log
```
