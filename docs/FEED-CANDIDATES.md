# Feed candidates — researched 2026-09-02

38 candidate feeds were researched by five parallel agents, each required to
actually fetch every URL. Every candidate below was then re-probed through
**this repo's own parser** (`fetch-news.mjs --check-sources`), because a URL that
answers `curl` is not the same as a feed this pipeline can read.

```bash
# reproduce: stage candidates in a config, point the real prober at it
NEWS_CONFIG=/path/to/candidates.json node scripts/news/fetch-news.mjs --check-sources
```

🔴 The flag is `NEWS_CONFIG` (env var). Passing `--config` is **silently ignored**
and the prober reads the live `sources.json` instead — the first verification run
here did exactly that and "confirmed" nine feeds that were never under test.

🔴 Every probe run carries a **negative control**: a URL that must 404. Without it
a clean sweep is indistinguishable from a prober pointed at the wrong file.

**Result: 37 of 38 reachable, control 404'd as required.**

## Verified live, with item counts from the probe

| feed | url | tag | w | items | note |
|---|---|---|---:|---:|---|
| MCP blog | `https://blog.modelcontextprotocol.io/index.xml` | ai | 3 | 26 | `rss.xml`/`feed.xml` both 404 — `index.xml` is the real one |
| Hamel Husain | `https://hamel.dev/index.xml` | ai | 3 | 20 | LLM eval practice; **emits some dateless items** |
| Eugene Yan | `https://eugeneyan.com/rss/` | ai | 3 | 212 | eval/RAG practitioner |
| Drew Breunig | `https://www.dbreunig.com/feed.xml` | ai | 2 | 20 | context/harness engineering |
| Shrivu Shankar | `https://blog.sshh.io/feed` | ai | 2 | 20 | agent harness design |
| Answer.AI | `https://www.answer.ai/index.xml` | ai | 2 | 20 | irregular, 5-month gaps |
| Anthropic news (mirror) | `https://raw.githubusercontent.com/taobojlen/anthropic-rss-feed/main/anthropic_news_rss.xml` | ai | 2 | 13 | see caveat below |
| Hugging Face | `https://huggingface.co/blog/feed.xml` | ai | 1 | 855 | high volume |
| Astro Blog | `https://astro.build/rss.xml` | tooling | 3 | 186 | our own stack |
| Bun Blog | `https://bun.com/rss.xml` | tooling | 3 | 177 | |
| TypeScript Devblog | `https://devblogs.microsoft.com/typescript/feed/` | tooling | 3 | 10 | ~0.5/mo, every item matters |
| Node.js Blog | `https://nodejs.org/en/feed/blog.xml` | tooling | 2 | 1052 | mostly patch releases |
| Vite Blog | `https://vite.dev/blog.rss` | tooling | 2 | 12 | sparse |
| Drizzle releases | `https://github.com/drizzle-team/drizzle-orm/releases.atom` | tooling | 2 | 10 | only Drizzle feed that exists |
| Vercel | `https://vercel.com/atom` | tooling | 1 | 1545 | firehose, filter hard |
| Crunchy Data | `https://www.crunchydata.com/blog/rss.xml` | dev | 3 | 5 | Postgres craft |
| This Week In React | `https://thisweekinreact.com/newsletter/rss.xml` | dev | 3 | 5 | fills the React gap |
| PostgreSQL News | `https://www.postgresql.org/news.rss` | dev | 2 | 10 | |
| Marc Brooker | `https://brooker.co.za/blog/rss.xml` | dev | 2 | 163 | distributed systems |
| Dan Luu | `https://danluu.com/atom.xml` | dev | 2 | 128 | measurement-driven |
| OpenTelemetry | `https://opentelemetry.io/blog/index.xml` | dev | 2 | 20 | vendor-free observability |
| TkDodo | `https://tkdodo.eu/blog/rss.xml` | dev | 1 | 91 | low volume |
| Google Testing Blog | `https://testing.googleblog.com/feeds/posts/default` | testing | 3 | 25 | 302s to feedburner |
| Kent Beck | `https://newsletter.kentbeck.com/feed` | testing | 3 | 20 | old substack URL 301s here |
| Hillel Wayne | `https://buttondown.com/hillelwayne/rss` | testing | 3 | 30 | property-based/formal |
| Mark Seemann | `https://blog.ploeh.dk/rss.xml` | testing | 3 | 10 | design/testability |
| James Bach | `https://www.satisfice.com/blog/feed` | testing | 2 | 10 | 🔴 see timeout note |
| Michael Lynch | `https://mtlynch.io/feed.xml` | dev | 3 | 255 | solo-founder revenue retrospectives |
| Jitbit | `https://www.jitbit.com/alexblog/rss/` | dev | 3 | 10 | bootstrapped SaaS |
| A Smart Bear | `https://longform.asmartbear.com/index.xml` | dev | 2 | 166 | excerpt-only feed |
| Plausible | `https://plausible.io/blog/feed.xml` | dev | 2 | 10 | |
| Justin Jackson | `https://justinjackson.ca/feed` | dev | 2 | 50 | `/feed.xml` 404s |
| AkitaOnRails | `https://www.akitaonrails.com/index.xml` | br | 3 | 20 | only verified individual PT-BR feed |
| Hipsters Ponto Tech | `https://www.hipsters.tech/feed/` | br | 3 | 10 | weekly, PT-BR, AI + BR regulatory |
| TabNews | `https://www.tabnews.com.br/recentes/rss` | br | 2 | 30 | 🔴 ~400-600 items/mo — needs a per-source cap |
| DEV braziliandevs | `https://dev.to/feed/tag/braziliandevs` | br | 1 | 12 | mediocre S/N but real |
| Creditas Tech | `https://medium.com/feed/creditas-tech` | br | 1 | 10 | ~1/mo |
| Nubank Building | `https://building.nubank.com/feed/` | br | 1 | 10 | Brazilian company, **English** |

## Caveats that must survive into any change

🔴 **James Bach timed out at the pipeline's default `NEWS_FETCH_TIMEOUT_MS=20000`
and succeeded at 60000.** Adding it without raising the timeout adds a feed that
fails every run. A slow feed and a dead feed produce the same log line.

🔴 **No first-party Anthropic feed exists.** `anthropic.com/rss.xml` 404s. The
mirror above is a third-party scraper we do not control; two other community
mirrors were checked and are stale by 5 and 9 months. The honest alternative is
scraping `anthropic.com/engineering` ourselves.

🔴 **TabNews out-posts everything else combined by roughly 100:1.** `weight`
biases the score; it does not cap intake. Adding TabNews without a per-source
item cap means the digest becomes TabNews.

🔴 **Brazilian corporate engineering blogs are dead as a category.** 18 were
opened; exactly one (Creditas) is PT-BR and posted within six months. iFood
(last 2025-11-06), PicPay (2026-02-23), Loft (2023-02), XP (2023-07), Pagar.me
(2021-11) all stopped. Nubank and Mercado Libre still post but switched to
English. **InfoQ Brasil serves valid RSS with zero items** — a shell feed.
Do not re-research this; it was searched thoroughly and the answer is no.

🔴 **No RSS exists for Brazilian regulators** (ANPD, Banco Central). Every
Plone-conventional path 404s. LGPD/Pix coverage has to come via Hipsters or
scraping.

🔴 **React has no official blog feed** (`react.dev/rss.xml` and `/blog/rss.xml`
both 404; a long-standing open issue). This Week In React is the substitute.

🔴 **`withastro/astro` releases.atom is a monorepo adapter-bump firehose** and
core releases do not appear in it. Use `astro.build/rss.xml`. Same for
`oven-sh/bun` (leaks internal CI tags) and `vitejs/vite`.

## Rejected after being checked

Dead or dormant: Dave Farley (2022-12), Dan North (2025-02), Enterprise
Craftsmanship (2023-03), Kent C. Dodds (2026-03, drifted off-topic), Gojko Adzic
(one post in two years), Chip Huyen (2025-01), Tiny Projects (2022-08), Boring
Rails (2025-12), Tailwind blog (one post in 16 months).

Broken: Indie Hackers (403), LangChain (returns HTML), vLLM, Modal, Braintrust,
Checkly, pganalyze, bytes.dev, `orm.drizzle.team/rss.xml`, Rocketseat
(connection refused), Alura (serves HTML), TecMundo (serves HTML).

Wrong shape: Thoughtworks Insights (consulting marketing + recruiting), DEV tags
`portugues`/`brasil` (single-author SEO slop), Baremetrics (content marketing),
epicweb.dev (course catalog), Jimmy Bogard (release announcements).
