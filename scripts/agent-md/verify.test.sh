#!/usr/bin/env bash
set -euo pipefail

verify="$(cd "$(dirname "$0")" && pwd)/verify.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export VERCEL_JSON="$fixture/vercel.json"
mkdir -p "$fixture/dist/blog/example"
printf '<h1>Example</h1>\n' > "$fixture/dist/blog/example/index.html"
printf '# Example\n\nPost body.\n' > "$fixture/dist/blog/example.md"
python3 - "$VERCEL_JSON" "$(cd "$(dirname "$0")/../.." && pwd)/vercel.json" <<'PY'
import json, sys
ACCEPT = json.load(open(sys.argv[2]))['routes'][4]['has'][0]['value']  # the real, shipped pattern
config = {'routes': [
    {'src': r'^/blog/[^/.]+/?$', 'headers': {'Vary': 'Accept'}, 'continue': True},
    {'src': r'^/blog/[^/.]+\.md$', 'headers': {'Vary': 'Accept', 'Content-Type': 'text/markdown; charset=utf-8'}, 'continue': True},
    {'src': '^/(.*)$', 'headers': {'Content-Signal': 'ai-train=no, search=yes, ai-input=yes'}, 'continue': True},
    {'src': r'^/blog/([^/.]+)/?$', 'has': [{'type': 'header', 'key': 'accept', 'value': ACCEPT}], 'headers': {'Content-Type': 'text/markdown; charset=utf-8'}, 'continue': True},
    {'src': r'^/blog/([^/.]+)/?$', 'has': [{'type': 'header', 'key': 'accept', 'value': ACCEPT}], 'dest': '/blog/$1.md'},
    {'handle': 'filesystem'},
]}
with open(sys.argv[1], 'w') as file:
    json.dump(config, file)
PY
cp "$VERCEL_JSON" "$fixture/valid.json"
# Deliberately run outside both the repository and the fixture directory.
cd /tmp
bash "$verify" "$fixture/dist"
echo 'PASS: valid fixture accepted'

reject() {
  local label=$1 expected=$2
  if bash "$verify" "$fixture/dist" > "$fixture/failure.log" 2>&1; then
    echo "FAIL: $label accepted"; exit 1
  fi
  if ! grep -Fq "FAIL: $expected" "$fixture/failure.log"; then
    cat "$fixture/failure.log"
    echo "FAIL: $label missing specific failure: $expected"; exit 1
  fi
  echo "PASS: $label rejected (FAIL: $expected)"
}

for mutation in deleted after vary signal qzero narrow noctype; do
  python3 - "$fixture/valid.json" "$VERCEL_JSON" "$mutation" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
routes = config['routes']
mutation = sys.argv[3]
if mutation == 'deleted': del routes[4]
if mutation == 'after': routes.append(routes.pop(4))
if mutation == 'vary': del routes[0]['headers']['Vary']
if mutation == 'signal': del routes[2]
if mutation in ('qzero', 'narrow'):
    narrow = '(.*)text/markdown(.*)' if mutation == 'qzero' else r'(?:^|.*[,\s])text/markdown(?:\s*(?:,|;\s*q=(?:1|0?\.[0-9]*[1-9][0-9]*)|$).*)?$'
    for index in (3, 4): routes[index]['has'][0]['value'] = narrow
if mutation == 'noctype': del routes[3]
with open(sys.argv[2], 'w') as file: json.dump(config, file)
PY
  case "$mutation" in
    deleted) reject 'missing negotiation' 'Accept negotiation route' ;;
    after) reject 'late negotiation' 'negotiation before filesystem' ;;
    vary) reject 'missing Vary' 'Vary: Accept HTML' ;;
    signal) reject 'missing Content-Signal' 'global Content-Signal' ;;
    qzero) reject 'q=0 regex' 'Accept regex rejects text/markdown;q=0' ;;
    narrow) reject 'narrow regex' 'Accept regex matches text/markdown;charset=utf-8' ;;
    noctype) reject 'missing rewritten Content-Type route' 'Content-Type header route for rewritten URL before negotiation' ;;
  esac
done
cp "$fixture/valid.json" "$VERCEL_JSON"
printf 'Example\n' > "$fixture/dist/blog/example.md"
reject 'invalid Markdown heading' "$fixture/dist/blog/example.md must start with # "
printf '# Example\n' > "$fixture/dist/blog/example.md"
mkdir -p "$fixture/dist/blog/extra"
printf '<h1>Extra</h1>\n' > "$fixture/dist/blog/extra/index.html"
reject 'page/twin mismatch' '2 HTML posts, 1 Markdown twins'
rm -r "$fixture/dist/blog/extra"
mv "$fixture/dist/blog/example.md" "$fixture/saved.md"
reject 'missing Markdown twin' "missing $fixture/dist/blog/example.md"
