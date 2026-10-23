#!/usr/bin/env bash
set -euo pipefail

verify="$(cd "$(dirname "$0")" && pwd)/verify.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/dist/blog/example"
printf '<h1>Example</h1>\n' > "$fixture/dist/blog/example/index.html"
printf '# Example\n\nPost body.\n' > "$fixture/dist/blog/example.md"
cd "$fixture"
python3 - <<'PY'
import json
config = {
    'rewrites': [
        {'source': source, 'destination': '/blog/:slug.md',
         'has': [{'type': 'header', 'key': 'accept', 'value': '(.*)text/markdown(.*)'}]}
        for source in ('/blog/:slug([^/.]+)', '/blog/:slug([^/.]+)/')
    ],
    'headers': [
        {'source': source, 'headers': [{'key': 'Vary', 'value': 'Accept'}]}
        for source in ('/blog/:slug([^/.]+)', '/blog/:slug([^/.]+)/', '/blog/:slug.md')
    ] + [
        {'source': '/blog/:slug.md', 'headers': [{'key': 'Content-Type', 'value': 'text/markdown; charset=utf-8'}]},
        {'source': '/(.*)', 'headers': [{'key': 'Content-Signal', 'value': 'ai-train=no, search=yes, ai-input=yes'}]},
    ],
}
with open('vercel.json', 'w') as file:
    json.dump(config, file)
PY

bash "$verify" dist
echo 'PASS: valid fixture accepted'
mv dist/blog/example.md saved.md
if bash "$verify" dist > failure.log 2>&1; then
  echo 'FAIL: missing Markdown twin accepted'; exit 1
fi
grep -q 'FAIL: missing dist/blog/example.md' failure.log
echo 'PASS: missing Markdown twin rejected'
mv saved.md dist/blog/example.md
python3 - <<'PY'
import json
config = json.load(open('vercel.json'))
config['headers'] = [rule for rule in config['headers'] if rule['source'] != '/(.*)']
with open('vercel.json', 'w') as file:
    json.dump(config, file)
PY
if bash "$verify" dist > failure.log 2>&1; then
  echo 'FAIL: missing Content-Signal accepted'; exit 1
fi
grep -q 'FAIL: global Content-Signal' failure.log
echo 'PASS: missing Content-Signal rejected'
