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

This targets the one failure actually observed in production —
`Terminal-Bench-Science 0.1` became `Benchmark de Ciência do Terminal 0,1` in the
PT draft. Run it on the EN summary against the source, **and on the PT summary
against source + EN**: a translated proper noun appears in neither, which is
exactly what makes it catchable.

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

Cheap, and it is the prerequisite for everything below.

### 3. Everything else waits

Specifically on the open ADR-001 follow-up: **does the summarization step earn
its place at all?** Building a faithfulness judge for prose that may be deleted
is optimizing a step that might not survive. `--no-llm` already exists to test it
— it falls back to the raw feed excerpt (`fetch-news.mjs`, after the `useLlm`
block), so one edition run that way answers whether a bare shortlist is harder to
review.

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
