# Evaluating the digest's LLM step — what to build, and what not to

Research pass 2026-09-04. Four parallel angles, every recommendation carrying a
URL that was actually fetched, then spot-checked here with a negative control.

**Read the rejections first.** Most of what a search returns for "LLM evals" does
not apply to a pipeline this small, and the expensive mistake is adopting it.

## The measurement that reframes everything

The first edition survives in git as a labelled pair: the model's own output at
`d44b785` (`draft: true`), the published post at `e8d6510` (`draft: false`).

| | EN | PT |
|---|---:|---:|
| items the model produced | 8 | 8 |
| URLs the human kept | **7** | 7 |
| **model sentences surviving verbatim** | **0 of 7** | **0 of 7** |

Selection works and uses **no LLM** — keyword scoring in `score()`, before
`summarizeEn` is ever called. The summarization step contributed zero published
prose. See ADR-001 for what that means for hosting, and for the open question of
whether the step earns its place at all.

🔴 **This kills the "free labels" plan, and two independent research passes
proposed it.** Both said: you rewrite ~5 of 8 every week, so `rewritten` vs
`kept` is a free human label — 100 pairs in 13 weeks, no labelling work. It does
not work here. The real rate is **7 of 7 rewritten**, which is a *constant
column*: every item has the same label, so agreement, precision and Cohen's κ are
all undefined. One of the two passes shipped the very control that catches it:

```python
assert len(set(h)) == 2, "CONTROL: a constant column makes kappa meaningless"
```

The label that would carry signal is not "was it rewritten" — the human rewrites
for depth and framing, not only for errors. It is **per-item and per-failure**:
did *this* summary mangle an entity, invent a number, say nothing specific.

## What to build, in order

### 1. Entity and number preservation — deterministic, zero dependencies

Every proper noun and every numeric literal in a summary must appear verbatim in
the source excerpt. No model, no eval set, no labels: it is decidable from the
source alone.

> **BUILT 2026-09-04** — `scripts/news/check-entities.mjs`, 26 assertions in
> `check-entities.test.sh`, 4 mutations with disjoint failure sets in
> `check-entities.mutate.sh`. Invoked by the pipeline at draft time as advisory
> `ENTITY_CHECK` log lines, and runnable over any edition record.

🔴 **RETRACTION — the failure this item was written for did not happen.** This
section claimed `Terminal-Bench-Science 0.1` became `Benchmark de Ciência do
Terminal 0,1` in the PT draft. Measured against that draft in git on 2026-09-04
(`d44b785:src/content/blog/2026-09-02-radar-ai-dev-pt.mdx`, line 16):

```
O Claude Fable 5.1 alcançou um desempenho de 52,6% no Terminal-Bench-Science 0,1, …
```

The identifier survived **intact**. Only the decimal separator changed, and a
decimal comma is correct pt-BR, not a defect. **Edition 1 has zero entity
manglings.** Same defect class as the "5 of 8" corrected in ADR-001: a claim in
prose that nothing re-measured — and this one had already propagated into the
module docstring and a test-arm label before the data was read.

The check is still worth its ~200 lines: it is deterministic, needs no model and
no labels, and runs in milliseconds. But it is **prophylactic, not remedial**, and
saying otherwise inflates what it has earned.

**How it is actually wired.** Three directions, not two:

| lane | question | what only it can answer |
|---|---|---|
| EN → source | is what the EN line asserts grounded? | invention |
| PT → source + EN | is what the PT line asserts grounded? | invention in translation |
| **EN → PT** | did the EN line's identifiers and numbers survive? | **deletion** |

🔴 The third lane is not in the original item, and it is the only one that could
catch the failure shape described above. A summary→source check sees INVENTION
only: it asks whether what the summary says is grounded, never whether what the
source said survived. With only the two grounding lanes, a translated identifier
reads `no-tokens` on the PT side — nothing checkable, silently not a pass.

**And production data broke the first version.** Run over the real edition-1
drafts, the EN→PT lane flagged **2 of 8** items, and both were `AI` rendered as
`IA` — the standard pt-BR form. A 25% false positive rate against a fixture suite
that read 23/0. Fixed with an explicit `TRANSLATION_EQUIVALENTS` map whose only
entry is the one that was measured; after it, edition 1 reports 0 findings across
19 checked tokens (non-zero, so not a vacuous pass).

> A fixture suite cannot tell you a false positive rate. It only ever tells you
> that the cases you imagined behave as you imagined. Run a new check over real
> historical data before believing its verdict on new data.

🔴 **And a one-way fix reads as done.** The `ai → ia` entry was added for the
EN→PT lane. The **first full live run with the model** then flagged `IA` on the
**PT→source** lane: the PT line says IA, the source says AI, and the map only
looked one way. Same root cause, opposite direction, fixed for a whole session
without being fixed. The map is bidirectional now, and `M9` mutates it back to
one-way to keep it that way.

Live runs since (8 items each, real model output, not fixtures):

| run | findings | tokens checked |
|---|---:|---:|
| before the bidirectional fix | 1 — a false positive | 69 |
| after | **0** | **78** |

The token count is the control: zero findings out of a growing non-zero token
count is a pass, zero out of zero is a `tautological` or `no-tokens` run.

🔴 **The mutation harness itself was lying, in the direction that matters.** It
tested for green with `grep -qF "0 failed"`, and `"10 failed"` contains that
substring — so a mutation that killed **ten** assertions was reported as
SURVIVED. Applied by hand the same mutation turned the suite red immediately. An
under-reporting harness sends you to add assertions that already exist, or to
weaken code you believe is untested. All three harnesses now use
`grep -qE "(^|[^0-9])0 failed"`.

Origin of the metric is precision-source from Nan et al., EACL 2021
(https://aclanthology.org/2021.eacl-main.235/) — cited as provenance, not as
tooling; the implementation is a regex.

🔴 The PT-side check has **no citation behind it**. The grounded-factuality
literature is monolingual English; no metric found targets translation-induced
entity mangling. It is our construction, and it is also the cheapest thing here.

### 2. Persist the draft→published pair per edition

Today edition 1 is recoverable only because its draft happened to be committed
before review, and only by git archaeology. Nothing captures the pair on purpose.
Without it, no eval set can ever accumulate — and the per-failure labels above
have nowhere to live.

> **BUILT 2026-09-04.** `fetch-news.mjs` writes `scripts/news/editions/<date>.json`
> whenever a draft actually reaches disk — the draft half, carrying the exact
> 700-char prompt excerpt the model was shown, so the ground is what it saw and
> not more. `capture-published.mjs` fills the published half after review.
> 15 assertions, 3 disjoint mutations.

Two controls in that pair are the whole value of it:

- **It refuses to run while either post still says `draft: true`** (exit 1, not 0).
  Capturing a draft as the published line would record the model's own output as
  the human's, and every later measurement would be the model graded against
  itself.
- **A parse that matches zero links is exit 2, a broken instrument.** "The human
  cut all 8 items" and "the post body shape changed" produce identical output
  otherwise, and the comfortable reading is the wrong one.

Each item carries `keptByHuman`, and the record carries `survivedVerbatimEn` —
the number ADR-001 turned on, recomputed per edition instead of remembered.

### 3. Does the summarization step earn its place? — measured 2026-09-04

The ADR-001 follow-up, run rather than argued. A full `--no-llm` edition was
generated against the live feeds (8 items, scratch dirs, production `seen.json`
untouched) and compared with edition 1's LLM draft and its published version.

| | items | median chars | ends mid-word |
|---|---:|---:|---:|
| `--no-llm`, **byte-220 fallback** (as it shipped until today) | 8 | 221 | **8 of 8** |
| `--no-llm`, **boundary fallback** (`excerpt.mjs`, built today) | 8 | 211 | **0 of 8** |
| LLM draft (edition 1) | 8 | 212 | 0 |
| published (human) | 7 | 366 | 0 |

**The first row was measuring the fallback, not the absence of a model** — and it
was about to be read as evidence for keeping the LLM step. Every line was exactly
221 characters because the fallback was `slice(0, 220) + '…'`; all eight ended
mid-word for a reason that has nothing to do with summarization.

`trimToBoundary` cuts at a sentence end when one falls past half the budget, and
otherwise at a word boundary with the ellipsis kept. Same eight items, re-run:

```
BEFORE  …ncement spends a notable amount of time on sc…
        …ks. In our internal testing, GPT-6… The post …
        … Engine (GKE). To handle massive 15K+ token c…
AFTER   …work, and long-running problem-solving tasks".
        …-horizon, autonomous coding and agentic tasks.
        …ipelines using Google Kubernetes Engine (GKE).
```

Six of eight now end on a full stop; the other two end on a whole word plus the
marker. **The gap the first table showed was ours, and it cost 40 lines to close.**

So the state of the question, honestly: the summarization step contributes **zero
published prose**, and against a competent fallback its remaining advantage is
that it strips feed boilerplate ("The post …", "Today is … day .") and compresses
rather than truncating. That is a real but small edge, and it is now measurable
against a fair opponent instead of a straw man we built ourselves.

> The general shape, and it is the reason this row is kept rather than replaced:
> **before comparing A against B, check that B is the best version of B.** A
> comparison against a weak alternative is not a measurement of A; it is a
> measurement of how little effort went into B.

🔴 **Ollama was wedged during this session** and stayed wedged: `/api/tags`
answered instantly while `/api/generate` returned nothing in 140 s. That is the
exact state `ollamaAlive()` exists to catch, and it is why the LLM side of the
table comes from edition 1 rather than from a same-week run. A catalogue that
answers is not generation that works.

### 4. Everything else waits

Building a faithfulness judge for prose that may be deleted is optimizing a step
that might not survive. Item 3 above is the decision that gates it.

## Researched and rejected

| | why not |
|---|---|
| **`bespoke-minicheck` 7B** as a faithfulness judge | Genuinely SOTA for this shape — 77.4% balanced accuracy on LLM-AggreFact, above Claude-3.5-Sonnet at 77.2 (https://llm-aggrefact.github.io/). But 4.7 GB, and `bespokelabs/Bespoke-MiniCheck-7B` exposes **no licence tag** on the HF API. Premature while step 3 is open. Licence-clean fallback if we ever want it: `lytang/MiniCheck-Flan-T5-Large`, MIT, 0.77B, −2.4 points. |
| **HHEM-2.1-Open** (Vectara) | Apache-2.0, CPU-fast, a genuinely independent second opinion. But it is **Python in a Node/Bun repo** — a second toolchain in `scripts/news/` for one check. |
| **promptfoo** (0.122.2, MIT, 2026-08-28) | Real, maintained, Ollama is a first-class provider. Its value is the *matrix* — many prompts × many models — and a web UI. With one local model and a dozen cases it is dependency without leverage. Revisit the day we compare two prompts side by side. 🔴 Config trap if we ever do: `llm-rubric` silently defaults to an **OpenAI** grader; override `defaultTest.options.provider`. |
| **AlignScore** | Stale. Last push 2024-03-11 and that commit is a README edit; pinned to PyTorch 1.12.1. Superseded by MiniCheck on the same benchmark. |
| **QAFactEval** | Effectively dead — last code commit 2022-11-13. Also wrong shape: QA-generation over a 25-word sentence yields almost no questions. |
| **FActScore** | Not dead, wrong tool. It decomposes long biographies into atomic facts; a 25-word line has 1-3. |
| **G-Eval, or any 1-5 quality score** | Likert scales are what current guidance tells you to avoid: *"arbitrary numeric scales, such as 1-10, rarely work well"* (https://www.evidentlyai.com/blog/how-to-align-llm-judge-with-human-labels). Binary, one criterion per judge. |
| **`llama3.2:3b` judging its own output** | Self-preference bias is measured (https://arxiv.org/pdf/2410.21819). Never let the generator grade itself. |
| **A 1000-example eval set** | Correct statistics, wrong project: at 8 items/week that is 2.4 years. Named so it is a rejected option, not an unexamined gap. |
| **ROUGE/BLEU against the human rewrite** | A valid rewrite of a 25-word sentence shares almost no n-grams with the draft. Use rewrites as failure exemplars, never as a similarity target. |

## Two traps worth carrying

🔴 **"LLM judges agree with humans 80-85%, better than human-human" is inflated.**
Those are exact-match figures. Cohen's κ deflates them by **33-41 percentage
points** across 21 judges from 9 providers
(https://arxiv.org/abs/2606.19544, 2026-06-17). Quoting the 85% is the most
common error in this space.

🔴 **Agreement is the trap metric.** If a failure happens 10% of the time, a
judge that always answers "pass" scores 90% accuracy. Report TPR/TNR or κ, never
bare accuracy — and assert that neither column is constant, which is exactly the
check our own data failed above.

## If we ever do build a judge

Statistical honesty at our volume, stated plainly: at 8 items/week we will
**never** have a set large enough to certify a small improvement. Three failures
in 24 gives a Wilson 95% interval of roughly [0.04, 0.31] — it tells you almost
nothing. Use a set for **saturation and regression catching** ("did a known-bad
case come back?"), which is categorical, not for proportion tests. Report a
Wilson interval beside any rate, never a bare percentage.

## Where the research came up empty

Stated rather than filled with filler:

- **No eval-set-size guidance exists for the ~25-word summary regime.** Every
  number found (246, 1000, "dozens to ~100") is generic LLM-eval advice.
- **No metric targets translation-induced entity mangling.** The literature is
  monolingual English. Our PT-side check is uncited by necessity.
- **No clean standard for running a local-model eval in CI.** The honest answer
  is not to: run it in the same weekly script that generates drafts, or have CI
  assert on *recorded* outputs with no model call. The promptfoo GitHub Action
  documents `openai-api-key` as its input, which confirms the gap rather than
  closing it.
- **The LLM-AggreFact leaderboard shows no update date** and its newest listed
  model is Claude-3.5-Sonnet, so the standings may be 2024-vintage. The MiniCheck
  repo is demonstrably alive; the leaderboard may not be.

## Verifying this document

Every URL above returned 200 when this was written, checked with a negative
control in the same run — without one, a captive network returning 200 to
everything would look like full verification.

```bash
for u in <the urls above>; do
  printf '%s %s\n' "$(curl -sSL -o /dev/null -m 25 -w '%{http_code}' "$u")" "$u"
done
# CONTROL: a URL that must NOT be 200
curl -sSL -o /dev/null -m 20 -w '%{http_code}\n' https://arxiv.org/abs/2606.99999
```
