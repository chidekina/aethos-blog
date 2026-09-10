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
PRISTINE="$T/pristine.src"
cp "$SRC" "$PRISTINE"
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
  grep -qF -- "$expect" <<<"$failed" && echo "            expected arm" || { echo "            WRONG ARM"; return 1; }
}

RC=0

echo "M1 — the empty /api/ps branch goes back to the retracted 'wedged runner' claim"
# The exact string the cron rehearsal printed, and the one whose prescribed fix
# measurement had already refuted.
mutate "M1 empty ps asserts 'genuinely wedged'" \
  '        ? `/api/ps is empty, which most likely means a LOAD IS IN PROGRESS: a model being loaded is ` +
            `not listed there until it finishes (measured — empty for 8.5 s of an 8.7 s cold load, with ` +
            `the GPU already at 2743 MiB). Loads on this machine have taken 4.6 s, 8.7 s and ~35 s, so a ` +
            `probe outliving ${PROBE_TIMEOUT_MS}ms points at a slow load rather than a dead server. ${discriminate}`' \
  '        ? `Nothing is reported loaded, so this looks like a genuinely wedged runner: \`ollama stop ${OLLAMA_MODEL}\`.`' \
  "it still picks the wrong cause" || RC=1

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
  "advice did not adapt" || RC=1   # ARM 16B: with only ours loaded the advice must flip back

echo "M-SUM-ON — summarisation goes back to being the default"
mutate "summarisation on by default" \
  "const wantSummary = argv.includes('--llm') || argv.includes('--llm-summary');" \
  "const wantSummary = !argv.includes('--no-llm');" \
  "default still requires Ollama" || RC=1

echo "M-SUM-INERT — --llm-summary is parsed and ignored"
mutate "summary flag inert" \
  "const wantSummary = argv.includes('--llm') || argv.includes('--llm-summary');" \
  "const wantSummary = false;" \
  "--llm-summary did not reach for the model" || RC=1

echo "M-TRANS-OFF — translation stops being the default (the state that shipped for a few hours)"
mutate "translation off by default" \
  "const wantTranslate = !argv.includes('--no-llm') && !argv.includes('--no-translate');" \
  "const wantTranslate = argv.includes('--llm');" \
  "monolingual output went unannounced" || RC=1

echo "M-TRANS-DIE — a translation outage kills the run instead of degrading"
mutate "outage is fatal" \
  "    useTranslate = false;" \
  "    process.exit(2);" \
  "a dead Ollama now kills the default run" || RC=1

echo "M-COUNT — the translated count is printed only when something went wrong"
# Without this, the count line reverts to the shape nobody learns to read.
mutate "count only on failure" \
  "log(\`TRANSLATED \${translated}/\${shortlist.length} PT lines. \` +" \
  "if (translated === shortlist.length) { /* silent on success */ } else log(\`TRANSLATED \${translated}/\${shortlist.length} PT lines. \` +" \
  "count is only printed on failure" || RC=1
# 🔴 The expect points at ARM 20, not ARM 19. This mutation SURVIVED its first
# run: every translation arm ran against a dead Ollama, so no arm ever reached a
# run where nothing went wrong, and "print only on failure" was indistinguishable
# from "print always". ARM 20 stubs a model that answers. A mutation surviving is
# a statement about the SUITE, not about the code.

echo "M-PERITEM — every item claims it was translated"
mutate "per-item flag always true" \
  "      translated: it.translated === true," \
  "      translated: true," \
  "per-item flag missing" || RC=1

echo "M-KNOWN — --no-llm is dropped from the accepted flags"
mutate "no-llm rejected" \
  "const KNOWN_FLAGS = new Set(['--dry-run', '--check-sources', '--no-llm', '--llm', '--llm-summary', '--no-translate']);" \
  "const KNOWN_FLAGS = new Set(['--dry-run', '--check-sources', '--llm', '--llm-summary', '--no-translate']);" \
  "--no-llm became an unknown flag" || RC=1

echo
after="$(bash "$SUITE" 2>&1 | tail -1)"; echo "restored: $after"
# 🔴 Restoration is a property of the FILE, and it is checked against the file.
# This used to key on the suite being green, which conflates two different
# outcomes: on 2026-09-10 a flaky arm made this print "the tree is dirty, do not
# commit" while `cmp` said the source was byte-identical to the pristine copy.
# A harness that reports a red suite as an unrestored tree sends you looking for
# a mutation that is not there.
if cmp -s "$PRISTINE" "$SRC"; then
  echo "restored: source is byte-identical to the pristine copy"
else
  echo "FATAL: SOURCE NOT RESTORED — $SRC differs from the copy taken before mutating."
  echo "       Recover it with: cp \"$PRISTINE\" \"$SRC\"  (do this before anything else)"
  diff -u "$PRISTINE" "$SRC" | head -20
  exit 1
fi
# A red suite on a restored source is a SEPARATE finding, and usually a flaky
# arm. Reported as itself, never as a restoration failure.
grep -qE "(^|[^0-9])0 failed" <<<"$after" \
  || { echo "WARNING: the suite is red on the restored source — $after"; echo "         Not a restoration failure. Run the suite alone before believing it."; RC=1; }
exit $RC
