# CONTRACT — aethos-blog

Machine-checkable invariants for this repo. Prose about *why* the architecture
looks like this lives in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md); this
file carries only what a machine can fail on.

Run by the pre-commit hook via `~/.claude/hooks/contract-validate.py`. Check it
by hand at any time:

```bash
python3 ~/.claude/hooks/contract-validate.py CONTRACT.md
```

A `[VACUOUS]` line means a rule swept zero files and is guarding nothing — fix
the glob, never silence the warning.

## Invariants

1. **The site is static.** No Astro adapter, no server routes, no runtime
   database. Reader input arrives through GitHub issue forms and lands in the
   repo as content. Adding an adapter is an architecture decision, not a patch.
2. **Generated posts are drafts.** Anything written by `scripts/news/` carries
   `draft: true` and is published only by a human editing that flag.
3. **Posts come in pairs.** Every post has an `en` and a `pt` counterpart linked
   by `translationSlug`.
4. **Content schemas are the gate.** `src/content/config.ts` validates every
   post and recommendation at build time; `bun run build` failing IS the
   rejection. No second validation layer.
5. **No secrets in the repo.** The news pipeline talks to a local Ollama over
   `OLLAMA_URL`; nothing here needs an API key.

## validation

```yaml
- pattern: "@astrojs/(vercel|node|cloudflare|netlify)"
  in: "astro.config.mjs"
  absent: true
  message: "An adapter turns the static site into a server deployment — see CONTRACT invariant 1. Deliberate? Update this contract in the same commit."

- pattern: "draft: true"
  in: "src/content/blog/*-radar-ai-dev*.mdx"
  message: "Generated radar digests must stay draft:true until a human reviews them (invariant 2)."

- pattern: "translationSlug"
  in: "src/content/blog/*.mdx"
  message: "Every post needs a translationSlug pairing it with its other language (invariant 3)."

- pattern: "sk-[A-Za-z0-9]{20}"
  in: "scripts/**/*.mjs"
  absent: true
  message: "Hardcoded API key in the news pipeline. It uses a local Ollama and needs no key (invariant 5)."
```
