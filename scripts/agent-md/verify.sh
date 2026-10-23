#!/usr/bin/env bash
set -euo pipefail

check_file() {
  if [[ ! -f "$1" ]]; then
    echo "FAIL: missing $1"
    return 1
  fi
}

target=${1:-./dist}
if [[ "$target" == http://* || "$target" == https://* ]]; then
  shopt -s nullglob
  pages=(dist/blog/*/index.html)
  [[ ${#pages[@]} -gt 0 ]] || { echo 'FAIL: no local dist post pages'; exit 1; }
  slug=${pages[0]%/index.html}
  slug=${slug##*/}
  headers=$(mktemp)
  trap 'rm -f "$headers"' EXIT
  for suffix in '' /; do
    for accept in text/markdown default text/html; do
      args=()
      expected=text/html
      if [[ "$accept" != default ]]; then args=(-H "Accept: $accept"); fi
      if [[ "$accept" == text/markdown ]]; then expected=text/markdown; fi
      status=$(curl --silent --show-error --max-time 30 -D "$headers" -o /dev/null \
        -w '%{http_code}' "${args[@]}" "${target%/}/blog/$slug$suffix")
      [[ "$status" == 200 ]] || { echo "FAIL: $accept $suffix HTTP $status"; exit 1; }
      python3 - "$headers" "$expected" <<'PY'
import re, sys
headers = open(sys.argv[1]).read().lower()
assert re.search(r'^content-type:\s*' + re.escape(sys.argv[2]) + r'(?:;|\s|$)', headers, re.M), headers
assert re.search(r'^vary:.*\baccept\b', headers, re.M), headers
PY
      echo "PASS: /blog/$slug$suffix Accept=$accept: 200, $expected, Vary: Accept"
    done
  done
  exit 0
fi

# Negative control exercises the same helper used for every real twin.
if check_file "$target/blog/__agent_md_missing_control__.md"; then
  echo 'FAIL: missing-file control unexpectedly exists'
  exit 1
fi
echo 'PASS: missing-file helper rejects bogus slug (expected failure above)'

failed=0
shopt -s nullglob
pages=("$target"/blog/*/index.html)
twins=("$target"/blog/*.md)
if [[ ${#pages[@]} -gt 0 && ${#pages[@]} -eq ${#twins[@]} ]]; then
  echo "PASS: ${#pages[@]} HTML posts, ${#twins[@]} Markdown twins"
else
  echo "FAIL: ${#pages[@]} HTML posts, ${#twins[@]} Markdown twins"
  failed=1
fi
for page in "${pages[@]}"; do
  twin="${page%/index.html}.md"
  if check_file "$twin"; then
    if [[ $(head -n 1 "$twin") == '# '* ]]; then
      echo "PASS: $twin starts with # "
    else
      echo "FAIL: $twin must start with # "
      failed=1
    fi
  else
    failed=1
  fi
done

python3 - <<'PY' || failed=1
import json, sys

try:
    config = json.load(open('vercel.json', encoding='utf-8'))
except (OSError, ValueError) as error:
    print(f'FAIL: vercel.json parses: {error}')
    sys.exit(1)
print('PASS: vercel.json parses')
failed = False
def check(condition, label):
    global failed
    print(('PASS: ' if condition else 'FAIL: ') + label)
    failed |= not condition

for source in ('/blog/:slug([^/.]+)', '/blog/:slug([^/.]+)/'):
    check(any(rule.get('source') == source
              and rule.get('destination') == '/blog/:slug.md'
              and rule.get('has') == [{'type': 'header', 'key': 'accept', 'value': '(.*)text/markdown(.*)'}]
              for rule in config.get('rewrites', [])), f'Accept rewrite {source}')

def header(source, key, value):
    return any(rule.get('source') == source
               and any(h.get('key', '').lower() == key.lower() and h.get('value') == value
                       for h in rule.get('headers', []))
               for rule in config.get('headers', []))

for source in ('/blog/:slug([^/.]+)', '/blog/:slug([^/.]+)/', '/blog/:slug.md'):
    check(header(source, 'Vary', 'Accept'), f'Vary: Accept {source}')
check(header('/blog/:slug.md', 'Content-Type', 'text/markdown; charset=utf-8'), 'Markdown Content-Type')
check(header('/(.*)', 'Content-Signal', 'ai-train=no, search=yes, ai-input=yes'), 'global Content-Signal')
sys.exit(1 if failed else 0)
PY
exit "$failed"
