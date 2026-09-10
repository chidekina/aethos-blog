/**
 * The model calls, and the prompts that define them.
 *
 * A module of its own for the reason `excerpt.mjs` is one: `fetch-news.mjs`
 * runs its whole pipeline at import time, so anything that wants `summarizeEn`
 * — the replay harness, a test — cannot import it without fetching 37 feeds.
 * The alternative was a second copy of the prompt, and two copies of a prompt
 * diverge in silence: the replay would then be measuring a prompt nobody ships.
 *
 * One owner, three callers.
 */

export const OLLAMA_URL = process.env.OLLAMA_URL ?? 'http://localhost:11434';
export const OLLAMA_MODEL = process.env.OLLAMA_MODEL ?? 'llama3.2:3b';
export const LLM_TIMEOUT_MS = Number(process.env.NEWS_LLM_TIMEOUT_MS ?? 120000);

export async function ask(prompt) {
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

export const oneParagraph = (s) => s.replace(/^["'`\s]+|["'`\s]+$/g, '').split('\n').filter(Boolean)[0] ?? '';

// The model is shown a 700-char slice, so THAT is the ground the entity check
// has to measure against — not the full excerpt, which would credit the model
// with material it never saw.
export const PROMPT_EXCERPT = 700;

export async function summarizeEn(item) {
  const out = await ask(
    `You are writing one entry of a developer news digest. In ONE sentence of at most 35 words, ` +
    `say plainly what happened and why a working software engineer should care. No preamble, no ` +
    `"this article", no marketing adjectives. Output the sentence only.\n\n` +
    `Headline: ${item.title}\nSource: ${item.source}\nExcerpt: ${item.summary.slice(0, PROMPT_EXCERPT)}`
  );
  return oneParagraph(out);
}

export async function translatePt(sentence) {
  const out = await ask(
    `Translate to Brazilian Portuguese. Keep technical terms in English (LLM, agent, prompt, ` +
    `commit, build, deploy, framework names). Output the translation only, one sentence, ` +
    `no quotes and no commentary.\n\n${sentence}`
  );
  return oneParagraph(out);
}
