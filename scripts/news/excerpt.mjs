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
