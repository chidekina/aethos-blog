import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

// createRequire also supports the optional package supplied through NODE_PATH.
const { getTransformedRoutes } = createRequire(import.meta.url)('@vercel/routing-utils');
const configPath = process.argv[2] ?? fileURLToPath(new URL('../../vercel.json', import.meta.url));
const { routes, error } = getTransformedRoutes(JSON.parse(readFileSync(configPath, 'utf8')));
assert.ifError(error);
assert.ok(routes?.length, 'transformed routes exist');
const negotiation = routes.findIndex((route) => route.has?.some((h) => h.key === 'accept'));
const filesystem = routes.findIndex((route) => route.handle === 'filesystem');
assert.ok(negotiation >= 0 && negotiation < filesystem, 'negotiation precedes filesystem');
assert.equal(routes[negotiation].continue, undefined, 'negotiation terminates routing');

// Evaluate the transformed header prefix up to the terminating rewrite. Headers
// accumulated by continue routes must still be present when the destination wins.
function response(path, accept) {
  const headers = {};
  for (const route of routes) {
    if (route.handle) break;
    const match = new RegExp(route.src).exec(path);
    if (!match) continue;
    if (route.has && !route.has.every((h) => h.type === 'header' && h.key === 'accept'
      && new RegExp(`^(?:${h.value})$`).test(accept))) continue;
    Object.assign(headers, route.headers);
    if (route.dest && !route.continue) {
      return { dest: route.dest.replace(/\$(\d+)/g, (_, index) => match[Number(index)]), headers };
    }
    assert.equal(route.continue, true, 'header routes continue');
  }
  return { dest: path, headers };
}
for (const path of ['/blog/x', '/blog/x/']) {
  const result = response(path, 'text/markdown');
  assert.equal(result.dest, '/blog/x.md');
  assert.equal(result.headers.Vary, 'Accept', 'Vary survives terminating rewrite');
  assert.equal(result.headers['Content-Signal'], 'ai-train=no, search=yes, ai-input=yes', 'Content-Signal survives terminating rewrite');
  for (const accept of ['text/markdown;q=0', 'text/html', '*/*']) {
    assert.equal(response(path, accept).dest, path, `${accept} does not rewrite`);
  }
}
const markdown = response('/blog/x.md', '*/*');
assert.equal(markdown.headers.Vary, 'Accept');
assert.equal(markdown.headers['Content-Type'], 'text/markdown; charset=utf-8');
assert.equal(markdown.headers['Content-Signal'], 'ai-train=no, search=yes, ai-input=yes');
console.log('PASS: routing-utils transform; negotiation before filesystem; continue headers retained at rewrite');
