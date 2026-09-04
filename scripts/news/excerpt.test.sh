#!/usr/bin/env bash
# v2026.09.04
# Suite for the fallback excerpt trim. Both ends on every arm: a trimmer that
# never cuts and a trimmer that always cuts mid-word must each turn this red.
set -uo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
MOD="$REPO/scripts/news/excerpt.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { grep -qF -- "$2" <<<"$1"; }

[ -f "$MOD" ] || { echo "FATAL: $MOD missing"; exit 1; }
node --check "$MOD" || { echo "FATAL: $MOD does not parse"; exit 1; }
run() { node --input-type=module -e "import {trimToBoundary,EXCERPT_BUDGET,SENTENCE_FLOOR} from '$MOD'; $1" 2>&1; }

echo "ARM 1 — under budget is returned untouched"
out="$(run "
const s='A short excerpt that fits.';
console.log('same='+(trimToBoundary(s,220)===s));
console.log('noEllipsis='+!trimToBoundary(s,220).endsWith('…'));
")"
has "$out" "same=true" && ok "a short line is unchanged" || bad "short line altered" "$out"
has "$out" "noEllipsis=true" && ok "and gains no ellipsis" || bad "ellipsis added to a complete line" "$out"

echo "ARM 2 — over budget cuts at a SENTENCE end when one is late enough"
out="$(run "
// two sentences; the first ends well past half the budget
const s='Google Cloud integrated TPU support into the vLLM serving engine this week, which lets teams scale embedding pipelines on GKE without rewriting their inference layer at all. Then a second sentence follows here with more detail that will not fit.';
const r=trimToBoundary(s,220);
console.log('len='+r.length+' endsDot='+r.endsWith('.')+' ellipsis='+r.endsWith('…'));
// 'ends with a letter' is NOT 'ends mid-word' — a correctly cut line ends on a
// whole word, which ends on a letter. That predicate passed here only because
// this line happens to end on a full stop. The one with teeth is whether the
// final token exists whole in the source.
// Normalise BOTH sides: the source token is 'all.' with the stop attached, so
// comparing a stripped tail against raw source tokens fails on punctuation and
// reads as a mid-word cut. Same class as the assertion this replaced.
const bare=(x)=>x.replace(/^[^A-Za-z0-9]+|[^A-Za-z0-9]+\$/g,'');
const w2=bare(r.split(/\s+/).pop());
console.log('lastWholeWord='+s.split(/\s+/).map(bare).includes(w2));
")"
has "$out" "endsDot=true" && ok "it ends on the sentence's own full stop" || bad "did not cut at the sentence end" "$out"
has "$out" "ellipsis=false" && ok "and adds no ellipsis — the line is complete" || bad "ellipsis on a complete sentence" "$out"
has "$out" "lastWholeWord=true" && ok "and its final word is whole, not a fragment" || bad "ends mid-word" "$out"

echo "ARM 3 — no usable sentence end: cut at a WORD boundary, with the ellipsis"
# This is the shape that produced 8 of 8 mid-word cuts in production.
out="$(run "
const s='GPT-6 Astra from OpenAI is now available in GitHub Copilot for long horizon autonomous coding and agentic tasks across the whole editor surface and the command line as well as review flows'.repeat(2);
const r=trimToBoundary(s,220);
console.log('ellipsis='+r.endsWith('…'));
console.log('withinBudget='+(r.length<=221));
// the crucial one: the last WORD must be whole, i.e. present in the source
const bare=(x)=>x.replace(/^[^A-Za-z0-9]+|[^A-Za-z0-9]+\$/g,'');
const last=bare(r.split(/\s+/).pop());
console.log('lastWholeWord='+s.split(/\s+/).map(bare).includes(last));
")"
has "$out" "ellipsis=true" && ok "an incomplete cut is marked with an ellipsis" || bad "no ellipsis on an incomplete cut" "$out"
# 🔴 THE assertion of this arm. A first version asked whether the line ends with
# a letter; that is not the same question, and it passed for a mutation that cut
# at byte 220 and appended '…'. Whole-word membership in the source is what
# actually separates a boundary cut from a byte cut.
has "$out" "lastWholeWord=true" && ok "its final word appears whole in the source — not a fragment" || bad "still cutting mid-word" "$out"
has "$out" "withinBudget=true" && ok "and it stays inside the budget" || bad "over budget" "$out"

echo "ARM 4 — an EARLY sentence end is ignored, not obeyed"
# Cutting at a full stop 6 chars in would throw away 97% of the excerpt. The
# floor is what stops the tidy rule from becoming the destructive one.
out="$(run "
const s='Done. '+'and then a great deal more text follows here that the reader actually wants to see because it carries the substance of the item rather than a one word opener '.repeat(3);
const r=trimToBoundary(s,220);
console.log('len='+r.length+' ellipsis='+r.endsWith('…'));
")"
has "$out" "ellipsis=true" && ok "an early full stop falls through to the word cut" || bad "obeyed a 6-char sentence end" "$out"
node --input-type=module -e "
import {trimToBoundary} from '$MOD';
const s='Done. '+'and then a great deal more text follows here that the reader actually wants to see because it carries the substance of the item rather than a one word opener '.repeat(3);
process.exit(trimToBoundary(s,220).length > 100 ? 0 : 1);" \
  && ok "and keeps most of the budget rather than 5 characters" || bad "threw away the excerpt" "$out"

echo "ARM 5 — no spaces at all: it must still bound the length"
out="$(run "
const r=trimToBoundary('A'.repeat(400),220);
console.log('len='+r.length+' ellipsis='+r.endsWith('…'));
")"
has "$out" "ellipsis=true" && ok "a single unbroken token still gets the marker" || bad "unbroken token unmarked" "$out"
node --input-type=module -e "
import {trimToBoundary} from '$MOD';
process.exit(trimToBoundary('A'.repeat(400),220).length <= 221 ? 0 : 1);" \
  && ok "and the budget still holds" || bad "budget blown on an unbroken token" "$out"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
