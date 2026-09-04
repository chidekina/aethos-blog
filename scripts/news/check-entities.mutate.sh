#!/usr/bin/env bash
# v2026.09.04
# Mutation harness for check-entities. Each mutation must turn the suite RED,
# and the failure sets must be DISJOINT — a mutation that kills everything
# proves only that the suite runs, not that any particular arm has teeth.
#
# 🔴 Every mutation asserts its own anchor before running. A mutation that does
# not reach the target leaves the suite green and reads as robustness; that has
# happened twice on this machine and cost a false "verified" both times.
set -uo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/scripts/news/check-entities.mjs"
SUITE="$REPO/scripts/news/check-entities.test.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

baseline="$(bash "$SUITE" 2>&1 | tail -1)"
echo "baseline: $baseline"
grep -qF "0 failed" <<<"$baseline" || { echo "FATAL: suite is not green before mutating"; exit 1; }

mutate() { # name  old  new  expect-substring
  local name="$1" old="$2" new="$3" expect="$4"
  cp "$SRC" "$T/orig.mjs"
  python3 - "$SRC" "$old" "$new" <<'PY' || { cp "$T/orig.mjs" "$SRC"; echo "  ANCHOR MISSED — mutation never reached the target"; return 1; }
import io,sys
p,old,new=sys.argv[1],sys.argv[2],sys.argv[3]
t=io.open(p,encoding='utf-8').read()
assert old in t, 'anchor absent'
io.open(p,'w',encoding='utf-8').write(t.replace(old,new,1))
PY
  local out; out="$(bash "$SUITE" 2>&1)"
  cp "$T/orig.mjs" "$SRC"
  local failed; failed="$(grep '^  FAIL' <<<"$out" | sed 's/^  FAIL //' | tr '\n' ';')"
  if grep -qF "0 failed" <<<"$out"; then
    echo "  SURVIVED  $name  — the suite does not test this"
    return 1
  fi
  echo "  killed    $name"
  echo "            fails: $failed"
  grep -qF "$expect" <<<"$failed" \
    && echo "            and it is the expected arm" \
    || { echo "            WRONG ARM — expected: $expect"; return 1; }
}

RC=0
echo "M1 — the EN→PT lane never finds anything missing"
mutate "M1 translation blind" \
  "strong: tok.strong.filter((tokenText) => !survived(tokenText))," \
  "strong: []," \
  "the failure this check exists for went unseen" || RC=1

echo "M2 — a plain capital is promoted to strong"
mutate "M2 over-broad classifier" \
  "if (/^\\p{Lu}/u.test(word) && !clauseInitial && !WEAK_STOPWORDS.has(word.toLowerCase())) return 'weak';" \
  "if (/^\\p{Lu}/u.test(word) && !clauseInitial && !WEAK_STOPWORDS.has(word.toLowerCase())) return 'strong';" \
  "over-broad classifier" || RC=1

echo "M3 — nothing checkable reads as a pass"
mutate "M3 blind run scored clean" \
  "  const status = checked === 0
    ? 'no-tokens'
    : (missing.strong.length + missing.numbers.length > 0 ? 'fail' : 'pass');

  return { status, checked, tokens: tok, missing };" \
  "  const status = missing.strong.length + missing.numbers.length > 0 ? 'fail' : 'pass';

  return { status, checked, tokens: tok, missing };" \
  "blind run reported as pass" || RC=1

echo "M4 — numbers compared with their separators intact"
mutate "M4 locale false positive" \
  "const digitsOf = (n) => n.replace(/[.,\\s]/g, '');" \
  "const digitsOf = (n) => n;" \
  "false positive on locale-correct number formatting" || RC=1

echo
after="$(bash "$SUITE" 2>&1 | tail -1)"
echo "restored: $after"
grep -qF "0 failed" <<<"$after" || { echo "FATAL: source not restored cleanly"; exit 1; }
exit $RC
