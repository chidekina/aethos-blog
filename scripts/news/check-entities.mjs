#!/usr/bin/env node
/**
 * Entity and number preservation — DIGEST-EVAL.md item 1.
 *
 * Every distinctive proper noun and every numeric literal a summary asserts must
 * already be present in the material it was derived from. No model, no eval set,
 * no labels: it is decidable from the source alone.
 *
 *   node scripts/news/check-entities.mjs scripts/news/editions/2026-09-07.json
 *   node scripts/news/check-entities.mjs --json <edition.json>
 *
 * Exit codes follow fetch-news.mjs — 0 nothing missing · 1 real findings ·
 * 2 BROKEN INSTRUMENT (file unreadable, no items, a record with no source text).
 * 2 is never a verdict about the summaries. Do not chain with `&&`.
 *
 * ── What it deliberately does NOT flag ───────────────────────────────────────
 * A plain single capitalized word (`Google`, `Anthropic`) is reported as `weak`
 * and never changes the verdict. Requiring those would flag every clause-initial
 * word and every capitalized common noun, which is the "81 alerts, 0 real"
 * profile in the one list that should say what broke.
 *
 * 🔴 DIGEST-EVAL item 1 motivates this check with a production failure —
 * `Terminal-Bench-Science 0.1` supposedly becoming `Benchmark de Ciência do
 * Terminal 0,1` in the PT draft. Measured against the draft in git (`d44b785`,
 * line 16) on 2026-09-04: IT DID NOT HAPPEN. The PT draft carries
 * `Terminal-Bench-Science 0,1` — the identifier survived intact and only the
 * decimal separator changed, which is correct pt-BR. Edition 1 has ZERO entity
 * manglings. The check is still worth its ~200 lines because it is deterministic
 * and free to run, but no one should believe it is paying for an observed
 * failure. Same defect class as the "5 of 8" that an ADR reasoned from: a claim
 * in prose that nothing re-measured, and this one nearly became the motivating
 * example in the code that implements it.
 *
 * 🔴 Numbers are compared as DIGIT STRINGS with separators removed, so `0.1` and
 * `0,1` are the same number. That is on purpose: pt-BR writes a decimal comma,
 * and flagging it would be a false positive about correct behaviour. What the
 * PT check catches in that example is the NAME, not the separator.
 *
 * 🔴 A summary containing no strong token and no number yields `no-tokens`, not
 * `pass`. Zero findings from an extractor that found nothing to check is a blind
 * measurement, and it must not read as clean.
 */
import { readFileSync } from 'node:fs';

// ── extraction ───────────────────────────────────────────────────────────────

// Clause-initial capitals carry no evidence of being a name, so the first word
// after a sentence boundary is never promoted to `weak`. These are the words
// that survive that filter anyway and are still not names.
const WEAK_STOPWORDS = new Set([
  'a', 'an', 'the', 'i', 'it', 'its', 'this', 'that', 'these', 'those', 'and', 'but', 'or',
  'if', 'for', 'to', 'in', 'on', 'of', 'at', 'by', 'with', 'from', 'as', 'is', 'are', 'was',
  'were', 'be', 'been', 'new', 'now', 'one', 'two', 'both', 'no', 'not', 'you', 'your', 'we',
  'o', 'a', 'os', 'as', 'um', 'uma', 'e', 'ou', 'de', 'do', 'da', 'dos', 'das', 'em', 'no',
  'na', 'nos', 'nas', 'para', 'por', 'com', 'que', 'se', 'ao', 'aos', 'sem', 'sobre',
]);

/**
 * Unicode punctuation the model rewrites without changing meaning.
 *
 * 🔴 Measured 2026-09-09 on the first timer-produced edition. The source title
 * carries `Navier` U+2013 `Stokes` (en dash); the model's summary carries
 * `Navier` U+002D `Stokes` (ASCII hyphen). Byte comparison called that an
 * ungrounded invention. It is the opposite — normalising a typographic dash to
 * a hyphen is correct, and the identifier survived intact.
 *
 * Both sides go through this, never one: normalising only the summary would
 * leave the mirror-image false positive when the model emits the fancy dash and
 * the source has the plain one.
 *
 * Deliberately narrow. It maps dashes to `-`, curly quotes to straight, and
 * no-break space to space. It does NOT strip accents: `milhao` and `milhão`
 * are different words and folding them would hide a real translation defect.
 */
const punctNormalize = (s) => String(s ?? '')
  .replace(/[\u2010-\u2015\u2212\u00AD]/gu, '-')
  .replace(/[\u2018\u2019\u201B\u2032]/gu, "'")
  .replace(/[\u201C\u201D\u2033]/gu, '"')
  .replace(/\u00A0/gu, ' ');

const stripEdges = (w) =>
  w.replace(/^[^\p{L}\p{N}]+/u, '').replace(/[^\p{L}\p{N}%]+$/u, '').replace(/['’]s$/u, '');

/**
 * Classify one already-trimmed word.
 *   strong — must survive verbatim: an identifier, an acronym, a camel/Pascal
 *            name, or a hyphenated multi-capital name.
 *   weak   — a plain capitalized word; reported, never fatal.
 *   null   — ordinary word.
 */
export function classify(word, { clauseInitial = false } = {}) {
  if (!word) return null;
  const hasLetter = /\p{L}/u.test(word);
  const hasDigit = /\p{Nd}/u.test(word);
  if (!hasLetter) return null;                              // bare numbers go through the number scan
  if (hasDigit) return 'strong';                            // GPT-4, llama3.2, v2
  if (/^\p{Lu}{2,}$/u.test(word)) return 'strong';          // LLM, API, SOTA
  if (/\p{Ll}\p{Lu}/u.test(word)) return 'strong';          // TypeScript, MiniCheck
  const parts = word.split('-');
  if (parts.length >= 2 && parts.filter((p) => /^\p{Lu}/u.test(p)).length >= 2) return 'strong';
  if (/^\p{Lu}/u.test(word) && !clauseInitial && !WEAK_STOPWORDS.has(word.toLowerCase())) return 'weak';
  return null;
}

/**
 * Acronyms whose pt-BR form is a DIFFERENT string and whose translation is
 * correct, not a defect. Every entry is here because it was measured, never
 * because it was imagined — an allowlist grown by guessing is a place to hide
 * real failures.
 *
 * 🔴 Provenance: running the EN→PT lane over the real edition-1 drafts
 * (`d44b785`) flagged 2 of 8 items, and BOTH were `AI` rendered as `IA`. That is
 * the standard pt-BR form, so the check as first written had a 25% false
 * positive rate on production data while its fixture suite read 23/0. A gate
 * that fires on correct behaviour one time in four is the "81 alerts, 0 real"
 * profile, and it arrives looking like thoroughness.
 *
 * Recompute the rate before adding an entry — a fixture cannot tell you this:
 *   node --input-type=module -e "…checkTranslation over the drafts of an edition…"
 *   (the full command is in docs/DIGEST-EVAL.md § Entity check)
 */
const EQUIVALENT_PAIRS = [
  ['ai', 'ia'],   // measured twice: edition 1 (EN→PT lane) and the first live LLM run (PT→source lane)
];

/**
 * Bidirectional, because the same pair shows up in opposite directions and a
 * one-way map fixes exactly half the false positives.
 *
 * 🔴 Measured 2026-09-04 in that order, which is the point: `ai → ia` was added
 * for the EN→PT lane after edition 1 flagged 2 of 8 items. The first full live
 * run then flagged `IA` on the PT→source lane — the PT line says IA, the source
 * says AI, and the map only looked one way. Same root cause, opposite direction,
 * and the one-way version read as fixed for a whole session.
 */
const TRANSLATION_EQUIVALENTS = new Map();
for (const [a, b] of EQUIVALENT_PAIRS) {
  TRANSLATION_EQUIVALENTS.set(a, [...(TRANSLATION_EQUIVALENTS.get(a) ?? []), b]);
  TRANSLATION_EQUIVALENTS.set(b, [...(TRANSLATION_EQUIVALENTS.get(b) ?? []), a]);
}

/** Is `token` present in `haystackLower`, verbatim or as a measured equivalent? */
const groundedIn = (token, haystackLower) => {
  const lower = token.toLowerCase();
  if (haystackLower.includes(lower)) return true;
  return (TRANSLATION_EQUIVALENTS.get(lower) ?? []).some((alt) => haystackLower.includes(alt));
};

/** Digit string of a numeric literal, separators removed: `0.1` and `0,1` → `01`. */
const digitsOf = (n) => n.replace(/[.,\s]/g, '');

const NUMBER_RE = /\p{Nd}[\p{Nd}.,]*\p{Nd}|\p{Nd}/gu;

/**
 * ── The sequence half of the number check ───────────────────────────────────
 *
 * 🔴 The token scan below compares a SET. `$10/million input` becoming
 * `$10 million for input` is wrong by a factor of a million, and every token of
 * the claim is present in the source, so the set comparison reports
 * `0 findings across 73 tokens`. Measured, and documented in DIGEST-EVAL.md as
 * a false negative on the check's own motivating class.
 *
 * What actually changed is the RELATION between the number and its magnitude
 * word: `per million` collapsed to `million`. That is decidable without a model
 * and without guessing, so this scan asks exactly that and nothing more.
 *
 * Deliberately narrow, and the narrowness is the design:
 *
 *  - It fires ONLY when the same (number, magnitude) pair occurs on both sides
 *    with a DIFFERENT per-relation. A number the source never carries is the
 *    existing scan's job; a magnitude the source never carries is not evidence
 *    of a rearrangement.
 *  - It is symmetric. Inventing `per` is as wrong as dropping it, and a one-way
 *    version reads as fixed while half the class walks through — the exact
 *    shape the EN→PT equivalents map already got caught by once.
 *  - Numbers keep their separator-stripped comparison, so `1,000,000` and
 *    `1.000.000` are the same number across locales, per the note above.
 */
const MAGNITUDE_WORDS = new Set([
  'million', 'millions', 'billion', 'billions', 'trillion', 'trillions', 'thousand', 'thousands',
  'milhao', 'milhoes', 'bilhao', 'bilhoes', 'trilhao', 'trilhoes', 'mil',
  'token', 'tokens', 'request', 'requests', 'query', 'queries', 'user', 'users',
  'month', 'months', 'year', 'years', 'day', 'days', 'hour', 'hours', 'second', 'seconds',
  'word', 'words', 'call', 'calls', 'seat', 'seats',
]);

// `a`/`um` are excluded on purpose: "$10 a month" does mean per-month, but so
// does the article in ordinary prose, and a marker that fires on an article
// would flag correct sentences constantly.
const PER_WORDS = new Set(['per', 'each', 'every', 'por', 'cada']);

// Accents are folded HERE and nowhere else. This set is matched against, never
// reported, so folding cannot hide a defect — it only lets `milhão` and the
// unaccented spelling a model sometimes emits reach the same bucket.
const fold = (w) => w.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();

/**
 * Every `{ digits, magnitude, per }` triple the text asserts.
 * `per` is true when a `/` sits between the number and the magnitude word, or
 * when a per-word does.
 */
export function extractRelations(text) {
  const src = punctNormalize(text).replace(/[`*_]/g, ' ');
  const out = [];
  for (const m of src.matchAll(NUMBER_RE)) {
    const digits = digitsOf(m[0]);
    if (!digits) continue;
    const after = src.slice(m.index + m[0].length, m.index + m[0].length + 40);
    // `sep` is what sits between the number and the next word — a `/` here is
    // the whole difference between "$10 per million" and "$10 million".
    const mm = after.match(/^([^\p{L}\p{N}]*)(\p{L}[\p{L}\p{M}]*)(?:([^\p{L}\p{N}]*)(\p{L}[\p{L}\p{M}]*))?/u);
    if (!mm) continue;
    const [, sep1, w1, sep2 = '', w2 = ''] = mm;
    const slashBefore = (s) => /\//.test(s ?? '');
    if (MAGNITUDE_WORDS.has(fold(w1))) {
      out.push({ digits, magnitude: fold(w1), per: slashBefore(sep1) });
      continue;
    }
    if (PER_WORDS.has(fold(w1)) && w2 && MAGNITUDE_WORDS.has(fold(w2))) {
      out.push({ digits, magnitude: fold(w2), per: true });
      continue;
    }
    // `$10/M` and `$10/token` where the magnitude word is the one right after a
    // slash but is not in the list is intentionally NOT recorded: an unlisted
    // word is unknown, and inventing a relation from it would be the guessing
    // this check exists to avoid.
  }
  return out;
}

/**
 * Relations the summary asserts that contradict the ground on the per-marker.
 * Returns [] when there is nothing comparable — which the caller must not read
 * as a pass; see `relationsChecked` in the result.
 */
export function relationConflicts(summaryText, groundText) {
  const mine = extractRelations(summaryText);
  const theirs = extractRelations(groundText);
  const bad = [];
  for (const r of mine) {
    const sameSubject = theirs.filter((g) => g.digits === r.digits && g.magnitude === r.magnitude);
    if (sameSubject.length === 0) continue;              // not this check's question
    if (sameSubject.some((g) => g.per === r.per)) continue;
    bad.push(r.per
      ? `${r.digits} per ${r.magnitude} (source says ${r.digits} ${r.magnitude})`
      : `${r.digits} ${r.magnitude} (source says ${r.digits} per ${r.magnitude})`);
  }
  return { conflicts: bad, comparable: mine.length };
}

export function extractTokens(text) {
  const src = punctNormalize(text).replace(/[`*_]/g, ' ');
  const strong = new Set();
  const weak = new Set();

  // A clause boundary is a sentence end or a newline; the word right after it is
  // capitalized by grammar, not by being a name.
  for (const clause of src.split(/(?:[.!?;:]\s+|\n+)/)) {
    const words = clause.trim().split(/\s+/).filter(Boolean);
    words.forEach((raw, i) => {
      const w = stripEdges(raw);
      const kind = classify(w, { clauseInitial: i === 0 });
      if (kind === 'strong') strong.add(w);
      else if (kind === 'weak') weak.add(w);
    });
  }

  const numbers = new Set();
  for (const m of src.matchAll(NUMBER_RE)) {
    const d = digitsOf(m[0]);
    if (d) numbers.add(d);
  }

  return { strong: [...strong], weak: [...weak], numbers: [...numbers] };
}

// ── grounding ────────────────────────────────────────────────────────────────

/**
 * @param summary  the sentence to check
 * @param grounds  every text the summary is allowed to draw from (source excerpt,
 *                 headline, and for the PT line also the EN line it came from)
 */
export function checkSummary({ summary, grounds }) {
  const text = String(summary ?? '').trim();
  const pool = (grounds ?? []).map((g) => String(g ?? '').trim()).filter(Boolean);

  if (!text) return { status: 'broken', reason: 'empty summary', missing: emptyMissing(), checked: 0 };
  if (pool.length === 0) {
    return { status: 'broken', reason: 'no ground text to check against', missing: emptyMissing(), checked: 0 };
  }

  const hay = punctNormalize(pool.join('\n')).replace(/[`*_]/g, ' ');
  const hayLower = hay.toLowerCase();
  const hayNumbers = new Set([...hay.matchAll(NUMBER_RE)].map((m) => digitsOf(m[0])));

  // 🔴 If the summary IS the source — which is exactly what --no-llm produces,
  // since the fallback is a slice of the excerpt — then every token is grounded
  // by construction. That is a TAUTOLOGY, not a measurement, and it reports a
  // reassuring non-zero `checked` while having no power to fail. Measured
  // 2026-09-04: a --no-llm run logged "0 ungrounded findings, 42 tokens checked"
  // and not one of those 42 could ever have been missing.
  const norm = (x) => x.toLowerCase().replace(/[\s…]+/g, ' ').trim();
  // 🔴 BOTH sides, and the asymmetry is not hypothetical: `hay` is punctuation-
  // normalised and markdown-stripped above, and comparing it against a RAW
  // summary let 14 of 94 items escape the tautology guard on a --no-llm corpus
  // — measured 2026-09-09, the same day the normaliser was added. Under
  // --no-llm the summary IS a slice of its excerpt, so every one of those 14
  // was a false `pass`, and 15 escapees were enough to suppress the run-level
  // VACUOUS warning for the other 79. A guard that normalises one side is worse
  // than one that normalises neither: it fails only on the texts that have the
  // punctuation, which is the subset nobody has a fixture for.
  const textCmp = punctNormalize(text).replace(/[`*_]/g, ' ');
  if (norm(hay).includes(norm(textCmp)) && norm(textCmp).length > 0) {
    return { status: 'tautological', reason: 'the summary is a substring of its own source', checked: 0, missing: emptyMissing() };
  }

  const tok = extractTokens(text);
  const rel = relationConflicts(text, hay);
  const missing = {
    strong: tok.strong.filter((tokenText) => !groundedIn(tokenText, hayLower)),
    weak: tok.weak.filter((tokenText) => !groundedIn(tokenText, hayLower)),
    numbers: tok.numbers.filter((n) => !hayNumbers.has(n)),
    // Rearranged, not missing. A set comparison cannot see these by construction.
    relations: rel.conflicts,
  };

  const checked = tok.strong.length + tok.numbers.length;
  // Zero findings out of zero checkable tokens is not a pass — it is a blind run.
  // A summary with no strong token and no number but a contradicted relation is
  // still a FAIL: `no-tokens` describes nothing to check, and here there was.
  const status = (missing.strong.length + missing.numbers.length + missing.relations.length > 0)
    ? 'fail'
    : (checked === 0 ? 'no-tokens' : 'pass');

  return { status, checked, relationsChecked: rel.comparable, tokens: tok, missing };
}

const emptyMissing = () => ({ strong: [], weak: [], numbers: [], relations: [] });

/**
 * Translation preservation, EN → PT. Every STRONG token and every number the EN
 * line asserts must still be there in the PT line.
 *
 * 🔴 This direction is not in DIGEST-EVAL item 1, and it is the only one that
 * could catch the failure shape item 1 describes. A translated identifier is a
 * DELETION from the PT line, and a summary→source check only ever sees
 * INVENTION: it asks whether what the summary says is grounded, never whether
 * what the source said survived. Run with only the two grounding checks, that
 * shape reads `no-tokens` on the PT side — nothing checkable, silently not a
 * pass. The suite's ARM 3 is a CONSTRUCTED case of it, not a recorded one; see
 * the note above on why the recorded one turned out not to exist.
 *
 * Safe against false positives because the translation prompt already instructs
 * the model to keep technical terms in English; a strong token is precisely an
 * identifier, acronym or multi-capital name, never a translatable common word.
 */
export function checkTranslation({ summaryEn, summaryPt }) {
  const en = String(summaryEn ?? '').trim();
  const pt = String(summaryPt ?? '').trim();
  if (!en || !pt) return { status: 'broken', reason: 'one side is empty', missing: emptyMissing(), checked: 0 };
  // A PT line that is byte-identical to EN is the documented fallback path in
  // fetch-news.mjs, not a translation. Nothing was lost, and nothing was done.
  if (en === pt) return { status: 'not-translated', checked: 0, missing: emptyMissing() };

  const tok = extractTokens(en);
  const ptNorm = punctNormalize(pt);
  const ptLower = ptNorm.toLowerCase();
  const ptNumbers = new Set([...ptNorm.matchAll(NUMBER_RE)].map((m) => digitsOf(m[0])));

  // A token counts as preserved if the PT line carries it verbatim OR carries a
  // measured pt-BR equivalent of it.
  // EN -> PT, so the EN line is the ground and the PT line is the claim.
  const rel = relationConflicts(pt, en);
  const missing = {
    strong: tok.strong.filter((tokenText) => !groundedIn(tokenText, ptLower)),
    weak: [],
    numbers: tok.numbers.filter((n) => !ptNumbers.has(n)),
    relations: rel.conflicts,
  };
  const checked = tok.strong.length + tok.numbers.length;
  const status = (missing.strong.length + missing.numbers.length + missing.relations.length > 0)
    ? 'fail'
    : (checked === 0 ? 'no-tokens' : 'pass');
  return { status, checked, relationsChecked: rel.comparable, missing };
}

/**
 * Check one edition item on all three directions.
 * EN is grounded in the source excerpt and headline. PT is grounded in those
 * PLUS the EN line it came from. Then EN → PT preservation, above.
 */
export function checkItem(item) {
  // `null` is DECLARED absence, `undefined` is a malformed record, and they must
  // not collapse. A backfilled edition (one reconstructed from git, before the
  // record writer existed) has no recoverable source excerpt: the feeds moved on,
  // and inventing one would let the grounding lanes deliver a confident verdict
  // about text the model never saw. That is a lane not applicable, not a broken
  // instrument — and reporting it as broken would make the historical record
  // scream exit 2 forever, which trains the operator to stop reading the output.
  // Three states, not two. An ABSENT key silently degrades the ground to the
  // headline alone — measured 2026-09-04: a record missing sourceExcerpt reported
  // `fail` on a faithful summary, because the identifier was in the excerpt the
  // record no longer carried. A confident verdict from a degraded ground is worse
  // than no verdict, so a malformed record is `broken` and never scored.
  if (item.sourceExcerpt === undefined) {
    const mal = { status: 'broken', reason: 'record carries no sourceExcerpt key — use null to declare it absent', checked: 0, missing: emptyMissing() };
    return { link: item.link, title: item.title, en: mal, pt: mal, translation: mal };
  }
  if (item.sourceExcerpt === null) {
    const na = { status: 'no-ground', reason: 'sourceExcerpt declared null (backfilled edition)', checked: 0, missing: emptyMissing() };
    return {
      link: item.link,
      title: item.title,
      en: na,
      pt: na,
      translation: checkTranslation({ summaryEn: item.summaryEn, summaryPt: item.summaryPt }),
    };
  }
  const base = [item.sourceExcerpt, item.title];
  return {
    link: item.link,
    title: item.title,
    en: checkSummary({ summary: item.summaryEn, grounds: base }),
    pt: checkSummary({ summary: item.summaryPt, grounds: [...base, item.summaryEn] }),
    translation: checkTranslation({ summaryEn: item.summaryEn, summaryPt: item.summaryPt }),
  };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

const isMain = process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const argv = process.argv.slice(2);
  const KNOWN = new Set(['--json']);
  const asJson = argv.includes('--json');
  const bad = argv.filter((a) => a.startsWith('-') && !KNOWN.has(a));
  const paths = argv.filter((a) => !a.startsWith('-'));

  const die = (msg) => { console.error(`[entities] ${msg}`); process.exit(2); };

  if (bad.length) die(`INSTRUMENT: unknown argument(s) ${bad.join(' ')} — known flags are ${[...KNOWN].join(' ')}`);
  if (paths.length !== 1) die('INSTRUMENT: expected exactly one edition record path');

  let record;
  try { record = JSON.parse(readFileSync(paths[0], 'utf8')); }
  catch (err) { die(`INSTRUMENT: cannot read ${paths[0]} — ${err.message}`); }

  const items = record?.items;
  if (!Array.isArray(items) || items.length === 0) die(`INSTRUMENT: ${paths[0]} carries no items`);

  const results = items.map(checkItem);
  const LANES = ['en', 'pt', 'translation'];
  const anyIs = (r, s) => LANES.some((l) => r[l].status === s);
  const broken = results.filter((r) => anyIs(r, 'broken'));
  const failed = results.filter((r) => anyIs(r, 'fail'));
  const blind = results.filter((r) => LANES.every((l) => ['no-tokens', 'not-translated', 'no-ground', 'tautological'].includes(r[l].status)));

  if (asJson) {
    console.log(JSON.stringify({ edition: record.dateIso ?? null, results }, null, 2));
  } else {
    // One line, not one per item per lane. A backfilled record has the same
    // declared-absent grounds on every item, so printing it 2N times buries the
    // one lane that CAN run — the "81 alerts, 0 real" shape at small scale.
    const noGround = results.filter((r) => r.en.status === 'no-ground').length;
    if (noGround > 0) {
      console.log(`NO-GROUND  ${noGround} of ${results.length} items declare sourceExcerpt: null — the two grounding lanes cannot run on them. ` +
                  `Not a pass and not a fault; a backfilled edition has no recoverable source text. The EN→PT lane below still applies.`);
    }
    for (const r of results) {
      for (const lang of LANES) {
        if (r[lang].status === 'no-ground') continue;   // summarised above
        const c = r[lang];
        const m = [...c.missing.strong, ...c.missing.numbers];
        const rels = c.missing.relations ?? [];
        const verb = lang === 'translation' ? 'dropped in PT' : 'ungrounded';
        if (c.status === 'fail') {
          if (m.length) console.log(`FAIL ${lang.toUpperCase()}  ${r.title}\n     ${verb}: ${m.join(', ')}`);
          // Named apart from the missing-token list on purpose: nothing is
          // absent here, so "ungrounded" would send the reviewer looking for a
          // word that is present. The defect is the relation, not the token.
          if (rels.length) console.log(`FAIL ${lang.toUpperCase()}  ${r.title}\n     REARRANGED (present but says something else): ${rels.join('; ')}`);
        }
        else if (c.status === 'broken') console.log(`BROKEN ${lang.toUpperCase()}  ${r.title} — ${c.reason}`);
        else if (c.status === 'no-tokens') console.log(`NO-TOKENS ${lang.toUpperCase()}  ${r.title} — nothing checkable, this is not a pass`);
        else if (c.status === 'tautological') console.log(`TAUTOLOGICAL ${lang.toUpperCase()}  ${r.title} — ${c.reason}; this lane had no power to fail`);
        else if (c.status === 'no-ground') console.log(`NO-GROUND ${lang.toUpperCase()}  ${r.title} — ${c.reason}; this lane cannot run, which is not a pass either`);
        if (c.missing.weak.length) console.log(`     note ${lang}: ungrounded plain capitals (informational): ${c.missing.weak.join(', ')}`);
      }
    }
    console.log(`[entities] ${items.length} items · ${failed.length} with ungrounded tokens · ${blind.length} with nothing checkable · ${broken.length} unusable records`);
  }

  if (broken.length) process.exit(2);
  process.exit(failed.length > 0 ? 1 : 0);
}
