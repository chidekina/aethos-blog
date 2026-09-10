#!/usr/bin/env bash
# v2026.09.10
# Mutation harness for replay-edition.mjs. Each mutation removes ONE guarantee
# and must kill a NAMED, DISJOINT set of assertions. A mutation that survives is
# a statement about the suite, not about the code.
#
#   bash scripts/news/replay-edition.mutate.sh
#
# 🔴 Every run is bounded by `timeout`. A mutation that loops does not go red, it
# HANGS — and a harness killed mid-run never restores the file, leaving the
# mutant on disk. Exit 124 is read here as "killed by hanging", a verdict.
# 🔴 Restoration is verified by EFFECT — `diff` against the pristine copy AND a
# grep for the line that carries the weight. An exit code proves neither.
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="$REPO/scripts/news/replay-edition.mjs"
SUITE="$REPO/scripts/news/replay-edition.test.sh"
PRISTINE="$(mktemp)"
cp "$TARGET" "$PRISTINE"
restore() {
  cp "$PRISTINE" "$TARGET"
  diff -q "$PRISTINE" "$TARGET" >/dev/null || { echo "FATAL: restore failed (diff)"; exit 1; }
  [ "$(grep -c 'VACUOUS' "$TARGET")" -ge 1 ] || { echo "FATAL: restore failed (load-bearing line absent)"; exit 1; }
}
trap 'restore; rm -f "$PRISTINE"' EXIT

BASE="$(timeout 300 bash "$SUITE" 2>&1 | tail -1)"
echo "baseline: $BASE"
case "$BASE" in *" 0 failed") ;; *) echo "FATAL: baseline is not green — mutations would be unreadable"; exit 1;; esac

MUT_FAILED=0
mutate() { # mutate <name> <expected-killed-arm> <python-patch>
  local name="$1" expect="$2" patch="$3"
  python3 - "$TARGET" <<PY
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read(); o=t
$patch
assert t!=o, "ANCHOR MISSED: mutation did not change the file"
open(p,'w',encoding='utf-8').write(t)
PY
  if [ $? -ne 0 ]; then
    echo "  MUTATION NOT APPLIED: $name — a mutation that misses its anchor runs against the INTACT file and reads as robustness"
    MUT_FAILED=1; restore; return
  fi
  local out st
  out="$(timeout 300 bash "$SUITE" 2>&1)"; st=$?
  local line; line="$(tail -1 <<<"$out")"
  restore
  if [ "$st" -eq 124 ]; then
    echo "  killed by HANGING: $name  (a verdict, not a lost run)"
  elif [ "$st" -ne 0 ]; then
    echo "  killed: $name -> $line   [expected: $expect]"
  else
    echo "  SURVIVED: $name -> $line   [expected to kill: $expect]"
    MUT_FAILED=1
  fi
}

echo "M1 - a backfilled record is replayed instead of refused"
mutate "no all-null guard" "ARM 1" '
old="if (nulls === ed.items.length) {"
assert old in t, "anchor"
t=t.replace(old,"if (false) {",1)'

echo "M2 - a tally over zero model lines is reported as a result"
mutate "no VACUOUS guard" "ARM 3" '
old="if (generated === 0) {"
assert old in t, "anchor"
t=t.replace(old,"if (false) {",1)'

echo "M3 - a non-integer --samples falls back instead of refusing"
mutate "--samples falls back" "ARM 4" '
old="if (!Number.isInteger(N) || N < 1) die(2,"
assert old in t, "anchor"
t=t.replace(old,"if (false) die(2,",1)'

echo "M4 - an unusable model is reported as a finding, not a broken instrument"
mutate "dead model exits 1" "ARM 5" '
old="die(2, `INSTRUMENT: ${OLLAMA_MODEL} at ${OLLAMA_URL} is unusable"
assert old in t, "anchor"
t=t.replace(old,"die(1, `INSTRUMENT: ${OLLAMA_MODEL} at ${OLLAMA_URL} is unusable",1)'

echo "M5 - notes are printed on stdout, so --json stops parsing"
mutate "log always stdout" "ARM 8" '
old="const log = (...a) => (asJson ? console.error : console.log)"
assert old in t, "anchor"
t=t.replace(old,"const log = (...a) => (false ? console.error : console.log)",1)'

echo
if [ "$MUT_FAILED" -eq 0 ]; then echo "MUTATE_EXIT=0 — every mutation was killed"; else echo "MUTATE_EXIT=1 — a mutation survived or missed its anchor"; fi
exit "$MUT_FAILED"
