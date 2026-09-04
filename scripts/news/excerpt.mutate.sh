#!/usr/bin/env bash
# v2026.09.04
# Mutation harness for the excerpt trim. Anchors asserted before running.
set -uo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/scripts/news/excerpt.mjs"
SUITE="$REPO/scripts/news/excerpt.test.sh"
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
echo "M1 — back to the bare byte slice (the shape that shipped 8 of 8 mid-word)"
mutate "M1 mid-word cut returns" \
  "  const head = s.slice(0, max);" \
  "  return s.slice(0, max) + '…';
  const head = s.slice(0, max);" \
  "still cutting mid-word" || RC=1   # the assertion that only has teeth with the marker stripped

echo "M2 — the sentence floor is removed, so any full stop wins"
mutate "M2 early full stop obeyed" \
  "if (sentence >= max * SENTENCE_FLOOR) return head.slice(0, sentence + 1).trim();" \
  "if (sentence >= 0) return head.slice(0, sentence + 1).trim();" \
  "obeyed a 6-char sentence end" || RC=1

echo "M3 — an ellipsis is appended even to a complete sentence"
mutate "M3 marker on a complete line" \
  "if (sentence >= max * SENTENCE_FLOOR) return head.slice(0, sentence + 1).trim();" \
  "if (sentence >= max * SENTENCE_FLOOR) return head.slice(0, sentence + 1).trim() + '…';" \
  "ellipsis on a complete sentence" || RC=1

echo "M4 — short input is trimmed anyway"
mutate "M4 touches a line under budget" \
  "  if (s.length <= max) return s;" \
  "  if (s.length < 0) return s;" \
  "short line altered" || RC=1

echo
after="$(bash "$SUITE" 2>&1 | tail -1)"; echo "restored: $after"
grep -qE "(^|[^0-9])0 failed" <<<"$after" || { echo "FATAL: source not restored"; exit 1; }
exit $RC
