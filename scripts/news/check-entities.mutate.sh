#!/usr/bin/env bash
# v2026.09.04
# Mutation harness for check-entities. Each mutation must turn the suite RED,
# and the failure sets must be DISJOINT — a mutation that kills everything
# proves only that the suite runs, not that any particular arm has teeth.
#
# 🔴 Every mutation asserts its own anchor before running. A mutation that does
# not reach the target leaves the suite green and reads as robustness; that has
# happened twice on this machine and cost a false "verified" both times.
#
# 🔴 The green test is `grep -qE "(^|[^0-9])0 failed"`, never `grep -qF "0 failed"`.
# Measured 2026-09-04: the fixed-string form matches "10 failed" by substring, so
# a mutation that killed TEN assertions was reported as SURVIVED. Applied by hand
# the same mutation turned the suite red immediately. The harness was lying in the
# one direction that matters — it under-reports the suite's teeth, so you go add
# assertions that already exist, or you weaken code believing it is untested.
set -uo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/scripts/news/check-entities.mjs"
SUITE="$REPO/scripts/news/check-entities.test.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

baseline="$(bash "$SUITE" 2>&1 | tail -1)"
echo "baseline: $baseline"
grep -qE "(^|[^0-9])0 failed" <<<"$baseline" || { echo "FATAL: suite is not green before mutating"; exit 1; }

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
  if grep -qE "(^|[^0-9])0 failed" <<<"$out"; then
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
  "    strong: tok.strong.filter((tokenText) => !groundedIn(tokenText, ptLower))," \
  "strong: []," \
  "the failure this check exists for went unseen" || RC=1

echo "M2 — a plain capital is promoted to strong"
mutate "M2 over-broad classifier" \
  "if (/^\\p{Lu}/u.test(word) && !clauseInitial && !WEAK_STOPWORDS.has(word.toLowerCase())) return 'weak';" \
  "if (/^\\p{Lu}/u.test(word) && !clauseInitial && !WEAK_STOPWORDS.has(word.toLowerCase())) return 'strong';" \
  "over-broad classifier" || RC=1

echo "M3 — nothing checkable reads as a pass"
# Re-anchored 2026-09-09: the status expression grew a third term when the
# relation lane landed, and this mutation stopped reaching it. The harness said
# ANCHOR MISSED rather than SURVIVED, which is the only reason it was noticed —
# a harness that reported a missed anchor as a green run would have retired a
# live assertion in silence.
mutate "M3 blind run scored clean" \
  "    : (checked === 0 ? 'no-tokens' : 'pass');

  return { status, checked, relationsChecked: rel.comparable, tokens: tok, missing };" \
  "    : 'pass';

  return { status, checked, relationsChecked: rel.comparable, tokens: tok, missing };" \
  "blind run reported as pass" || RC=1

echo "M4 — numbers compared with their separators intact"
mutate "M4 locale false positive" \
  "const digitsOf = (n) => n.replace(/[.,\\s]/g, '');" \
  "const digitsOf = (n) => n;" \
  "false positive on locale-correct number formatting" || RC=1

echo "M5 — declared-absent grounds collapse back into 'broken'"
mutate "M5 backfilled record screams exit 2" \
  "  if (item.sourceExcerpt === null) {" \
  "  if (false) {" \
  "declared absence read as a fault" || RC=1

echo "M6 — a record MISSING the key degrades to the headline instead of refusing"
mutate "M6 verdict from a degraded ground" \
  "  if (item.sourceExcerpt === undefined) {" \
  "  if (false) {" \
  "malformed record excused as no-ground" || RC=1

echo "M7 — the tautology guard is removed, so a self-grounded summary scores"
mutate "M7 tautology reported as a pass" \
  "  if (norm(hay).includes(norm(textCmp)) && norm(textCmp).length > 0) {" \
  "  if (false) {" \
  "tautology reported as a measurement" || RC=1

echo "M8 — the tautology guard eats everything"
mutate "M8 guard too broad" \
  "  if (norm(hay).includes(norm(textCmp)) && norm(textCmp).length > 0) {" \
  "  if (true) {" \
  "the tautology rule swallowed a real check" || RC=1

echo "M9 — the map goes one way only (the state this shipped in for a session)"
mutate "M9 half-fixed map" \
  "  TRANSLATION_EQUIVALENTS.set(b, [...(TRANSLATION_EQUIVALENTS.get(b) ?? []), a]);" \
  "  void b;" \
  "one-way map: PT→source still false-positives" || RC=1

echo "M10 — the grounding lane stops consulting the map at all"
mutate "M10 grounding lane ignores equivalents" \
  "    strong: tok.strong.filter((tokenText) => !groundedIn(tokenText, hayLower))," \
  "    strong: tok.strong.filter((tokenText) => !hayLower.includes(tokenText.toLowerCase()))," \
  "one-way map: PT→source still false-positives" || RC=1

echo "M11 — punctuation normalisation becomes a no-op (the state this shipped in until 2026-09-09)"
mutate "M11 no dash normalisation" \
  "const punctNormalize = (s) => String(s ?? '')" \
  "const punctNormalize = (s) => String(s ?? '').split('\\u0000').join('') || String(s ?? ''); const _unusedPunct = (s) => String(s ?? '')" \
  "dash normalisation missing" || RC=1

echo "M12 — the relation lane never reports a conflict"
mutate "M12 relations blind" \
  "    if (sameSubject.some((g) => g.per === r.per)) continue;" \
  "    if (true) continue;" \
  "the motivating false negative is still open" || RC=1

echo "M13 — the relation lane only looks one way (per dropped, never per invented)"
mutate "M13 one-way relations" \
  "    if (sameSubject.some((g) => g.per === r.per)) continue;" \
  "    if (sameSubject.some((g) => g.per === r.per) || r.per) continue;" \
  "relation check is one-way" || RC=1

echo "M14 — any word after a number counts as a magnitude"
mutate "M14 magnitude list ignored" \
  "    if (MAGNITUDE_WORDS.has(fold(w1))) {" \
  "    if (w1) {" \
  "extractor invents relations" || RC=1

echo "M15 — relation findings are computed but never reach the verdict"
# 🔴 The anchor is ONE line on purpose. A multi-line anchor written with \n
# inside double quotes reaches python as a literal backslash-n and the mutation
# silently never lands — which the harness reports as ANCHOR MISSED rather than
# as robustness, and that is the only reason this was caught.
mutate "M15 relations not scored" \
  "  const status = (missing.strong.length + missing.numbers.length + missing.relations.length > 0)" \
  "  const status = (missing.strong.length + missing.numbers.length > 0)" \
  "the motivating false negative is still open" || RC=1

echo "M16 — the tautology guard normalises only the haystack (the regression of 2026-09-09)"
mutate "M16 one-sided tautology normalisation" \
  "  if (norm(hay).includes(norm(textCmp)) && norm(textCmp).length > 0) {" \
  "  if (norm(hay).includes(norm(text)) && norm(text).length > 0) {" \
  "one-sided normalisation: a self-grounded summary scored" || RC=1

echo
after="$(bash "$SUITE" 2>&1 | tail -1)"
echo "restored: $after"
grep -qE "(^|[^0-9])0 failed" <<<"$after" || { echo "FATAL: source not restored cleanly"; exit 1; }
exit $RC
