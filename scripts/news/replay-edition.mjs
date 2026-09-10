/**
 * Replay a recorded edition through the CURRENT pipeline.
 *
 * ```bash
 * node scripts/news/replay-edition.mjs scripts/news/editions/2026-09-10.json
 * node scripts/news/replay-edition.mjs <record> --samples 5
 * node scripts/news/replay-edition.mjs <record> --json
 * ```
 *
 * `DIGEST-EVAL.md` §3d said the shortlist "can be replayed rather than waited
 * for". It could not: `EDITIONS_DIR` was write-only in `fetch-news.mjs`, so the
 * capability the document leaned on did not exist. This is it.
 *
 * What it answers: with today's strip, ground floor and entity check, does the
 * model's EN line earn its place on the items a real edition actually carried?
 *
 * 🔴 It NEVER writes to the record it reads. The edition record is half of the
 * eval pair; a replay that overwrote it would destroy the human line it is
 * being measured against.
 *
 * Exit codes follow the rest of the pipeline — 2 is a BROKEN INSTRUMENT (record
 * unreadable, no recoverable ground, model unusable), never a verdict about the
 * model. 1 means real findings. Do not chain this with `&&` as if 0 and 1 were
 * the only outcomes.
 */
import { readFileSync } from 'node:fs';
import { hasSummarisableGround } from './excerpt.mjs';
import { checkSummary } from './check-entities.mjs';

// The relation lane arrives with the sequence-half fix and is not in every
// checker this can run against. 🔴 Absent, it reports ABSENT — an unavailable
// lane and a lane that found nothing are different statements, and printing
// `0 conflicts` for the first would credit a check that never ran.
const relationLane = await import('./check-entities.mjs')
  .then((m) => (typeof m.extractRelations === 'function' ? m : null));
import { summarizeEn, ask, OLLAMA_URL, OLLAMA_MODEL } from './summarise.mjs';

// 🔴 Under --json, stdout carries the record and NOTHING else. A note printed
// beside it makes the output unparseable, and the caller sees a JSON error where
// it expected data — the suite caught exactly that. Notes go to stderr, where a
// human still reads them and `| node -e JSON.parse` does not.
let asJson = false;
const log = (...a) => (asJson ? console.error : console.log)('[replay]', ...a);
const die = (code, msg) => { console.error(`[replay] ${msg}`); process.exit(code); };

const argv = process.argv.slice(2);
const KNOWN = new Set(['--samples', '--json']);
const bad = argv.filter((a, i) => a.startsWith('-') && !KNOWN.has(a) && argv[i - 1] !== '--samples');
if (bad.length) die(2, `INSTRUMENT: unknown flag(s) ${bad.join(' ')}. Known: ${[...KNOWN].join(' ')}`);

asJson = argv.includes('--json');
const paths = argv.filter((a, i) => !a.startsWith('-') && argv[i - 1] !== '--samples');
if (paths.length !== 1) die(2, `INSTRUMENT: give exactly one edition record path, got ${paths.length}`);

// A non-integer sample count must refuse, not fall back. `Number('three')` is
// NaN and `k < NaN` is always false, so a typo would run ZERO samples and print
// a clean tally over nothing — the vacuous pass this whole file exists to avoid.
const rawN = argv.includes('--samples') ? argv[argv.indexOf('--samples') + 1] : '3';
const N = Number(rawN);
if (!Number.isInteger(N) || N < 1) die(2, `INSTRUMENT: --samples must be a positive integer, got ${JSON.stringify(rawN)}`);

let ed;
try { ed = JSON.parse(readFileSync(paths[0], 'utf8')); }
catch (err) { die(2, `INSTRUMENT: cannot read ${paths[0]} — ${err.message}`); }
if (!Array.isArray(ed.items) || ed.items.length === 0) die(2, `INSTRUMENT: ${paths[0]} carries no items`);

// 🔴 A backfilled edition records `sourceExcerpt: null` — DECLARED absence, not
// an empty excerpt. Replaying it would hand the model an empty prompt and grade
// the result against nothing, and every line would come back `no-ground`: a
// confident-looking run that measured the record's age, not the model. Measured
// 2026-09-10 — `2026-09-02.json` is null in all 8 items, `2026-09-10.json` in none.
const nulls = ed.items.filter((i) => i.sourceExcerpt == null).length;
if (nulls === ed.items.length) {
  die(2, `INSTRUMENT: every item in ${paths[0]} declares sourceExcerpt: null (a backfilled edition). ` +
         `There is no recoverable ground to replay against — the feeds moved on. This is not a quiet result.`);
}
if (nulls > 0) log(`${nulls}/${ed.items.length} items declare no source excerpt and are SKIPPED, not scored`);

// The probe is on the path this actually uses. `/api/tags` answering proves a
// server is up, not that generation works — the same false green as pg_isready.
try {
  const probe = await ask('Reply with the single word: ok');
  if (!probe) die(2, `INSTRUMENT: ${OLLAMA_MODEL} at ${OLLAMA_URL} returned an empty generation`);
} catch (err) {
  die(2, `INSTRUMENT: ${OLLAMA_MODEL} at ${OLLAMA_URL} is unusable — ${err.message}`);
}

if (N === 1) log('NOTE: --samples 1. The same item flips between pass and fail across runs ' +
                 '(measured 2026-09-10: 8 of 10 on one item, 0 of 20 on four others), so a single ' +
                 'draw is not a rate. Use --samples 3 or more before quoting a number.');

const rows = [];
let generated = 0, relComparable = 0, relConflicts = 0, relGround = 0;
for (const [n, it] of ed.items.entries()) {
  if (it.sourceExcerpt == null) continue;
  const grounds = [it.sourceExcerpt, it.title];
  if (relationLane) relGround += relationLane.extractRelations(grounds.join(' ')).length;
  const ground = hasSummarisableGround(it.sourceExcerpt, it.title);
  const samples = [];
  for (let k = 0; k < N; k++) {
    // The ground floor is part of the pipeline under test, so the replay honours
    // it. An item it blocks is NOT a model sample and must not count as one.
    const line = ground ? await summarizeEn({ title: it.title, source: it.source, summary: it.sourceExcerpt }) : it.title;
    if (ground) generated++;
    const r = checkSummary({ summary: line, grounds });
    relComparable += r.relationsChecked ?? 0;
    relConflicts += (r.missing?.relations ?? []).length;
    samples.push({ line, status: r.status, ungrounded: [...(r.missing?.strong ?? []), ...(r.missing?.numbers ?? [])] });
  }
  rows.push({ index: n, title: it.title, link: it.link, groundFloorBlocked: !ground,
              human: it.publishedEn ?? null, recorded: it.summaryEn ?? null, samples });
}

// 🔴 A run where the model never spoke is not evidence about the model. If the
// ground floor blocked every item, every line is a headline echo and the tally
// below would read as a clean sweep of a lane with no power.
if (generated === 0) {
  die(2, `INSTRUMENT: VACUOUS — the ground floor blocked all ${rows.length} items, so no model line was generated. ` +
         `A tally over zero generations is not a result about the model.`);
}

const tally = {};
for (const r of rows) for (const s of r.samples) tally[s.status] = (tally[s.status] ?? 0) + 1;
const total = Object.values(tally).reduce((a, b) => a + b, 0);
const nonPass = total - (tally.pass ?? 0);

if (asJson) {
  console.log(JSON.stringify({ record: paths[0], dateIso: ed.dateIso, model: OLLAMA_MODEL, samples: N,
    generated, tally, nonPass, relations: relationLane ? { inGrounds: relGround, comparable: relComparable, conflicts: relConflicts } : null,
    items: rows }, null, 2));
} else {
  for (const r of rows) {
    const t = {};
    for (const s of r.samples) t[s.status] = (t[s.status] ?? 0) + 1;
    log(`[${r.index}] ${JSON.stringify(t)}${r.groundFloorBlocked ? ' (ground floor blocked — headline echoed, not a model line)' : ''}  ${r.title.slice(0, 52)}`);
    for (const s of r.samples) if (s.status !== 'pass') log(`      ${s.status}${s.ungrounded.length ? ` [${s.ungrounded.join(', ')}]` : ''}  ${s.line.slice(0, 110)}`);
  }
  log(`LINES ${total} scored · ${generated} written by the model · ${nonPass} non-pass  ${JSON.stringify(tally)}`);
  log(relationLane
    ? `RELATIONS ${relGround} in grounds · ${relComparable} comparable in summaries · ${relConflicts} conflicts`
    : 'RELATIONS lane ABSENT in this check-entities.mjs — not measured, which is not the same as zero');
}
process.exit(nonPass > 0 ? 1 : 0);
