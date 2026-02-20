import { getCollection } from 'astro:content';
import satori from 'satori';
import { Resvg } from '@resvg/resvg-js';
import type { APIContext } from 'astro';
import fs from 'node:fs';
import path from 'node:path';

export async function getStaticPaths() {
  const posts = await getCollection('blog', ({ data }) => !data.draft);
  return posts.map((post) => ({ params: { slug: post.slug }, props: { post } }));
}

async function loadFont(): Promise<ArrayBuffer> {
  // satori supports TTF/OTF/WOFF (not woff2)
  const woffPath = path.join(process.cwd(), 'node_modules/@fontsource/inter/files/inter-latin-700-normal.woff');
  if (fs.existsSync(woffPath)) {
    return fs.readFileSync(woffPath).buffer as ArrayBuffer;
  }
  // Fallback: try 400 weight
  const woff400 = path.join(process.cwd(), 'node_modules/@fontsource/inter/files/inter-latin-400-normal.woff');
  if (fs.existsSync(woff400)) {
    return fs.readFileSync(woff400).buffer as ArrayBuffer;
  }
  throw new Error('Inter font not found. Run: bun add @fontsource/inter');
}

export async function GET({ props }: APIContext & { props: { post: Awaited<ReturnType<typeof getCollection<'blog'>>>[number] } }) {
  const { post } = props;
  const font = await loadFont();

  const svg = await satori(
    {
      type: 'div',
      props: {
        style: {
          width: '1200px',
          height: '630px',
          background: 'hsl(0, 0%, 4%)',   /* --color-background */
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'space-between',
          padding: '64px',
          fontFamily: 'Inter',
          borderLeft: '3px solid hsl(0, 0%, 26%)',  /* subtle border like LP */
        },
        children: [
          {
            type: 'div',
            props: {
              style: { display: 'flex', flexDirection: 'column', gap: '20px' },
              children: [
                /* Breadcrumb: Aethos Tech / Blog */
                {
                  type: 'div',
                  props: {
                    style: { display: 'flex', alignItems: 'center', gap: '10px' },
                    children: [
                      {
                        type: 'span',
                        props: { style: { color: 'hsl(0, 0%, 85%)', fontSize: '16px', fontWeight: '600', letterSpacing: '-0.01em' }, children: 'Aethos Tech' },
                      },
                      { type: 'span', props: { style: { color: 'hsl(0, 0%, 30%)', fontSize: '16px' }, children: '/' } },
                      {
                        type: 'span',
                        props: { style: { color: 'hsl(0, 0%, 50%)', fontSize: '16px' }, children: 'Blog' },
                      },
                    ],
                  },
                },
                /* Post title */
                {
                  type: 'h1',
                  props: {
                    style: { color: 'hsl(0, 0%, 95%)', fontSize: '52px', fontWeight: '700', lineHeight: '1.2', margin: '0', letterSpacing: '-0.02em' },
                    children: post.data.title,
                  },
                },
              ],
            },
          },
          /* Footer row */
          {
            type: 'div',
            props: {
              style: { display: 'flex', alignItems: 'center', gap: '16px' },
              children: [
                {
                  type: 'span',
                  props: {
                    style: { color: 'hsl(0, 0%, 50%)', fontSize: '16px' },
                    children: post.data.date.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' }),
                  },
                },
                { type: 'span', props: { style: { color: 'hsl(0, 0%, 25%)', fontSize: '16px' }, children: '·' } },
                {
                  type: 'span',
                  props: {
                    style: {
                      fontSize: '13px', fontWeight: '600', padding: '3px 9px', borderRadius: '4px',
                      color: 'hsl(0, 0%, 70%)',
                      background: 'hsl(0, 0%, 12%)',
                      border: '1px solid hsl(0, 0%, 20%)',
                    },
                    children: post.data.lang.toUpperCase(),
                  },
                },
                ...post.data.tags.slice(0, 3).map((tag) => ({
                  type: 'span',
                  props: {
                    style: {
                      fontSize: '13px', color: 'hsl(0, 0%, 50%)',
                      background: 'hsl(0, 0%, 10%)',
                      border: '1px solid hsl(0, 0%, 18%)',
                      borderRadius: '4px', padding: '3px 8px',
                    },
                    children: `#${tag}`,
                  },
                })),
              ],
            },
          },
        ],
      },
    },
    {
      width: 1200,
      height: 630,
      fonts: [{ name: 'Inter', data: font, weight: 400, style: 'normal' }],
    }
  );

  const resvg = new Resvg(svg);
  const pngData = resvg.render();
  const pngBuffer = pngData.asPng();

  return new Response(pngBuffer, {
    headers: { 'Content-Type': 'image/png' },
  });
}
