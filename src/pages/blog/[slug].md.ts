import { getCollection, type CollectionEntry } from 'astro:content';
import type { APIRoute } from 'astro';
import { stripMdxStatements } from '../../lib/strip-mdx';

export async function getStaticPaths() {
  const posts = await getCollection('blog', ({ data }) => !data.draft);
  return posts.map((post) => ({ params: { slug: post.slug }, props: { post } }));
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
