/**
 * Fallback excerpt trimming for the digest.
 *
 * A module of its own rather than an export from `fetch-news.mjs`: that file
 * runs its whole pipeline at import time — feeds and all — so importing it to
 * unit-test one function fetches 37 feeds as a side effect. Measured while
 * trying exactly that.
 */

/** Budget for a fallback line. */
export const EXCERPT_BUDGET = 220;

/**
 * A sentence end earlier than this fraction of the budget throws away too much
 * to be worth the tidiness, so those fall through to the word-boundary cut.
 */
export const SENTENCE_FLOOR = 0.5;

/**
 * ── Feed boilerplate ────────────────────────────────────────────────────────
 *
 * What a feed wraps around its own content and a reader of THIS page does not
 * need: the headline repeated (the digest already prints it, linked), the
 * publisher's footer, the newsletter's greeting.
 *
 * 🔴 Every rule here carries the frequency it was measured at, on a corpus of
 * 94 real excerpts pulled through the real pipeline on 2026-09-09. Recompute
 * before trusting any of them — the feeds change:
 *
 *   | rule                              | hits |
 *   |-----------------------------------|-----:|
 *   | headline repeated at the head     | 10/94|
 *   | `The post … appeared first on …`  |  5/94|
 *   | newsletter greeting               |  3/94|
 *
 * 🔴 `Today is … day .` is NOT implemented, and the reason is a cost, not an
 * absence. It occurs **1 in 94** — and the first count taken here said **0**,
 * from a predicate written as `Today is[^.]{0,60}day`. The one real instance is
 * `Today is Claude Fable (and Mythos) 5.1 day .`, whose version number carries a
 * dot, so the negated character class stopped before `day`. A zero from a blind
 * predicate reads exactly like a zero from a clean corpus, and this one was
 * about to be committed as a measured fact.
 *
 * With a dot-tolerant anchored predicate the rule works — and it also matches
 * `Today is a good day to ship, and the release notes are long.`, an ordinary
 * opening sentence. One excerpt gained against a demonstrated false positive on
 * plausible prose is a bad trade, so the rule stays out. Named, not omitted.
 */

/**
 * Drop the headline when the excerpt merely repeats it.
 *
 * 🔴 The discriminant is what comes AFTER the repeated headline, and a naive
 * prefix strip gets it wrong on real data. Measured cases:
 *
 *   "On the Navier–Stokes… Problem Impressive result from OpenAI…"  -> strip
 *   "Introducing ChatGPT Images 2.5 OpenAI's image models…"          -> strip
 *   "Introducing GeneBench-Pro, a new benchmark testing…"            -> KEEP
 *
 * In the third the headline IS the opening of a running sentence, and cutting
 * it leaves the line starting at ", a new benchmark…". So the strip fires only
 * when the next character begins a new sentence — a capital, a digit or a
 * quote — never when it is a comma or a lowercase continuation.
 */
export function stripRepeatedTitle(text, title) {
  const s = String(text ?? '');
  const t = String(title ?? '').trim();
  if (!t || t.length < 8) return s;                    // too short to be evidence
  const head = s.trimStart();
  if (head.slice(0, t.length).toLowerCase() !== t.toLowerCase()) return s;
  const rest = head.slice(t.length);
  const next = rest.replace(/^[\s.:—–-]+/u, '');
  if (!next) return s;                                  // the excerpt IS the title
  if (!/^[\p{Lu}\p{Nd}"'“]/u.test(next)) return s;      // running sentence: keep
  return next;
}

/**
 * The publisher footer WordPress appends, and the newsletter greeting.
 *
 * Both are anchored and length-capped. An unanchored `The post` would match the
 * phrase in ordinary prose, and this repo already carries the record of what an
 * over-broad strip costs: it fires on correct content, and nobody can tell from
 * the output that it did.
 */
export function stripFeedFurniture(text) {
  return String(text ?? '')
    // "The post <title> appeared first on <blog>." — measured 5/94, always trailing.
    .replace(/\s*\bThe post\b[\s\S]{0,200}?\bappeared first on\b[^.!?]{0,60}[.!?]?\s*$/iu, '')
    // "Hi everyone, Seb and Jan here 👋!" — measured 3/94, always the opening.
    // `here` is required: without it the pattern is just a greeting word and
    // would eat the first sentence of anything starting with "Hi".
    .replace(/^\s*(?:Hi|Hello|Hey)\b[^.!?]{0,60}\bhere\b[^.!?]{0,24}[.!?\\]*\s*/iu, '')
    .trim();
}

/** Both, in the order the shapes actually nest: furniture wraps the body. */
export function stripBoilerplate(text, title) {
  return stripRepeatedTitle(stripFeedFurniture(text), title);
}

/**
 * Cut an excerpt at a boundary a reader recognises, never mid-word.
 *
 * 🔴 Measured 2026-09-04: with a bare `slice(0, 220)`, ALL EIGHT lines of a
 * `--no-llm` edition ended mid-word. That figure was about to be read as
 * evidence for keeping the LLM summarization step (ADR-001's open follow-up)
 * when it was really evidence about the FALLBACK — the weakest possible version
 * of the no-LLM option. Deciding against it would have been deciding against a
 * straw man we built ourselves.
 *
 * A cut at a sentence end returns a complete sentence and NO ellipsis: the
 * heading above the line already links the source, so the marker buys nothing
 * and costs legibility. A cut at a word boundary keeps the ellipsis, because
 * there the line genuinely stops mid-thought and the reader should see it.
 */
export function trimToBoundary(text, max = EXCERPT_BUDGET) {
  const s = String(text ?? '');
  if (s.length <= max) return s;
  const head = s.slice(0, max);
  const sentence = Math.max(head.lastIndexOf('. '), head.lastIndexOf('! '), head.lastIndexOf('? '));
  if (sentence >= max * SENTENCE_FLOOR) return head.slice(0, sentence + 1).trim();
  const word = head.lastIndexOf(' ');
  const cut = word > 0 ? head.slice(0, word) : head;
  return cut.replace(/[\s,;:—–-]+$/u, '') + '…';
}
