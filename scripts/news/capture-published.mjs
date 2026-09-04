#!/usr/bin/env node
/**
 * Capture the PUBLISHED half of an edition pair — DIGEST-EVAL item 2.
 *
 * The draft half is written by fetch-news.mjs at generation time. This fills in
 * what the human actually shipped, so the pair can accumulate into an eval set
 * instead of being recoverable only by git archaeology.
 *
 *   node scripts/news/capture-published.mjs scripts/news/editions/2026-09-07.json
 *
 * Run it AFTER flipping `draft: false` on both posts. Exit codes follow the rest
 * of the pipeline — 0 captured · 1 nothing to capture (still a draft) · 2 BROKEN
 * INSTRUMENT (record unreadable, posts missing, no item matched).
 *
 * 🔴 It REFUSES to run while either post still carries `draft: true`. Capturing a
 * draft as the published line would fabricate a pair that reads as a human
 * decision and is really the model's own output — and every later measurement
 * built on it would be measuring the model against itself. That refusal is exit
 * 1, not 0: "not published yet" is a real state, not a successful capture.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const POSTS_DIR = process.env.NEWS_POSTS_DIR ?? join(ROOT, 'src/content/blog');

const log = (...a) => console.log('[capture]', ...a);
const die = (msg) => { console.error(`[capture] ${msg}`); process.exit(2); };

const argv = process.argv.slice(2);
const bad = argv.filter((a) => a.startsWith('-'));
if (bad.length) die(`INSTRUMENT: unknown argument(s) ${bad.join(' ')} — this takes one edition record path and no flags`);
if (argv.length !== 1) die('INSTRUMENT: expected exactly one edition record path');

let record;
try { record = JSON.parse(readFileSync(argv[0], 'utf8')); }
catch (err) { die(`INSTRUMENT: cannot read ${argv[0]} — ${err.message}`); }
if (!record?.dateIso) die(`INSTRUMENT: ${argv[0]} carries no dateIso`);
if (!Array.isArray(record.items) || record.items.length === 0) die(`INSTRUMENT: ${argv[0]} carries no items`);

/**
 * Pull one line of prose per item out of a rendered post.
 * The body shape comes from renderPost() in fetch-news.mjs:
 *   ### [title](link)\n\n<the sentence>\n\n<small>source · date</small>
 * Keyed by LINK, never by position — a human may reorder or drop items, and
 * matching by index would silently pair item 3's prose with item 5's source.
 */
function linesByLink(mdx) {
  const out = new Map();
  const re = /^### \[[^\]]*\]\(([^)]+)\)\s*\n+([\s\S]*?)(?=\n+<small>)/gm;
  for (const m of mdx.matchAll(re)) out.set(m[1], m[2].trim());
  return out;
}

const isDraft = (mdx) => /^draft:\s*true\s*$/m.test(mdx.split(/^---$/m)[1] ?? '');

const sides = [
  { lang: 'en', file: join(POSTS_DIR, `${record.dateIso}-radar-ai-dev.mdx`) },
  { lang: 'pt', file: join(POSTS_DIR, `${record.dateIso}-radar-ai-dev-pt.mdx`) },
];

const missing = sides.filter((s) => !existsSync(s.file));
if (missing.length) die(`INSTRUMENT: post file(s) absent — ${missing.map((s) => s.file).join(', ')}`);

const loaded = sides.map((s) => ({ ...s, mdx: readFileSync(s.file, 'utf8') }));
const stillDraft = loaded.filter((s) => isDraft(s.mdx));
if (stillDraft.length) {
  log(`NOT_PUBLISHED — ${stillDraft.map((s) => s.lang).join(' and ')} still carry draft: true. ` +
      `Capturing now would record the model's own output as the human's, so nothing was written.`);
  process.exit(1);
}

const byLang = Object.fromEntries(loaded.map((s) => [s.lang, linesByLink(s.mdx)]));

let matched = 0, dropped = 0;
const items = record.items.map((it) => {
  const en = byLang.en.get(it.link) ?? null;
  const pt = byLang.pt.get(it.link) ?? null;
  if (en === null && pt === null) { dropped++; return { ...it, publishedEn: null, publishedPt: null, keptByHuman: false }; }
  matched++;
  return { ...it, publishedEn: en, publishedPt: pt, keptByHuman: true };
});

// A capture that matched nothing is a broken parser, not an edition where the
// human cut every item — those look identical from the outside, and the
// comfortable reading is the wrong one.
if (matched === 0) {
  die(`INSTRUMENT: not one of ${record.items.length} links was found in the published posts. ` +
      `Either the post body shape changed or the wrong edition was passed — not a verdict about the review.`);
}

const verbatim = items.filter((i) => i.keptByHuman && i.publishedEn && i.publishedEn.trim() === String(i.summaryEn ?? '').trim()).length;

const out = {
  ...record,
  items,
  published: {
    capturedAt: new Date().toISOString(),
    files: loaded.map((s) => s.file),
    kept: matched,
    cut: dropped,
    // The number ADR-001 turned on. Recorded per edition so it is recomputed
    // rather than remembered: "5 of 8" lived in three documents and an ADR
    // reasoned from it before anyone measured that the real figure was 7 of 7.
    survivedVerbatimEn: verbatim,
  },
};

writeFileSync(argv[0], JSON.stringify(out, null, 2) + '\n', 'utf8');
log(`WROTE ${argv[0]} — ${matched} kept, ${dropped} cut, ${verbatim} of ${matched} EN lines survived the review verbatim`);
process.exit(0);
