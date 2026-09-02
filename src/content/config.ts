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
    translationSlug: z.string().optional(),
    draft: z.boolean().optional().default(false),
  }),
});

/**
 * Reader recommendations. One JSON file per entry, added via PR after a
 * reader opens the "Recommend" issue form. See docs/RECOMMENDATIONS.md.
 * Category values are the tabs on /recommendations — adding one here without
 * adding it to CATEGORIES in src/pages/recommendations.astro hides the entry.
 */
const recommendations = defineCollection({
  type: 'data',
  schema: z.object({
    title: z.string(),
    url: z.string().url(),
    category: z.enum(['youtube', 'spotify', 'article', 'site', 'newsletter', 'course', 'book', 'tool']),
    description: z.string().max(280),
    author: z.string().optional(),
    lang: z.enum(['en', 'pt', 'other']).default('en'),
    tags: z.array(z.string()).default([]),
    recommendedBy: z.string(),
    addedAt: z.coerce.date(),
  }),
});

export const collections = { blog, recommendations };
