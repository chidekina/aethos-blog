import assert from 'node:assert/strict';
import { stripMdxStatements } from './strip-mdx';

for (const fence of ['```', '~~~~']) {
  const body = `${fence}export\nexport const example = 1;\nimport X from 'y'\n${fence}\nProse`;
  assert.equal(stripMdxStatements(body), body, `${fence} fenced examples stay intact`);
}
assert.equal(stripMdxStatements("import X from 'y'\n\nProse"), '\nProse');
assert.equal(stripMdxStatements("import {\n  X,\n  Y\n} from 'y'\n\nProse"), '\nProse');
assert.equal(stripMdxStatements('export const value = {\n  x: 1\n}\n\nProse'), '\nProse');
// A terminated statement must not consume adjacent prose (the old blank-line-only rule did).
for (const statement of ["import X from 'y'", 'import X from "y";', 'export const x = 1;']) {
  assert.equal(stripMdxStatements(`${statement}\nAdjacent prose`), 'Adjacent prose');
}
assert.equal(stripMdxStatements("import {\n  X\n} from 'y';\nAdjacent prose"), 'Adjacent prose');
process.stdout.write('PASS: MDX statements stripped; adjacent prose and backtick/tilde fences preserved\n');
