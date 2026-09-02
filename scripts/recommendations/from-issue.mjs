#!/usr/bin/env node
/**
 * Turn an approved "[rec]" issue into a recommendations content file.
 *
 *   node scripts/recommendations/from-issue.mjs 42
 *   node scripts/recommendations/from-issue.mjs 42 --dry-run
 *
 * Reads the issue with `gh`, parses the issue-form sections, validates, and
 * writes src/content/recommendations/<slug>.json. It does NOT commit and does
 * NOT close the issue — approval stays a human step, and the build is the gate.
 *
 * Exit codes: 0 written · 1 rejected (bad input) · 2 broken instrument
 * (gh missing, not authenticated, issue not found). Never chain with `&&` as
 * if 0/1 were the only outcomes.
 */
import { execFileSync } from 'node:child_process';
import { writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OUT_DIR = join(ROOT, 'src/content/recommendations');

const CATEGORIES = ['youtube', 'spotify', 'article', 'site', 'newsletter', 'course', 'book', 'tool'];
const LANGS = ['en', 'pt', 'other'];

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const issueNumber = args.find((a) => /^\d+$/.test(a));

function die(code, msg) {
  console.error(msg);
  process.exit(code);
}

if (!issueNumber) die(2, 'usage: from-issue.mjs <issue-number> [--dry-run]');

let raw;
try {
  raw = execFileSync('gh', ['issue', 'view', issueNumber, '--json', 'body,author,title,number'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
} catch (err) {
  die(2, `INSTRUMENT: could not read issue #${issueNumber} via gh — ${err.message.trim()}`);
}

const issue = JSON.parse(raw);

/**
 * GitHub renders an issue form as `### Label\n\n<value>` blocks. An unanswered
 * optional field renders the literal `_No response_`, which must read as absent
 * rather than as the string — otherwise "_No response_" ends up on the site.
 */
function parseForm(body) {
  const out = {};
  const blocks = body.split(/^### /m).slice(1);
  for (const block of blocks) {
    const nl = block.indexOf('\n');
    const label = block.slice(0, nl < 0 ? undefined : nl).trim().toLowerCase();
    const value = (nl < 0 ? '' : block.slice(nl + 1)).trim();
    out[label] = value === '_No response_' || value === '' ? null : value;
  }
  return out;
}

const f = parseForm(issue.body ?? '');
const get = (...keys) => keys.map((k) => f[k]).find((v) => v != null) ?? null;

const title = get('title');
const url = get('url');
const category = (get('category') ?? '').toLowerCase() || null;
const description = get("why is it worth someone's time?", 'description');
const lang = (get('language of the content', 'language') ?? '').toLowerCase() || null;
const author = get('author / creator', 'author');
const tagsRaw = get('tags');

const problems = [];
if (!title) problems.push('missing Title');
if (!url) problems.push('missing URL');
else {
  try {
    const u = new URL(url);
    if (u.protocol !== 'https:' && u.protocol !== 'http:') problems.push(`URL protocol not http(s): ${u.protocol}`);
  } catch {
    problems.push(`URL is not a valid URL: ${url}`);
  }
}
if (!CATEGORIES.includes(category)) problems.push(`category must be one of ${CATEGORIES.join('|')} — got ${category}`);
if (!description) problems.push('missing description');
else if (description.length > 280) problems.push(`description is ${description.length} chars, max 280`);
if (!LANGS.includes(lang)) problems.push(`lang must be one of ${LANGS.join('|')} — got ${lang}`);

if (problems.length) {
  die(1, `REJECTED issue #${issue.number} (${issue.title}):\n` + problems.map((p) => `  - ${p}`).join('\n'));
}

const slug = title
  .toLowerCase()
  .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
  .replace(/[^a-z0-9]+/g, '-')
  .replace(/^-|-$/g, '')
  .slice(0, 60);

const entry = {
  title,
  url,
  category,
  description,
  ...(author ? { author } : {}),
  lang,
  tags: tagsRaw
    ? tagsRaw.split(',').map((t) => t.trim().toLowerCase()).filter(Boolean)
    : [],
  recommendedBy: issue.author?.login ?? 'unknown',
  addedAt: new Date().toISOString().slice(0, 10),
  sourceIssue: issue.number,
};

const target = join(OUT_DIR, `${slug}.json`);
const collides = existsSync(target);

// A dry run must still SHOW the parsed entry when the slug collides — that is
// exactly when you need to see it, to decide whether it is a genuine duplicate
// or two different things with the same title. It warns loudly and exits 0; the
// real run below still refuses.
if (dryRun) {
  console.log(JSON.stringify(entry, null, 2));
  if (collides) console.log(`\nWARNING: ${target} already exists — a real run would refuse this as a duplicate.`);
  console.log(`\n(dry run — would write ${target})`);
  process.exit(0);
}

if (collides) die(1, `REJECTED: ${target} already exists — duplicate recommendation?`);

mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(target, JSON.stringify(entry, null, 2) + '\n', 'utf8');
console.log(`WROTE ${target}`);
console.log('Next: bun run build   (the schema is the gate), then commit.');
