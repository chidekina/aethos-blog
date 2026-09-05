#!/usr/bin/env bash
# v2026.09.04
# Mutation harness for the Ollama liveness probe in fetch-news.mjs.
#
# Why this file exists: fetch-news.mjs was the only script in scripts/news/ with
# a suite and NO mutation harness, so its 66 assertions were never shown to have
# teeth. The three siblings had one; the largest surface did not.
#
# Scope is the probe and its diagnosis — the part measured on 2026-09-04, when a
# real cron firing returned RESULT=BROKEN with a cause the data could not
# support. Every mutation here reverts one property of that fix and must kill a
# NAMED arm; a mutation that kills nothing is either a dead assertion or a
# mutation that never reached its target, and this harness distinguishes them.
set -uo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/scripts/news/fetch-news.mjs"
SUITE="$REPO/scripts/news/fetch-news.test.sh"
T="$(mktemp -d)"
cp "$SRC" "$T/pristine.mjs"
# 🔴 The restore must survive an INTERRUPT, not only a clean finish. Measured
# 2026-09-04: this harness was killed mid-mutation and left fetch-news.mjs
# mutated on disk, with `git status` the only thing that would have said so. The
# end-of-run check cannot fire on a run that never reaches its end.
restore() { cp "$T/pristine.mjs" "$SRC" 2>/dev/null; rm -rf "$T"; }
trap restore EXIT INT TERM

# 🔴 `grep -qF "0 failed"` matches "10 failed". Measured on this repo's other
# harnesses: a mutation that killed TEN assertions was reported as SURVIVED.
green() { grep -qE "(^|[^0-9])0 failed" <<<"$1"; }

base="$(bash "$SUITE" 2>&1 | tail -1)"; echo "baseline: $base"
green "$base" || { echo "FATAL: not green before mutating — nothing below would mean anything"; exit 1; }

mutate() {
  local name="$1" old="$2" new="$3" expect="$4"
  cp "$SRC" "$T/orig.mjs"
  # The anchor is asserted INSIDE the patch. A mutation whose anchor drifted runs
  # against the pristine file and comes back green — indistinguishable from
  # robustness, and the more comfortable of the two readings.
  python3 - "$SRC" "$old" "$new" <<'PY' || { cp "$T/orig.mjs" "$SRC"; echo "  ANCHOR MISSED — $name never reached the target"; return 1; }
import io,sys
p,old,new=sys.argv[1],sys.argv[2],sys.argv[3]
t=io.open(p,encoding='utf-8').read()
assert old in t, 'anchor absent'
io.open(p,'w',encoding='utf-8').write(t.replace(old,new,1))
PY
  # 🔴 `expect` must be the label from `bad "..."`, not the one from `ok "..."`.
  # They differ, and passing the ok-label reports WRONG ARM for a mutation that
  # killed exactly the right assertion — a harness lying in the direction that
  # makes you weaken a correct test.
  local out; out="$(bash "$SUITE" 2>&1)"; cp "$T/orig.mjs" "$SRC"
  local failed; failed="$(grep '^  FAIL' <<<"$out" | sed 's/^  FAIL //' | tr '\n' ';')"
  green "$out" && { echo "  SURVIVED  $name"; return 1; }
  echo "  killed    $name"
  echo "            fails: $failed"
  grep -qF "$expect" <<<"$failed" && echo "            expected arm" || { echo "            WRONG ARM"; return 1; }
}

RC=0

echo "M1 — the empty /api/ps branch goes back to naming a cause"
# The exact string the cron rehearsal printed, and the one whose prescribed fix
# measurement had already refuted.
mutate "M1 empty ps asserts 'genuinely wedged'" \
  '        ? `/api/ps reports nothing loaded, and that does not identify the cause — a load queued waiting ` +
            `for a slot is invisible there by construction, so a wedged runner and a card that was held ` +
            `and released read the same. ${discriminate}`' \
  '        ? `Nothing is reported loaded, so this looks like a genuinely wedged runner: \`ollama stop ${OLLAMA_MODEL}\`.`' \
  "it still picks a cause" || RC=1

echo "M2 — loadedModels collapses 'could not read' back into 'read, and empty'"
mutate "M2 unreadable ps reads as empty" \
  "return { queried: false, models: [], why: err.name === 'AbortError' ? 'timed out after 5000ms' : err.message };" \
  "return { queried: true, models: [], why: '' };" \
  "unreadable ps reported as empty" || RC=1

echo "M3 — the generation probe is skipped, so the catalogue alone decides"
# This is the original false-green the probe exists to close: /api/tags answering
# is not generation working. Without the probe every wedged-server arm passes.
mutate "M3 catalogue answering counts as alive" \
  "    const gctl = new AbortController();" \
  "    return { ok: true };
    const gctl = new AbortController();" \
  "wedged runner -> exit 2" || RC=1

echo "M4 — the holder filter stops excluding our own model"
# With only ours loaded this flips the message into the blocked-by-another
# branch, which is the advice measurement refuted.
mutate "M4 our model counts as its own blocker" \
  "const others = holders.models.filter((m) => m.name !== OLLAMA_MODEL);" \
  "const others = holders.models.filter(() => true);" \
  "advice did not adapt" || RC=1

echo
after="$(bash "$SUITE" 2>&1 | tail -1)"; echo "restored: $after"
green "$after" || { echo "FATAL: source not restored — the tree is dirty, do not commit"; exit 1; }
exit $RC
