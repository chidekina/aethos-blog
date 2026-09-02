# Recommendations — how a reader suggestion becomes a page entry

`/recommendations` lists podcasts, videos, articles, sites, newsletters,
courses, books and tools that readers vouched for, grouped by category.

## The flow

```
reader clicks "Recommend something"
        │
        ▼
GitHub issue form (.github/ISSUE_TEMPLATE/recommendation.yml)
        │   you read it; approve or close
        ▼
node scripts/recommendations/from-issue.mjs <issue-number>
        │   writes src/content/recommendations/<slug>.json
        ▼
bun run build   ← the zod schema is the gate
        │
        ▼
land it on main → Vercel → live, credited to the reader's handle
```

There is no form endpoint and no database because the site has no server (see
[`ARCHITECTURE.md`](ARCHITECTURE.md)). The trade is deliberate: submitting
requires a GitHub account, and in exchange there is no spam surface, no
moderation queue to build, no runtime cost, and every entry arrives with a real
identity attached to credit.

## Approving one

```bash
gh issue list --label recommendation
node scripts/recommendations/from-issue.mjs 42 --dry-run   # see the entry, write nothing
node scripts/recommendations/from-issue.mjs 42             # write the file
bun run build
gh issue close 42 --comment "Live at https://blog.aethostech.com.br/recommendations"
```

Exit codes: `0` written · `1` rejected (bad or duplicate input — the message
names every problem at once) · `2` broken instrument (`gh` missing, not
authenticated, issue not found). The script writes one file and nothing else:
it does not stage, does not land anything, does not close the issue. Approval
stays a human act.

## Adding one by hand

Drop a JSON file in `src/content/recommendations/`. The filename is the slug and
is not used anywhere else.

```json
{
  "title": "Latent Space",
  "url": "https://www.latent.space/",
  "category": "newsletter",
  "description": "One or two sentences on why it is worth someone's time. Max 280 characters.",
  "author": "swyx & Alessio",
  "lang": "en",
  "tags": ["ai", "engineering"],
  "recommendedBy": "chidekina",
  "addedAt": "2026-09-02"
}
```

`recommendedBy` is a GitHub handle, rendered as a link to that profile. `author`
is optional; everything else is required. `description` is capped at 280
characters by the schema.

## Categories

`youtube` · `spotify` · `article` · `site` · `newsletter` · `course` · `book` ·
`tool`

Adding a category means editing **three** places together:

1. the `category` enum in `src/content/config.ts`,
2. the `CATEGORIES` array in `src/pages/recommendations.astro` (label + icon),
3. the `dropdown` options in `.github/ISSUE_TEMPLATE/recommendation.yml`.

Miss the second and the build stays green while the entry renders no tab and
becomes unreachable. Tabs for categories with zero entries are hidden
automatically, so a new category is invisible until its first entry lands.

## What to accept

The page is a recommendation list, not a directory. Rough bar:

- Would you send this link to a working developer without a caveat?
- Is the description about *why it is useful*, rather than what it is?
- Is it still maintained, or recent enough to matter?

Reject vendor marketing, affiliate links, and anything whose description is the
product's own tagline. Rewriting a weak description while approving is fine and
expected — credit the reader either way.
