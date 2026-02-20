import { defineCollection, z } from 'astro:content';

const blog = defineCollection({
  type: 'content',
  schema: z.object({
    title: z.string(),
    description: z.string(),
    date: z.coerce.date(),
    lang: z.enum(['en', 'pt']),
    tags: z.array(z.string()),
    series: z.string().optional(),
    draft: z.boolean().optional().default(false),
  }),
});

export const collections = { blog };
