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
2. **Generated posts are born drafts.** Everything `scripts/news/` writes carries
   `draft: true`; publishing is a human editing that flag after checking each
   line against its source.

   🔴 **This invariant is deliberately NOT in the validation block below, and
   the reason matters.** Two grep-shaped versions of it were tried and both were
   worthless. Globbing the published posts made *publishing a reviewed digest* —
   the intended path — a violation: the gate was aimed at the artifact instead
   of the thing that produces it. Retargeting it at the generator then read
   green against a generator mutated to emit `draft: false`, because the
   frontmatter lives inside a template literal and this validator blanks string
   text before matching. A rule that cannot see its own subject is worse than no
   rule: it reports enforcement it never performed.

   The enforcement is `scripts/news/fetch-news.test.sh` ARM 8, which runs the
   generator and asserts both emitted files carry the flag. Verified by mutation
   on 2026-09-02: flipping `draft: true` to `false` in the generator turns the
   suite red (18/1) on exactly that assertion, while the contract stayed green.
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

- pattern: "translationSlug"
  in: "src/content/blog/*.mdx"
  message: "Every post needs a translationSlug pairing it with its other language (invariant 3)."

- pattern: "sk-[A-Za-z0-9]{20}"
  in: "scripts/**/*.mjs"
  absent: true
  message: "Hardcoded API key in the news pipeline. It uses a local Ollama and needs no key (invariant 5)."
```
