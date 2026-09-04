#!/usr/bin/env bash
# v2026.09.04
# Mutation harness for capture-published. Anchors are asserted before running:
# a mutation that misses its target leaves the suite green and reads as
# robustness, which has produced a false "verified" twice on this machine.
set -uo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/scripts/news/capture-published.mjs"
SUITE="$REPO/scripts/news/capture-published.test.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

base="$(bash "$SUITE" 2>&1 | tail -1)"; echo "baseline: $base"
grep -qE "(^|[^0-9])0 failed" <<<"$base" || { echo "FATAL: not green before mutating"; exit 1; }

mutate() {
  local name="$1" old="$2" new="$3" expect="$4"
  cp "$SRC" "$T/orig.mjs"
  python3 - "$SRC" "$old" "$new" <<'PY' || { cp "$T/orig.mjs" "$SRC"; echo "  ANCHOR MISSED — $name never reached the target"; return 1; }
import io,sys
p,old,new=sys.argv[1],sys.argv[2],sys.argv[3]
t=io.open(p,encoding='utf-8').read()
assert old in t, 'anchor absent'
io.open(p,'w',encoding='utf-8').write(t.replace(old,new,1))
PY
  local out; out="$(bash "$SUITE" 2>&1)"; cp "$T/orig.mjs" "$SRC"
  local failed; failed="$(grep '^  FAIL' <<<"$out" | sed 's/^  FAIL //' | tr '\n' ';')"
  grep -qE "(^|[^0-9])0 failed" <<<"$out" && { echo "  SURVIVED  $name"; return 1; }
  echo "  killed    $name"; echo "            fails: $failed"
  grep -qF "$expect" <<<"$failed" && echo "            expected arm" || { echo "            WRONG ARM"; return 1; }
}

RC=0
echo "M1 — the draft guard is disarmed"
mutate "M1 captures a draft as published" \
  "const isDraft = (mdx) => /^draft:\\s*true\\s*\$/m.test(mdx.split(/^---\$/m)[1] ?? '');" \
  "const isDraft = () => false;" \
  "draft capture exit 0 (expected 1)" || RC=1

echo "M2 — the published half is filled from the DRAFT instead of the post"
mutate "M2 pair collapses to one side" \
  "return { ...it, publishedEn: en, publishedPt: pt, keptByHuman: true };" \
  "return { ...it, publishedEn: it.summaryEn, publishedPt: it.summaryPt, keptByHuman: true };" \
  "published half is not the post body" || RC=1

echo "M3 — a parser that matches nothing reports a clean capture"
mutate "M3 zero matches read as all-cut" \
  "if (matched === 0) {" \
  "if (false) {" \
  "zero-match exit 0 (expected 2)" || RC=1

echo
after="$(bash "$SUITE" 2>&1 | tail -1)"; echo "restored: $after"
grep -qE "(^|[^0-9])0 failed" <<<"$after" || { echo "FATAL: source not restored"; exit 1; }
exit $RC
