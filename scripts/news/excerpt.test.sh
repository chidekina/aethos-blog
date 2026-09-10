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

echo "ARM 6 — the repeated headline comes off, and a running sentence does NOT"
# 🔴 All three fixtures are COPIED from the 94-excerpt corpus measured
# 2026-09-09, not invented. The third is the one that matters: there the
# headline is the opening of a running sentence, and a naive prefix strip leaves
# the line starting at ", a new benchmark…". An invented fixture agrees with the
# naive implementation, which is why this repo copies its fixtures.
out="$(node --input-type=module -e "
import {stripRepeatedTitle} from '$MOD';
const EN_DASH='–';
const a=stripRepeatedTitle('On the Navier'+EN_DASH+'Stokes Millennium Prize Problem Impressive result from OpenAI, who used an unreleased model.','On the Navier'+EN_DASH+'Stokes Millennium Prize Problem');
console.log('stripped='+a.slice(0,10));
const b=stripRepeatedTitle(\"Introducing ChatGPT Images 2.5 OpenAI's image generation models are widely used.\",'Introducing ChatGPT Images 2.5');
console.log('stripped2='+b.slice(0,7));
const c=stripRepeatedTitle('Introducing GeneBench-Pro, a new benchmark testing AI performance in genomics.','Introducing GeneBench-Pro');
console.log('kept='+c.startsWith('Introducing GeneBench-Pro,'));
// An excerpt that is ONLY the headline has nothing left to keep; returning an
// empty line would be worse than repeating the headline.
const d=stripRepeatedTitle('Introducing GeneBench-Pro','Introducing GeneBench-Pro');
console.log('titleOnly='+(d==='Introducing GeneBench-Pro'));
// A headline the excerpt does not repeat must pass through untouched.
const e=stripRepeatedTitle('Something else entirely happened today.','Introducing GeneBench-Pro');
console.log('untouched='+e.startsWith('Something else'));
" 2>&1)"
has "$out" "stripped=Impressive" && ok "headline followed by a new sentence is dropped" || bad "repeated headline survived" "$out"
has "$out" "stripped2=OpenAI" && ok "and the second measured case" || bad "second case survived" "$out"
has "$out" "kept=true" && ok "headline that OPENS a running sentence is kept" || bad "naive prefix strip broke a sentence" "$out"
has "$out" "titleOnly=true" && ok "an excerpt that is only the headline is left alone" || bad "stripped an excerpt down to nothing" "$out"
has "$out" "untouched=true" && ok "a non-repeated headline changes nothing" || bad "strip fired without a repetition" "$out"

echo "ARM 7 — publisher footer and newsletter greeting, both anchored"
# Measured 5/94 and 3/94 respectively. The negative arms carry the weight: an
# unanchored version of either eats ordinary prose, and nothing in the output
# would show that it had.
out="$(node --input-type=module -e "
import {stripFeedFurniture} from '$MOD';
console.log('footer='+stripFeedFurniture('CodeQL now supports Linux ARM64 runners. The post CodeQL 2.27.0 adds support for Linux ARM64 appeared first on The GitHub Blog .'));
console.log('greeting='+stripFeedFurniture('Hi everyone, Seb and Jan here! React 19.3 is out with a new compiler.'));
// NEGATIVE: 'the post' in ordinary prose, with no 'appeared first on', stays.
console.log('prose='+stripFeedFurniture('The post office closed early, so the release slipped a day.'));
// NEGATIVE: a greeting without the trailing 'here' is not the newsletter shape.
console.log('hi='+stripFeedFurniture('Hi there, this release fixes three bugs.'));
" 2>&1)"
has "$out" "footer=CodeQL now supports Linux ARM64 runners." && ok "the WordPress footer is removed" || bad "footer survived or ate the body" "$out"
has "$out" "greeting=React 19.3 is out with a new compiler." && ok "the newsletter greeting is removed" || bad "greeting survived or ate the body" "$out"
has "$out" "prose=The post office closed early" && ok "'The post' in ordinary prose is untouched" || bad "unanchored footer rule ate real prose" "$out"
has "$out" "hi=Hi there, this release fixes three bugs." && ok "a greeting without 'here' is not the shape" || bad "greeting rule too broad" "$out"

echo "ARM 8 — boilerplate comes off BEFORE the budget cut"
# Order matters: 220 characters spent on a repeated headline is 220 characters
# the reader does not get. This asserts the composition, not either half.
out="$(node --input-type=module -e "
import {stripBoilerplate,trimToBoundary,EXCERPT_BUDGET} from '$MOD';
const title='Introducing ChatGPT Images 2.5';
const body='OpenAI image models are widely used. '.repeat(12);
const raw=title+' '+body;
const good=trimToBoundary(stripBoilerplate(raw,title),EXCERPT_BUDGET);
const bad_=trimToBoundary(raw,EXCERPT_BUDGET);
console.log('leadsWithBody='+good.startsWith('OpenAI'));
console.log('naiveLeadsWithTitle='+bad_.startsWith('Introducing'));
console.log('within='+(good.length<=EXCERPT_BUDGET+1));
" 2>&1)"
has "$out" "leadsWithBody=true" && ok "the trimmed line starts at the body" || bad "headline still consumed the budget" "$out"
# The control: without the strip the same input DOES lead with the headline, so
# the arm above is measuring the strip and not a property of the fixture.
has "$out" "naiveLeadsWithTitle=true" && ok "and without the strip it does not (control)" || bad "fixture proves nothing — it leads with the body either way" "$out"
has "$out" "within=true" && ok "the budget still holds" || bad "budget blown" "$out"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
