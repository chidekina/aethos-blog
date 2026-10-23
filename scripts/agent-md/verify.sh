#!/usr/bin/env bash
set -euo pipefail

check_file() {
  if [[ ! -f "$1" ]]; then
    echo "FAIL: missing $1"
    return 1
  fi
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
vercel_json=${VERCEL_JSON:-"$script_dir/../../vercel.json"}
target=${1:-./dist}
if [[ "$target" == http://* || "$target" == https://* ]]; then
  shopt -s nullglob
  pages=("$script_dir"/../../dist/blog/*/index.html)
  [[ ${#pages[@]} -gt 0 ]] || { echo 'FAIL: no local dist post pages'; exit 1; }
  slug=${pages[0]%/index.html}
  slug=${slug##*/}
  headers=$(mktemp)
  body=$(mktemp)
  trap 'rm -f "$headers" "$body"' EXIT
  bypass=()
  if [[ -n "${VERCEL_AUTOMATION_BYPASS_SECRET:-}" ]]; then
    bypass=(-H "x-vercel-protection-bypass: $VERCEL_AUTOMATION_BYPASS_SECRET")
  fi
  first=1
  for suffix in '' /; do
    for accept in text/markdown default text/html; do
      args=()
      expected=text/html
      if [[ "$accept" != default ]]; then args=(-H "Accept: $accept"); fi
      if [[ "$accept" == text/markdown ]]; then expected=text/markdown; fi
      status=$(curl --silent --show-error --max-time 30 -D "$headers" -o "$body" \
        -w '%{http_code}' "${bypass[@]}" "${args[@]}" "${target%/}/blog/$slug$suffix")
      if [[ "$first" == 1 && ( "$status" == 401 || "$status" == 403 ) && ${#bypass[@]} == 0 ]]; then
        echo 'FAIL: preview is SSO-protected; set VERCEL_AUTOMATION_BYPASS_SECRET for live verification'
        exit 1
      fi
      first=0
      [[ "$status" == 200 ]] || { echo "FAIL: $accept $suffix HTTP $status"; exit 1; }
      if [[ "$expected" == text/markdown && $(head -n 1 "$body") != '# '* ]]; then
        echo 'FAIL: Markdown response body must start with # '; exit 1
      fi
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
if check_file "$target/blog/__agent_md_missing_control__.md" >/dev/null 2>&1; then
  echo 'FAIL: missing-file control unexpectedly exists'
  exit 1
fi
echo 'PASS: missing-file helper rejects bogus slug (negative control)'

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

python3 - "$vercel_json" <<'PY' || failed=1
import json, re, sys

try:
    config = json.load(open(sys.argv[1], encoding='utf-8'))
except (OSError, ValueError) as error:
    print(f'FAIL: vercel.json parses: {error}')
    sys.exit(1)
print('PASS: vercel.json parses')
failed = False
def check(condition, label):
    global failed
    print(('PASS: ' if condition else 'FAIL: ') + label)
    failed |= not condition

def matches(pattern, value):
    try:
        return re.fullmatch(pattern, value) is not None
    except (re.error, TypeError):
        return False

check('rewrites' not in config and 'headers' not in config, 'routes only (no top-level rewrites/headers)')
routes = config.get('routes', [])
filesystem = [i for i, rule in enumerate(routes) if rule.get('handle') == 'filesystem']
check(len(filesystem) == 1 and filesystem[0] == len(routes) - 1, 'filesystem handle last')
fs = filesystem[0] if filesystem else -1
negotiation = [(i, rule) for i, rule in enumerate(routes) if rule.get('has') and rule.get('dest')]
check(len(negotiation) == 1, 'Accept negotiation route')
for i, rule in negotiation:
    check(i < fs, 'negotiation before filesystem')
    check(rule.get('dest') == '/blog/$1.md' and not rule.get('continue'), 'negotiation destination and termination')
    conditions = rule.get('has', [])
    accept = [h for h in conditions if h.get('type') == 'header' and h.get('key', '').lower() == 'accept']
    check(len(conditions) == 1 and len(accept) == 1, 'Accept header condition')
    pattern = accept[0].get('value') if accept else None
    for value in ('text/markdown', 'text/markdown;charset=utf-8', 'text/markdown; charset=utf-8; q=0.5', 'text/html, text/markdown;q=0.8', '*/*, text/markdown'):
        check(matches(pattern, value), f'Accept regex matches {value}')
    for value in ('text/markdown;q=0', 'text/markdown; q=0.0', 'text/markdown;charset=utf-8;q=0', 'text/html', '*/*', 'text/markdownx'):
        check(not matches(pattern, value), f'Accept regex rejects {value}')
    ctype = [(j, r) for j, r in enumerate(routes) if r.get('has') and not r.get('dest')
             and r.get('headers', {}).get('Content-Type') == 'text/markdown; charset=utf-8'
             and r.get('has') == conditions and r.get('src') == rule.get('src')
             and r.get('continue') is True and j < i]
    check(len(ctype) == 1, 'Content-Type header route for rewritten URL before negotiation')
    for path in ('/blog/x', '/blog/x/'):
        check(matches(rule.get('src'), path), f'negotiation src matches {path}')
    for path in ('/blog/x.md', '/blog/', '/blog/a/b'):
        check(not matches(rule.get('src'), path), f'negotiation src rejects {path}')

header_routes = [(i, r) for i, r in enumerate(routes) if 'headers' in r]
check(bool(header_routes) and all(i < fs and r.get('continue') is True for i, r in header_routes),
      'header routes continue before filesystem')
check(all(i < n for i, _ in header_routes for n, _ in negotiation), 'headers before negotiation')
def header(path, key, value):
    return any(matches(rule.get('src'), path)
               and any(k.lower() == key.lower() and v == value for k, v in rule['headers'].items())
               for _, rule in header_routes)

for path in ('/blog/x', '/blog/x/'):
    check(header(path, 'Vary', 'Accept'), f'Vary: Accept HTML {path}')
check(header('/blog/x.md', 'Vary', 'Accept'), 'Vary: Accept Markdown')
check(header('/blog/x.md', 'Content-Type', 'text/markdown; charset=utf-8'), 'Markdown Content-Type')
check(any(rule.get('src') == '^/(.*)$'
          and rule['headers'].get('Content-Signal') == 'ai-train=no, search=yes, ai-input=yes'
          for _, rule in header_routes), 'global Content-Signal')
sys.exit(1 if failed else 0)
PY
if node -e "require.resolve('@vercel/routing-utils', {paths: [process.argv[1]]})" "$script_dir" >/dev/null 2>&1; then
  node "$script_dir/transform-check.mjs" "$vercel_json" || failed=1
elif [[ "${CI:-}" == true ]]; then
  echo 'FAIL: @vercel/routing-utils not installed (required in CI)'
  failed=1
else
  echo 'SKIP: @vercel/routing-utils not installed'
fi
exit "$failed"
