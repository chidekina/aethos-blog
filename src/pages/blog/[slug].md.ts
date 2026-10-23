import { getCollection, type CollectionEntry } from 'astro:content';
import type { APIRoute } from 'astro';

export async function getStaticPaths() {
  const posts = await getCollection('blog', ({ data }) => !data.draft);
  return posts.map((post) => ({ params: { slug: post.slug }, props: { post } }));
}

// MDX module statements are blocks separated by blank lines. Keep fenced examples.
function stripMdxStatements(body: string): string {
  let fence = '';
  let statement = false;
  return body.split('\n').filter((line) => {
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (fence) {
      if (marker && marker[1][0] === fence[0]
          && marker[1].length >= fence.length && line.trim() === marker[1]) fence = '';
      return true;
    }
    if (statement) {
      if (!line.trim()) statement = false;
      return !statement;
    }
    if (marker) fence = marker[1];
    if (!fence && /^(?:import|export)\s/.test(line)) {
      statement = true;
      return false;
    }
    return true;
  }).join('\n');
}

export const GET: APIRoute = ({ props }) => {
  const post = props.post as CollectionEntry<'blog'>;
  const { title, date, lang, tags, description } = post.data;
  return new Response([
    `# ${title}`,
    `${date.toISOString().split('T')[0]} · ${lang} · ${tags.join(', ')}`,
    description,
    stripMdxStatements(post.body),
  ].join('\n\n'));
};
