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

const OLLAMA_URL = process.env.OLLAMA_URL ?? 'http://localhost:11434';
const OLLAMA_MODEL = process.env.OLLAMA_MODEL ?? 'llama3.2:3b';
const FETCH_TIMEOUT_MS = Number(process.env.NEWS_FETCH_TIMEOUT_MS ?? 20000);
const LLM_TIMEOUT_MS = Number(process.env.NEWS_LLM_TIMEOUT_MS ?? 120000);

const argv = process.argv.slice(2);
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

const seen = existsSync(SEEN_PATH) ? JSON.parse(readFileSync(SEEN_PATH, 'utf8')) : { links: [] };
const seenSet = new Set(seen.links);

// ── fetch + parse ─────────────────────────────────────────────────────────
const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_' });

async function fetchFeed(src) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(src.url, {
      signal: ctl.signal,
      headers: { 'user-agent': 'aethos-blog-news/1.0 (+https://blog.aethostech.com.br)' },
    });
    if (!res.ok) return { ok: false, reason: `HTTP ${res.status}` };
    return { ok: true, xml: await res.text() };
  } catch (err) {
    return { ok: false, reason: err.name === 'AbortError' ? `timeout after ${FETCH_TIMEOUT_MS}ms` : err.message };
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
    return { ok: true };
  } catch (err) {
    return { ok: false, reason: err.message };
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

async function summarizeEn(item) {
  const out = await ask(
    `You are writing one entry of a developer news digest. In ONE sentence of at most 35 words, ` +
    `say plainly what happened and why a working software engineer should care. No preamble, no ` +
    `"this article", no marketing adjectives. Output the sentence only.\n\n` +
    `Headline: ${item.title}\nSource: ${item.source}\nExcerpt: ${item.summary.slice(0, 700)}`
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
for (const it of scored) {
  const n = perSource.get(it.source) ?? 0;
  if (n >= 3) continue;
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
  const excerpt = it.summary.slice(0, 220) + (it.summary.length > 220 ? '…' : '');
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

// Only mark links seen once the drafts actually exist — a crash before this
// point must leave the items available for the next run.
if (written.length > 0) {
  const links = [...seenSet, ...shortlist.map((i) => i.link)];
  writeFileSync(SEEN_PATH, JSON.stringify({ updatedAt: new Date().toISOString(), links: links.slice(-800) }, null, 2) + '\n', 'utf8');
}

for (const f of written) log(`WROTE ${f}`);
log(`DIGEST_OK items=${shortlist.length} files=${written.length} — both drafts. Review, then set draft: false.`);
