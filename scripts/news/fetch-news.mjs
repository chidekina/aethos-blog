#!/usr/bin/env node
/**
 * AI/dev news digest — fetch, filter, summarize locally, emit MDX DRAFTS.
 *
 *   node scripts/news/fetch-news.mjs                # write EN + PT drafts
 *   node scripts/news/fetch-news.mjs --dry-run      # print the shortlist, write nothing
 *   node scripts/news/fetch-news.mjs --check-sources # probe every feed, write nothing
 *   node scripts/news/fetch-news.mjs --no-llm       # skip Ollama, use feed excerpts
 *
 * Nothing here publishes. Both files are written with `draft: true`, so they are
 * excluded from the build until a human flips the flag. See docs/NEWS-PIPELINE.md.
 *
 * Exit codes — 0 wrote (or nothing new, said so explicitly) · 1 no usable items
 * survived the filters · 2 BROKEN INSTRUMENT (no network, Ollama down, config
 * unreadable, every feed failed). 2 is never a verdict about the news; do not
 * chain this with `&&` as if 0/1 were the only outcomes.
 */
import { XMLParser } from 'fast-xml-parser';
import { checkItem } from './check-entities.mjs';
import { trimToBoundary, EXCERPT_BUDGET } from './excerpt.mjs';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
// Overridable so the test suite can point the whole pipeline at fixtures.
// Production never sets these — a test that had to redefine the predicate would
// be measuring its own copy instead of what cron runs.
const CONFIG_PATH = process.env.NEWS_CONFIG ?? join(ROOT, 'scripts/news/sources.json');
const SEEN_PATH = process.env.NEWS_SEEN ?? join(ROOT, 'scripts/news/seen.json');
const POSTS_DIR = process.env.NEWS_POSTS_DIR ?? join(ROOT, 'src/content/blog');
// The draft side of the eval pair (DIGEST-EVAL item 2). Edition 1 survives only
// because its draft happened to be committed before review, and only by git
// archaeology; nothing captured it on purpose, so no eval set could accumulate.
const EDITIONS_DIR = process.env.NEWS_EDITIONS_DIR ?? join(ROOT, 'scripts/news/editions');

const OLLAMA_URL = process.env.OLLAMA_URL ?? 'http://localhost:11434';
const OLLAMA_MODEL = process.env.OLLAMA_MODEL ?? 'llama3.2:3b';
const FETCH_TIMEOUT_MS = Number(process.env.NEWS_FETCH_TIMEOUT_MS ?? 20000);
const LLM_TIMEOUT_MS = Number(process.env.NEWS_LLM_TIMEOUT_MS ?? 120000);
// Budget for the liveness probe only. A single token on a WARM runner is ~1 s;
// the budget exists for the COLD case, where the model must be loaded first.
//
// 🔴 60 s, not 30 s, and the change is measured rather than padded. Three loads
// timed on this machine on 2026-09-04: 4.6 s (blob warm, another model resident
// and evicted), 8.7 s (cold, GPU free), and ~35 s (another model resident and
// kept — they coexist at 3345 MB of 4096). A 30 s budget sits INSIDE that
// spread, so it converts an ordinary slow load into `RESULT=BROKEN`, which is
// exactly what the weekly digest reported. The cost of 60 s is that a genuinely
// dead server takes a minute to say so, once a week, in a job nobody watches
// live.
const PROBE_TIMEOUT_MS = Number(process.env.NEWS_PROBE_TIMEOUT_MS ?? 60000);

const argv = process.argv.slice(2);
// An unknown flag is a BROKEN INSTRUMENT, not a no-op. Measured 2026-09-02: a
// verification run passed `--config <candidates.json>`, which this script never
// read — the knob is the NEWS_CONFIG env var. The run silently probed the live
// sources.json instead and reported a clean sweep, so 38 candidate feeds were
// "confirmed" without ever being fetched. A flag that is ignored produces a
// confident answer about the wrong input, which is worse than an error.
const KNOWN_FLAGS = new Set(['--dry-run', '--check-sources', '--no-llm']);
const unknownFlags = argv.filter((a) => !KNOWN_FLAGS.has(a));
if (unknownFlags.length > 0) {
  console.error(
    `[news] INSTRUMENT: unknown argument(s) ${unknownFlags.join(' ')} — known flags are ` +
    `${[...KNOWN_FLAGS].join(' ')}. Paths are set through env vars, not flags ` +
    `(NEWS_CONFIG, NEWS_SEEN, NEWS_POSTS_DIR). Refusing to run rather than silently ` +
    `ignoring an argument and answering about the wrong input.`
  );
  process.exit(2);
}
const dryRun = argv.includes('--dry-run');
const checkSources = argv.includes('--check-sources');
const noLlm = argv.includes('--no-llm');

const log = (...a) => console.log(`[news]`, ...a);
function die(code, msg) { console.error(`[news] ${msg}`); process.exit(code); }

// ── config ────────────────────────────────────────────────────────────────
let cfg;
try {
  cfg = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
} catch (err) {
  die(2, `INSTRUMENT: cannot read ${CONFIG_PATH} — ${err.message}`);
}
if (!Array.isArray(cfg.sources) || cfg.sources.length === 0) {
  die(2, 'INSTRUMENT: sources.json has no sources — a scan over zero feeds is not a quiet news day');
}

// A malformed numeric knob must not read as "no limit". `Number("three")` is NaN
// and `n >= NaN` is ALWAYS false, so a typo in maxPerDigest silently removes the
// per-source cap — precisely the firehose this cap exists to stop, arriving as a
// config typo nobody would look for. Same for timeoutMs, where NaN aborts the
// fetch instantly and reads as a dead feed. Refuse instead of guessing: falling
// back to the default would hide the typo forever.
function posInt(value, where) {
  if (value == null) return null;
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0 || !Number.isInteger(n)) {
    die(2, `INSTRUMENT: ${where} must be a positive integer, got ${JSON.stringify(value)}. ` +
           `A non-numeric cap becomes NaN, and every comparison against NaN is false — ` +
           `the limit would silently vanish rather than fail.`);
  }
  return n;
}
posInt(cfg.maxPerSource, 'maxPerSource');
for (const s of cfg.sources) {
  posInt(s.maxPerDigest, `maxPerDigest on source "${s.name}"`);
  posInt(s.timeoutMs, `timeoutMs on source "${s.name}"`);
}

const seen = existsSync(SEEN_PATH) ? JSON.parse(readFileSync(SEEN_PATH, 'utf8')) : { links: [] };
const seenSet = new Set(seen.links);

// ── fetch + parse ─────────────────────────────────────────────────────────
const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_' });

async function fetchFeed(src) {
  // Per-source override. Measured 2026-09-02: satisfice.com answers in >20s but
  // well under 60s. At the shared default it fails every run, and a slow feed
  // logs identically to a dead one — so the digest would lose it silently
  // rather than wait the extra seconds once a week.
  const timeoutMs = Number(src.timeoutMs ?? FETCH_TIMEOUT_MS);
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(src.url, {
      signal: ctl.signal,
      headers: { 'user-agent': 'aethos-blog-news/1.0 (+https://blog.aethostech.com.br)' },
    });
    if (!res.ok) return { ok: false, reason: `HTTP ${res.status}` };
    return { ok: true, xml: await res.text() };
  } catch (err) {
    return { ok: false, reason: err.name === 'AbortError' ? `timeout after ${timeoutMs}ms` : err.message };
  } finally {
    clearTimeout(timer);
  }
}

const asArray = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
const textOf = (v) => {
  if (v == null) return '';
  if (typeof v === 'string') return v;
  if (typeof v === 'object') return String(v['#text'] ?? v['@_href'] ?? '');
  return String(v);
};

function stripHtml(s) {
  return String(s)
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    // Numeric entities are common in RSS titles (&#8217; for a curly apostrophe);
    // leaving them raw puts a literal "&#8217;" on the page.
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/\s+/g, ' ')
    .trim();
}

/** Handles both RSS 2.0 (`channel.item`) and Atom (`feed.entry`) in one shape. */
function parseItems(xml, src) {
  const doc = parser.parse(xml);
  const rss = asArray(doc?.rss?.channel?.item);
  const atom = asArray(doc?.feed?.entry);
  const raw = rss.length ? rss : atom;

  return raw.map((it) => {
    const link = rss.length
      ? textOf(it.link)
      : (asArray(it.link).find((l) => l?.['@_rel'] !== 'self')?.['@_href'] ?? textOf(it.link));
    const dateStr = it.pubDate ?? it.published ?? it.updated ?? it['dc:date'] ?? null;
    const summary = stripHtml(
      textOf(it.description) || textOf(it.summary) || textOf(it.content) || textOf(it['content:encoded'])
    );
    return {
      source: src.name,
      tag: src.tag,
      weight: src.weight ?? 1,
      title: stripHtml(textOf(it.title)),
      link: String(link ?? '').trim(),
      date: dateStr ? new Date(dateStr) : null,
      summary: summary.slice(0, 1200),
    };
  }).filter((i) => i.title && i.link);
}

// ── scoring ───────────────────────────────────────────────────────────────
function score(item) {
  const hay = `${item.title} ${item.summary}`.toLowerCase();
  if (cfg.blocklist?.some((b) => hay.includes(b.toLowerCase()))) return -1;
  let s = item.weight;
  for (const [kw, w] of Object.entries(cfg.keywords ?? {})) {
    if (hay.includes(kw.toLowerCase())) s += w;
  }
  return s;
}

// ── Ollama ────────────────────────────────────────────────────────────────
async function ollamaAlive() {
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 4000);
    const res = await fetch(`${OLLAMA_URL}/api/tags`, { signal: ctl.signal });
    clearTimeout(t);
    if (!res.ok) return { ok: false, reason: `HTTP ${res.status}` };
    const body = await res.json();
    const names = (body.models ?? []).map((m) => m.name);
    if (!names.includes(OLLAMA_MODEL)) {
      return { ok: false, reason: `model ${OLLAMA_MODEL} not pulled (have: ${names.join(', ') || 'none'})` };
    }
    // The catalogue answering is NOT the model generating. Measured 2026-09-03:
    // the llama3.2:3b runner sat at 0.0% CPU for 51 minutes while every
    // /api/generate timed out at 600s, cold and warm alike — and /api/tags
    // answered in under a second the whole time, so this function returned ok
    // and the digest went on to hang forever. Same false-green as `pg_isready`
    // proving *a* postgres listens rather than yours.
    //
    // So probe the path we actually use, with a tiny prompt and a short budget.
    const gctl = new AbortController();
    const gt = setTimeout(() => gctl.abort(), PROBE_TIMEOUT_MS);
    try {
      const gres = await fetch(`${OLLAMA_URL}/api/generate`, {
        method: 'POST',
        signal: gctl.signal,
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ model: OLLAMA_MODEL, prompt: 'ok', stream: false, options: { num_predict: 1 } }),
      });
      if (!gres.ok) return { ok: false, reason: `generate probe HTTP ${gres.status}` };
      await gres.json();
    } catch (err) {
      if (err.name !== 'AbortError') return { ok: false, reason: `generate probe failed — ${err.message}` };
      // 🔴 RETRACTED, and the retraction is the point. This block used to say
      // that a 4096 MiB GPU "cannot hold" llama3.2:3b (2.8 GB) alongside
      // nomic-embed-text (595 MB) and that ollama "waits for a slot rather than
      // evicting". Both were measured false on 2026-09-04:
      //
      //   the two coexist          3345 MB of 4096, both listed in /api/ps
      //   eviction does happen     a later run evicted nomic and loaded in 4.6 s
      //   load times observed      4.6 s, 8.7 s, ~35 s — it VARIES per run
      //
      // What is stable, and what actually explains the failure this code
      // reports: a model being LOADED is not listed by /api/ps at all. Measured
      // by polling during a cold load — empty for 8.5 s of the 8.7 s, while the
      // GPU had already climbed to 2743 MiB. So "generation timed out AND
      // /api/ps is empty" is the signature of a load in progress, not of an idle
      // server and not of a wedged runner.
      // 🔴 An EMPTY /api/ps is not evidence of an idle server, and the branch
      // below used to read it as one — it said "genuinely wedged runner, stop
      // <our model>". Measured 2026-09-04 on a cron rehearsal that produced
      // RESULT=BROKEN: /api/ps read empty, generation outlived 30000ms, and a
      // cold load with the slot PROVABLY free took 8 s on the same machine
      // minutes later. Those three facts together identify no cause. A load
      // queued behind a holder is invisible in /api/ps by construction, so
      // "wedged" and "something held the card and released it" render
      // identically there. Naming one of them is a guess wearing the clothes of
      // a diagnosis, and it sends the operator to `ollama stop` the one model
      // that stopping cannot help.
      const holders = await loadedModels();
      const others = holders.models.filter((m) => m.name !== OLLAMA_MODEL);
      const discriminate =
        `To separate a slow load from a dead server, re-run the probe by hand and WATCH: ` +
        `\`curl -s ${OLLAMA_URL}/api/generate -d '{"model":"${OLLAMA_MODEL}","prompt":"hi","stream":false}'\` ` +
        `alongside \`nvidia-smi --query-gpu=memory.used --format=csv\`. VRAM climbing while /api/ps stays ` +
        `empty is a load running; VRAM flat at zero for a minute is not.`;
      const detail = !holders.queried
        ? `/api/ps could NOT be read (${holders.why}), so the holder is unknown. An unreadable instrument ` +
          `is not an empty one; this is not evidence that nothing is loaded. ${discriminate}`
        : holders.models.length === 0
          ? `/api/ps is empty, which most likely means a LOAD IS IN PROGRESS: a model being loaded is ` +
            `not listed there until it finishes (measured — empty for 8.5 s of an 8.7 s cold load, with ` +
            `the GPU already at 2743 MiB). Loads on this machine have taken 4.6 s, 8.7 s and ~35 s, so a ` +
            `probe outliving ${PROBE_TIMEOUT_MS}ms points at a slow load rather than a dead server. ${discriminate}`
          : others.length === 0
            ? `Only ${OLLAMA_MODEL} is loaded, so it is wedged rather than blocked: \`ollama stop ${OLLAMA_MODEL}\`.`
            : `VRAM is occupied by ${others.map((m) => `${m.name} (${m.gb} GB)`).join(', ')}. That does NOT ` +
              `mean the load cannot happen — measured 2026-09-04, the two coexist at 3345 MB of 4096 and ollama ` +
              `sometimes evicts instead. What it costs is TIME: the slowest load observed with another model ` +
              `resident was ~35 s against 8.7 s cold with the card free. Either free it ` +
              `(${others.map((m) => `\`ollama stop ${m.name}\``).join(' ')}) or raise NEWS_PROBE_TIMEOUT_MS. ` +
              `Stopping ${OLLAMA_MODEL} is not the fix — it is not loaded.`;
      return {
        ok: false,
        reason: `catalogue answers but generation did not respond within ${PROBE_TIMEOUT_MS}ms. ${detail}`,
      };
    } finally {
      clearTimeout(gt);
    }
    return { ok: true };
  } catch (err) {
    return { ok: false, reason: err.message };
  }
}

/**
 * What ollama currently holds in memory. Best effort: this runs only on the
 * failure path, so it must never throw and never hang for long.
 *
 * 🔴 It returns `queried` SEPARATELY from the list, and that separation is the
 * whole point. The previous version returned `[]` for three different states —
 * nothing loaded, /api/ps answering non-200, and /api/ps unreachable — and the
 * caller then asserted "nothing is loaded" from it. A reader that cannot read
 * and a subject that is empty are indistinguishable in a bare `[]`, and the
 * comfortable reading of the two is the wrong one. Same family as every other
 * zero-without-a-control recorded in this repo.
 *
 * @returns {Promise<{queried: boolean, models: Array<{name: string, gb: string}>, why: string}>}
 */
async function loadedModels() {
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 5000);
    try {
      const res = await fetch(`${OLLAMA_URL}/api/ps`, { signal: ctl.signal });
      if (!res.ok) return { queried: false, models: [], why: `HTTP ${res.status}` };
      const body = await res.json();
      return {
        queried: true,
        why: '',
        models: (body.models ?? []).map((m) => ({
          name: m.name ?? m.model ?? '(unnamed)',
          gb: ((m.size_vram ?? m.size ?? 0) / 1e9).toFixed(1),
        })),
      };
    } finally { clearTimeout(t); }
  } catch (err) {
    return { queried: false, models: [], why: err.name === 'AbortError' ? 'timed out after 5000ms' : err.message };
  }
}

async function ask(prompt) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), LLM_TIMEOUT_MS);
  try {
    const res = await fetch(`${OLLAMA_URL}/api/generate`, {
      method: 'POST',
      signal: ctl.signal,
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: OLLAMA_MODEL, prompt, stream: false, options: { temperature: 0.3 } }),
    });
    if (!res.ok) throw new Error(`Ollama HTTP ${res.status}`);
    const body = await res.json();
    return String(body.response ?? '').trim();
  } finally {
    clearTimeout(timer);
  }
}

const oneParagraph = (s) => s.replace(/^["'`\s]+|["'`\s]+$/g, '').split('\n').filter(Boolean)[0] ?? '';


// The model is shown a 700-char slice, so THAT is the ground the entity check
// has to measure against — not the full excerpt, which would credit the model
// with material it never saw.
const PROMPT_EXCERPT = 700;

async function summarizeEn(item) {
  const out = await ask(
    `You are writing one entry of a developer news digest. In ONE sentence of at most 35 words, ` +
    `say plainly what happened and why a working software engineer should care. No preamble, no ` +
    `"this article", no marketing adjectives. Output the sentence only.\n\n` +
    `Headline: ${item.title}\nSource: ${item.source}\nExcerpt: ${item.summary.slice(0, PROMPT_EXCERPT)}`
  );
  return oneParagraph(out);
}

async function translatePt(sentence) {
  const out = await ask(
    `Translate to Brazilian Portuguese. Keep technical terms in English (LLM, agent, prompt, ` +
    `commit, build, deploy, framework names). Output the translation only, one sentence, ` +
    `no quotes and no commentary.\n\n${sentence}`
  );
  return oneParagraph(out);
}

// ── MDX ───────────────────────────────────────────────────────────────────
const esc = (s) => String(s).replace(/"/g, '\\"');

function renderPost({ lang, dateIso, items, tags }) {
  const isPt = lang === 'pt';
  const title = isPt ? `Radar: IA e dev — ${dateIso}` : `Radar: AI & dev — ${dateIso}`;
  const description = isPt
    ? `O que apareceu em IA, ferramentas e testes na semana de ${dateIso}, com o porquê de cada item.`
    : `What surfaced in AI, tooling and testing during the week of ${dateIso}, and why each item matters.`;
  const intro = isPt
    ? `Compilado automaticamente das fontes em \`scripts/news/sources.json\`, resumido por um modelo local e **revisado à mão antes de publicar**. Cada link vai para a fonte original.`
    : `Compiled automatically from the feeds in \`scripts/news/sources.json\`, summarized by a local model and **reviewed by hand before publishing**. Every link points at the original source.`;
  const outro = isPt
    ? `Achou algo que deveria estar aqui? [Indique na página de recomendações](/recommendations).`
    : `Found something that belongs here? [Send it through the recommendations page](/recommendations).`;

  const body = items.map((it) => {
    const line = isPt ? it.summaryPt : it.summaryEn;
    const dateLabel = it.date ? it.date.toISOString().slice(0, 10) : '';
    return `### [${it.title}](${it.link})\n\n${line}\n\n<small>${it.source}${dateLabel ? ` · ${dateLabel}` : ''}</small>`;
  }).join('\n\n');

  return `---
title: "${esc(title)}"
description: "${esc(description)}"
date: ${dateIso}
lang: "${lang}"
tags: [${tags.map((t) => `"${t}"`).join(', ')}]
series: "${isPt ? 'Radar' : 'Radar'}"
translationSlug: "${dateIso}-radar-ai-dev${isPt ? '' : '-pt'}"
draft: true
---

${intro}

${body}

---

${outro}
`;
}

// ── main ──────────────────────────────────────────────────────────────────
const results = await Promise.all(
  cfg.sources.map(async (src) => ({ src, res: await fetchFeed(src) }))
);

const failures = results.filter((r) => !r.res.ok);
for (const f of failures) log(`FEED FAILED  ${f.src.name} — ${f.res.reason}`);

if (checkSources) {
  for (const r of results.filter((x) => x.res.ok)) {
    let n = 0;
    try { n = parseItems(r.res.xml, r.src).length; } catch (err) { log(`PARSE FAILED ${r.src.name} — ${err.message}`); }
    log(`ok  ${String(n).padStart(3)} items  ${r.src.name}`);
  }
  log(`${results.length - failures.length}/${results.length} feeds reachable`);
  process.exit(failures.length === results.length ? 2 : 0);
}

if (failures.length === results.length) {
  die(2, `INSTRUMENT: every one of ${results.length} feeds failed — that is a network or config fault, not a quiet news week`);
}

const cutoff = Date.now() - (cfg.maxAgeDays ?? 8) * 86400000;
let pool = [];
for (const { src, res } of results) {
  if (!res.ok) continue;
  try { pool.push(...parseItems(res.xml, src)); }
  catch (err) { log(`PARSE FAILED ${src.name} — ${err.message}`); }
}

const totalFetched = pool.length;

// Undated items are KEPT, because a feed with broken timestamps would otherwise
// vanish under the window without a word. But "kept" used to mean "immortal":
// nothing can age out an item that has no date, so a month-old post surfaces as
// this week's news forever. Measured 2026-09-02 — the Google Developers Blog
// feed is RSS 2.0 with no date element at all on its items, and a post from
// August 4th reached the first digest as fresh.
//
// So: keep them, name the feeds that force it, and cap how many can reach one
// digest. Silence about a dateless feed is what made the first miss invisible.
const dated = (i) => i.date && !Number.isNaN(i.date.getTime());
const datelessBySource = new Map();
for (const i of pool) if (!dated(i)) datelessBySource.set(i.source, (datelessBySource.get(i.source) ?? 0) + 1);
for (const [src, n] of datelessBySource) {
  log(`NO DATES  ${src} — ${n} items carry no parseable date; they cannot age out and are capped at ${cfg.maxUndated ?? 2} per digest`);
}

pool = pool.filter((i) => !dated(i) || i.date.getTime() >= cutoff);
const afterAge = pool.length;
pool = pool.filter((i) => !seenSet.has(i.link));
const afterSeen = pool.length;

const scored = pool
  .map((i) => ({ ...i, score: score(i) }))
  .filter((i) => i.score >= (cfg.minScore ?? 2))
  .sort((a, b) => b.score - a.score || (b.date?.getTime() ?? 0) - (a.date?.getTime() ?? 0));

// Never let one loud feed fill the digest, and never let undated items — which
// no window can expire — take it over.
const perSource = new Map();
const shortlist = [];
let undatedUsed = 0;
// The cap was hardcoded at 3. `weight` biases an item's SCORE, so a firehose
// still reached a third of an 8-item digest on volume alone — TabNews alone
// posts ~400-600 items/month against ~1/month from several others here. The
// limit is now per-source, so a high-volume community feed can be admitted at
// 1 without being weighted down into never appearing at all.
const capFor = (src) => {
  // Values were validated as positive integers at startup, so no NaN can reach here.
  const own = cfg.sources.find((s) => s.name === src)?.maxPerDigest;
  return Number(own ?? cfg.maxPerSource ?? 3);
};
for (const it of scored) {
  const n = perSource.get(it.source) ?? 0;
  if (n >= capFor(it.source)) continue;
  if (!dated(it)) {
    if (undatedUsed >= (cfg.maxUndated ?? 2)) continue;
    undatedUsed++;
  }
  perSource.set(it.source, n + 1);
  shortlist.push(it);
  if (shortlist.length >= (cfg.maxItems ?? 8)) break;
}

log(`fetched ${totalFetched} · within ${cfg.maxAgeDays}d ${afterAge} · unseen ${afterSeen} · scored ${scored.length} · shortlist ${shortlist.length}`);

if (shortlist.length === 0) {
  log('NO_NEW_ITEMS — nothing cleared the filters. Feeds were reachable; this is a real quiet result, not a failure.');
  process.exit(1);
}

if (dryRun) {
  for (const it of shortlist) log(`  ${String(it.score).padStart(3)}  [${it.source}] ${it.title}\n       ${it.link}`);
  log('(dry run — no files written, seen.json untouched)');
  process.exit(0);
}

// Summaries
let useLlm = !noLlm;
if (useLlm) {
  const alive = await ollamaAlive();
  if (!alive.ok) {
    die(2, `INSTRUMENT: Ollama unusable at ${OLLAMA_URL} — ${alive.reason}. ` +
           `Start it (\`ollama serve\`) or rerun with --no-llm. Refusing to emit a digest whose ` +
           `summaries would silently be raw feed excerpts.`);
  }
}

for (const it of shortlist) {
  if (useLlm) {
    try {
      it.summaryEn = await summarizeEn(it);
      it.summaryPt = await translatePt(it.summaryEn);
    } catch (err) {
      log(`LLM FAILED on "${it.title}" — ${err.message}; falling back to feed excerpt for this item`);
      it.summaryEn = '';
      it.summaryPt = '';
    }
  }
  const excerpt = trimToBoundary(it.summary, EXCERPT_BUDGET);
  if (!it.summaryEn) it.summaryEn = excerpt || it.title;
  if (!it.summaryPt) it.summaryPt = it.summaryEn;
}

const dateIso = new Date().toISOString().slice(0, 10);
const tags = [...new Set(['radar', ...shortlist.map((i) => i.tag)])];

mkdirSync(POSTS_DIR, { recursive: true });
const written = [];
for (const lang of ['en', 'pt']) {
  const slug = `${dateIso}-radar-ai-dev${lang === 'pt' ? '-pt' : ''}`;
  const file = join(POSTS_DIR, `${slug}.mdx`);
  if (existsSync(file)) { log(`SKIP ${file} — already exists, not overwriting`); continue; }
  writeFileSync(file, renderPost({ lang, dateIso, items: shortlist, tags }), 'utf8');
  written.push(file);
}

// The edition record — the DRAFT half of the eval pair (DIGEST-EVAL item 2).
// Written only when a draft actually reached disk, for the same reason seen.json
// is: a record of an edition that was never emitted is a lie about what the
// model produced. `sourceExcerpt` is the exact slice the prompt carried, so the
// entity check measures the model against what it was shown and nothing more.
if (written.length > 0) {
  mkdirSync(EDITIONS_DIR, { recursive: true });
  const recordPath = join(EDITIONS_DIR, `${dateIso}.json`);
  const record = {
    schemaVersion: 1,
    dateIso,
    generatedAt: new Date().toISOString(),
    llm: useLlm,
    model: useLlm ? OLLAMA_MODEL : null,
    drafts: written,
    items: shortlist.map((it) => ({
      title: it.title,
      link: it.link,
      source: it.source,
      score: it.score,
      sourceExcerpt: String(it.summary ?? '').slice(0, PROMPT_EXCERPT),
      summaryEn: it.summaryEn,
      summaryPt: it.summaryPt,
    })),
    // Filled in by capture-published.mjs after a human flips `draft: false`.
    published: null,
  };
  if (existsSync(recordPath)) {
    log(`SKIP ${recordPath} — an edition record for ${dateIso} already exists, not overwriting`);
  } else {
    writeFileSync(recordPath, JSON.stringify(record, null, 2) + '\n', 'utf8');
    log(`WROTE ${recordPath}`);
  }

  // Advisory only, and deliberately so: these are drafts, a human reads every
  // line against its source before publishing, and a blocking gate here would
  // stop an edition over a token the reviewer was about to fix anyway. The
  // point is that the check is INVOKED — a check nobody runs is the prose it
  // was meant to replace.
  let flagged = 0;
  let tokensChecked = 0;
  for (const r of record.items.map(checkItem)) {
    for (const lane of ['en', 'pt', 'translation']) {
      const c = r[lane];
      tokensChecked += c.checked ?? 0;
      if (c.status !== 'fail') continue;
      flagged++;
      const what = [...c.missing.strong, ...c.missing.numbers].join(', ');
      const verb = lane === 'translation' ? 'dropped in the PT line' : 'not in the source';
      log(`ENTITY_CHECK ${lane.toUpperCase()} "${r.title}" — ${verb}: ${what}`);
    }
  }
  // 🔴 "0 findings" out of 0 checked tokens is VACUOUS, and it reads exactly like
  // a clean run. Measured 2026-09-04: with --no-llm the PT line is a copy of the
  // EN line, so the EN→PT lane is not applicable on every item, and each summary
  // IS its own source excerpt, so the grounding lanes are trivially satisfied.
  // The check has zero power in that mode and must say so rather than reporting
  // a reassuring zero.
  if (tokensChecked === 0) {
    log(`ENTITY_CHECK VACUOUS — 0 tokens were checkable across ${record.items.length} items, so the zero above means nothing. ` +
        `Expected under --no-llm: the PT line is a copy of the EN line and each summary is its own source.`);
  } else {
    log(`ENTITY_CHECK ${flagged} ungrounded finding(s) across ${record.items.length} items, ${tokensChecked} tokens checked (advisory — review before publishing)`);
  }
}

// Only mark links seen once the drafts actually exist — a crash before this
// point must leave the items available for the next run.
if (written.length > 0) {
  const links = [...seenSet, ...shortlist.map((i) => i.link)];
  writeFileSync(SEEN_PATH, JSON.stringify({ updatedAt: new Date().toISOString(), links: links.slice(-800) }, null, 2) + '\n', 'utf8');
}

for (const f of written) log(`WROTE ${f}`);

// Measured 2026-09-02 under a real cron environment: when both target files
// already existed the run skipped both, wrote nothing, and still logged
// "DIGEST_OK ... drafts written". A run that produced no file must not report
// success — that is the false-green this whole script is built to avoid.
if (written.length === 0) {
  log(`NOTHING_WRITTEN — every target file already existed. Delete them (and their links from seen.json) to regenerate.`);
  process.exit(1);
}

log(`DIGEST_OK items=${shortlist.length} files=${written.length} — drafts, not published. Review, then set draft: false.`);
