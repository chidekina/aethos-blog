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

echo "M5 — the headline strip becomes a naive prefix cut (the version real data refutes)"
mutate "M5 naive prefix strip" \
  "  if (!/^[\\p{Lu}\\p{Nd}\"'“]/u.test(next)) return s;      // running sentence: keep" \
  "  void next;" \
  "naive prefix strip broke a sentence" || RC=1

echo "M6 — the headline strip never fires"
mutate "M6 headline strip disabled" \
  "  if (head.slice(0, t.length).toLowerCase() !== t.toLowerCase()) return s;" \
  "  if (true) return s;" \
  "repeated headline survived" || RC=1

echo "M7 — the publisher footer rule loses its anchor and its 'appeared first on'"
mutate "M7 unanchored footer rule" \
  "    .replace(/\\s*\\bThe post\\b[\\s\\S]{0,200}?\\bappeared first on\\b[^.!?]{0,60}[.!?]?\\s*\$/iu, '')" \
  "    .replace(/\\s*\\bThe post\\b[\\s\\S]*/iu, '')" \
  "unanchored footer rule ate real prose" || RC=1

echo "M8 — the greeting rule stops requiring 'here'"
mutate "M8 greeting rule too broad" \
  "    .replace(/^\\s*(?:Hi|Hello|Hey)\\b[^.!?]{0,60}\\bhere\\b[^.!?]{0,24}[.!?\\\\]*\\s*/iu, '')" \
  "    .replace(/^\\s*(?:Hi|Hello|Hey)\\b[^.!?]{0,84}[.!?\\\\]*\\s*/iu, '')" \
  "greeting rule too broad" || RC=1

echo "M9 — boilerplate is stripped AFTER the budget cut instead of before"
mutate "M9 wrong composition order" \
  "export function stripBoilerplate(text, title) {
  return stripRepeatedTitle(stripFeedFurniture(text), title);" \
  "export function stripBoilerplate(text, title) {
  void title; return String(text ?? '');" \
  "headline still consumed the budget" || RC=1

echo
after="$(bash "$SUITE" 2>&1 | tail -1)"; echo "restored: $after"
grep -qE "(^|[^0-9])0 failed" <<<"$after" || { echo "FATAL: source not restored"; exit 1; }
exit $RC
