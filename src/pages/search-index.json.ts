import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';

/**
 * Full-text search index, emitted as a static file at build time.
 *
 * It is a SEPARATE file rather than markup on the homepage on purpose. The
 * bodies total ~281 KB against a ~142 KB homepage, so inlining them would
 * roughly triple the page for every visitor to serve the few who search. The
 * index is fetched once, lazily, when a reader first focuses the search box.
 *
 * Metadata-only search was measured and rejected: of 20 plausible query terms,
 * 9 — `typescript`, `deploy`, `migration`, `cache`, `webhook`, `neon`, `rss`,
 * `stripe`, `benchmark` — appear only in post bodies. A search that answers
 * "no posts match" for `typescript` on this blog is worse than no search.
 */

/** Strip MDX down to prose. Imperfect on purpose: this feeds a substring match,
 *  not a renderer, so leftover punctuation costs nothing and a missing word costs
 *  a false "no results". When unsure, keep the text. */
function toPlainText(body: string): string {
  return body
    .replace(/```[\s\S]*?```/g, ' ')       // fenced code — the noisiest false-positive source
    .replace(/`[^`\n]*`/g, ' ')            // inline code
    .replace(/^import\s.+$/gm, ' ')        // MDX imports
    .replace(/<[^>]+>/g, ' ')              // JSX and HTML tags
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')  // links/images — keep the label, drop the URL
    .replace(/[#>*_~|-]+/g, ' ')           // markdown punctuation
    .replace(/\s+/g, ' ')
    .trim();
}

export const GET: APIRoute = async () => {
  const posts = await getCollection('blog', ({ data }) => !data.draft);

  const index = posts
    .sort((a, b) => b.data.date.getTime() - a.data.date.getTime())
    .map((post) => ({
      slug: post.slug,
      lang: post.data.lang,
      // Everything a query is matched against, pre-lowercased so the browser
      // does not re-lowercase ~280 KB on every keystroke.
      text: [
        post.data.title,
        post.data.description,
        post.data.tags.join(' '),
        toPlainText(post.body),
      ].join(' ').toLowerCase(),
    }));

  return new Response(JSON.stringify(index), {
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'public, max-age=3600',
    },
  });
};
