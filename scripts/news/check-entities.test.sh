#!/usr/bin/env bash
# v2026.09.04
# Suite for the entity/number preservation check (DIGEST-EVAL item 1).
#
#   bash scripts/news/check-entities.test.sh
#
# Every arm carries both ends. A suite made only of arms that must FAIL would
# certify a checker that flags everything; a suite made only of arms that must
# PASS would certify a checker that flags nothing. Both shapes have shipped in
# this repo's history, so neither is hypothetical.
#
# The predicates are IMPORTED from the real module, never re-typed — a re-typed
# predicate measures the copy instead of what the pipeline runs.
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
MOD="$REPO/scripts/news/check-entities.mjs"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
# here-string, never `| grep -q`: under pipefail a producer killed by SIGPIPE
# reports 141 and a match that DID happen reads as a failure.
has() { grep -qF -- "$2" <<<"$1"; }

# Precondition. Without it a missing module makes every `node -e` print nothing,
# every `has` fail, and the restrictive arms pass for entirely the wrong reason.
[ -f "$MOD" ] || { echo "FATAL: $MOD does not exist"; exit 1; }
node --check "$MOD" || { echo "FATAL: $MOD does not parse"; exit 1; }

run() { node --input-type=module -e "import {classify,extractTokens,checkSummary,checkTranslation,checkItem} from '$MOD'; $1" 2>&1; }

echo "ARM 1 — classification: the strong classes, and the words that must NOT be strong"
out="$(run "
const strong=['GPT-4','llama3.2','LLM','API','TypeScript','MiniCheck','Terminal-Bench-Science'];
const notStrong=['ships','framework','developers','Google','Anthropic'];
console.log('S:'+strong.map(w=>classify(w)).join(','));
// String(): Array.join renders null as an empty string, so a raw join would
// make 'null' and 'strong-but-empty' indistinguishable — a control reading the
// render instead of the predicate. Same defect shape as this session's log.
console.log('N:'+notStrong.map(w=>String(classify(w))).join(','));
")"
has "$out" "S:strong,strong,strong,strong,strong,strong,strong" \
  && ok "every strong class is recognised" \
  || bad "strong classes" "$out"
# The negative control. A classifier that answered 'strong' to everything would
# pass the line above and produce an alert on every ordinary word.
has "$out" "N:null,null,null,weak,weak" \
  && ok "ordinary words are null, plain capitals are weak (never strong)" \
  || bad "negative control: over-broad classifier" "$out"

echo "ARM 2 — a faithful summary is clean, on all three lanes"
out="$(run "
const item={title:'Terminal-Bench-Science 0.1 released',link:'x',
  sourceExcerpt:'Terminal-Bench-Science 0.1 is an agent benchmark from Stanford using LLM graders.',
  summaryEn:'Terminal-Bench-Science 0.1 gives agents a reproducible LLM-graded benchmark.',
  summaryPt:'Terminal-Bench-Science 0.1 dá aos agents um benchmark reproduzível avaliado por LLM.'};
const r=checkItem(item);
console.log('en='+r.en.status+' pt='+r.pt.status+' tr='+r.translation.status+' checked='+r.en.checked);
")"
has "$out" "en=pass pt=pass tr=pass" && ok "faithful item passes all three lanes" || bad "false positive on a clean item" "$out"
# Two-ended: 'pass' out of zero checked tokens would be a blind pass.
has "$out" "checked=" && ! has "$out" "checked=0" \
  && ok "and the pass rests on a non-zero token count" \
  || bad "vacuous pass — nothing was actually checked" "$out"

echo "ARM 3 — a translated identifier: CONSTRUCTED, not observed"
# EN keeps the identifier; PT translates it. A DELETION, so the two grounding
# lanes cannot see it — only the EN→PT lane can. Removing checkTranslation turns
# this arm red and leaves every other arm green.
#
# 🔴 This case is BUILT, not recorded. DIGEST-EVAL item 1 presents it as observed
# in edition 1; measured against the draft in git on 2026-09-04, the PT line
# reads `Terminal-Bench-Science 0,1` — the identifier survived and only the
# decimal separator changed. Labelling a constructed fixture as observed is how a
# suite starts certifying a story instead of a behaviour.
out="$(run "
const r=checkItem({title:'Terminal-Bench-Science 0.1 released',link:'x',
  sourceExcerpt:'Terminal-Bench-Science 0.1 is a new agent benchmark.',
  summaryEn:'Terminal-Bench-Science 0.1 benchmarks agents on scientific tasks.',
  summaryPt:'Benchmark de Ciência do Terminal 0,1 avalia agents em tarefas científicas.'});
console.log('en='+r.en.status+' pt='+r.pt.status+' tr='+r.translation.status);
console.log('dropped='+r.translation.missing.strong.join('|'));
")"
has "$out" "tr=fail" && ok "the mangled identifier is caught on the EN→PT lane" || bad "the failure this check exists for went unseen" "$out"
has "$out" "dropped=Terminal-Bench-Science" && ok "and it is named, not just counted" || bad "finding carries no token" "$out"
# The control that makes the arm mean something: the OTHER two lanes stay quiet,
# which is why a summary→source check alone reports this item as fine.
has "$out" "en=pass pt=pass" \
  && ok "negative control: both grounding lanes read this item as clean" \
  || bad "grounding lanes fired — arm no longer isolates the deletion" "$out"

echo "ARM 4 — numbers: an invented one is caught, a pt-BR decimal comma is not"
out="$(run "
const inv=checkSummary({summary:'The model scores 94% on the suite.',grounds:['The model scores 49% on the suite.']});
console.log('invented='+inv.status+' missing='+inv.missing.numbers.join('|'));
const loc=checkTranslation({summaryEn:'Version 0.1 cut latency by 1,200 ms.',summaryPt:'A versão 0,1 cortou a latência em 1.200 ms.'});
console.log('locale='+loc.status+' checked='+loc.checked);
")"
has "$out" "invented=fail" && has "$out" "missing=94" && ok "an ungrounded number is caught and named" || bad "invented number missed" "$out"
# The false-positive control, and it is the one that decides whether anyone
# keeps reading the output: pt-BR writes a decimal comma and a dot thousands
# separator. Flagging correct behaviour is the '81 alerts, 0 real' profile.
has "$out" "locale=pass" && ! has "$out" "locale=pass checked=0" \
  && ok "0.1→0,1 and 1,200→1.200 are the same numbers, and something was checked" \
  || bad "false positive on locale-correct number formatting" "$out"

echo "ARM 5 — nothing checkable is NOT a pass"
out="$(run "
const r=checkSummary({summary:'The release makes the tool faster for everyone.',grounds:['A release that speeds things up.']});
console.log('status='+r.status+' checked='+r.checked+' missingStrong='+r.missing.strong.length);
")"
has "$out" "status=no-tokens" && ok "a summary with no strong token and no number reads no-tokens" || bad "blind run reported as pass" "$out"
has "$out" "checked=0 missingStrong=0" && ok "and it is honest that zero findings came from zero checks" || bad "no-tokens carries findings" "$out"

echo "ARM 6 — broken instrument is distinct from a clean result"
out="$(run "
console.log('nogrounds='+checkSummary({summary:'GPT-4 ships.',grounds:[]}).status);
console.log('empty='+checkSummary({summary:'',grounds:['GPT-4 ships.']}).status);
console.log('identical='+checkTranslation({summaryEn:'GPT-4 ships.',summaryPt:'GPT-4 ships.'}).status);
")"
has "$out" "nogrounds=broken" && ok "no ground text is 'broken', never 'pass'" || bad "checked against nothing and called it clean" "$out"
has "$out" "empty=broken" && ok "an empty summary is 'broken'" || bad "empty summary passed" "$out"
has "$out" "identical=not-translated" && ok "the documented EN=PT fallback is named, not scored" || bad "fallback path mis-scored" "$out"

echo "ARM 7 — CLI exit codes: 0 clean · 1 findings · 2 broken instrument"
clean="$T/clean.json"; dirty="$T/dirty.json"; noitems="$T/noitems.json"
cat > "$clean" <<'JSON'
{"schemaVersion":1,"dateIso":"2026-09-07","items":[
 {"title":"GPT-4 router ships","link":"https://e.test/a","sourceExcerpt":"The GPT-4 router ships with 3 backends.",
  "summaryEn":"The GPT-4 router ships with 3 backends.","summaryPt":"O router GPT-4 chega com 3 backends."}]}
JSON
cat > "$dirty" <<'JSON'
{"schemaVersion":1,"dateIso":"2026-09-07","items":[
 {"title":"Terminal-Bench-Science 0.1 released","link":"https://e.test/b","sourceExcerpt":"Terminal-Bench-Science 0.1 is a new agent benchmark.",
  "summaryEn":"Terminal-Bench-Science 0.1 benchmarks agents.","summaryPt":"Benchmark de Ciência do Terminal 0,1 avalia agents."}]}
JSON
echo '{"schemaVersion":1,"items":[]}' > "$noitems"

out="$(node "$MOD" "$clean" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "clean edition exits 0" || bad "clean edition exit $rc" "$out"
out="$(node "$MOD" "$dirty" 2>&1)"; rc=$?
[ $rc -eq 1 ] && ok "an edition with findings exits 1" || bad "dirty edition exit $rc (expected 1)" "$out"
has "$out" "dropped in PT" && ok "and the report says which direction failed" || bad "report does not name the lane" "$out"
out="$(node "$MOD" "$noitems" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "an edition with no items is exit 2, a broken instrument" || bad "empty edition exit $rc (expected 2)" "$out"
out="$(node "$MOD" "$T/does-not-exist.json" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "an unreadable record is exit 2" || bad "missing file exit $rc (expected 2)" "$out"
out="$(node "$MOD" --nope "$clean" 2>&1)"; rc=$?
[ $rc -eq 2 ] && has "$out" "unknown argument" && ok "an unknown flag refuses to run" || bad "unknown flag ignored" "$out"
out="$(node "$MOD" --json "$dirty" 2>&1)"
node --input-type=module -e "
let d; try { d=JSON.parse(process.argv[1]); } catch { console.log('BADJSON'); process.exit(0); }
console.log('lanes='+Object.keys(d.results[0]).filter(k=>['en','pt','translation'].includes(k)).length);" "$out" \
  | grep -qF "lanes=3" && ok "--json emits all three lanes" || bad "--json shape" "$out"

echo "ARM 8 — a plain capital is reported but never changes the verdict"
out="$(run "
const r=checkSummary({summary:'The GPT-4 router from Wobblecorp ships.',grounds:['The GPT-4 router ships.']});
console.log('status='+r.status+' weak='+r.missing.weak.join('|')+' strong='+r.missing.strong.length);
")"
has "$out" "weak=Wobblecorp" && ok "an ungrounded plain capital is surfaced" || bad "weak class not reported at all" "$out"
has "$out" "status=pass" && ok "and it does not turn the verdict red" || bad "weak class escalated to a failure" "$out"

echo "ARM 9 — a measured pt-BR acronym equivalent is not a loss (and the map does not swallow real ones)"
# Provenance: this arm exists because the fixture suite read 23/0 while the real
# edition-1 drafts produced 2 false positives in 8 items, both `AI` → `IA`.
out="$(run "
console.log('equiv='+checkTranslation({summaryEn:'The AI router uses GPT-4.',summaryPt:'O router de IA usa GPT-4.'}).status);
const lost=checkTranslation({summaryEn:'The LLM benchmark ships.',summaryPt:'A avaliação chega.'});
console.log('lost='+lost.status+' missing='+lost.missing.strong.join('|'));
const bogus=checkTranslation({summaryEn:'The AI router ships.',summaryPt:'O sistema chega.'});
console.log('bogus='+bogus.status+' missing='+bogus.missing.strong.join('|'));
")"
has "$out" "equiv=pass" && ok "AI rendered as IA is correct translation, not a dropped token" || bad "false positive on AI→IA" "$out"
# Both ends. A map applied too loosely — or a lane that stopped checking strong
# tokens at all — would also make the line above green.
has "$out" "lost=fail" && has "$out" "missing=LLM" \
  && ok "an acronym with no equivalent that vanishes is still caught" || bad "map swallowed a real loss" "$out"
has "$out" "bogus=fail" && has "$out" "missing=AI" \
  && ok "and AI vanishing WITHOUT its equivalent present is still caught" || bad "map excuses the token unconditionally" "$out"

echo "ARM 10 — a backfilled record: declared-absent grounds are not a broken instrument"
# sourceExcerpt: null means "we know there is none" (edition 1 predates the record
# writer; its feeds moved on). undefined means the record is malformed. Collapsing
# the two would make the historical record scream exit 2 forever.
out="$(run "
const r=checkItem({title:'T',link:'x',sourceExcerpt:null,
  summaryEn:'GPT-4 ships with 3 backends.',summaryPt:'O GPT-4 chega com 3 backends.'});
console.log('en='+r.en.status+' pt='+r.pt.status+' tr='+r.translation.status);
const bad=checkItem({title:'T',link:'x',summaryEn:'GPT-4 ships.',summaryPt:'O GPT-4 chega.'});
console.log('undef_en='+bad.en.status);
")"
has "$out" "en=no-ground pt=no-ground" && ok "null grounds read no-ground, not broken" || bad "declared absence read as a fault" "$out"
# The lane that CAN still run must still run — otherwise no-ground is a blanket
# excuse and a backfilled record checks nothing at all.
has "$out" "tr=pass" && ok "and the EN→PT lane still runs on that same item" || bad "no-ground disabled every lane" "$out"
# Two-ended: a record MISSING the key entirely is still a broken instrument.
has "$out" "undef_en=broken" && ok "an absent key is still broken — null and undefined do not collapse" || bad "malformed record excused as no-ground" "$out"

BF="$T/backfilled.json"
cat > "$BF" <<'JSON'
{"schemaVersion":1,"dateIso":"2026-09-02","backfilled":{"from":"git"},"items":[
 {"title":"A","link":"https://e.test/a","sourceExcerpt":null,
  "summaryEn":"The GPT-4 router ships.","summaryPt":"O router GPT-4 chega."},
 {"title":"B","link":"https://e.test/b","sourceExcerpt":null,
  "summaryEn":"The LLM benchmark ships.","summaryPt":"A avaliação chega."}]}
JSON
out="$(node "$MOD" "$BF" 2>&1)"; rc=$?
# Item B drops LLM, so the record has a real finding and must exit 1 — a
# backfilled record is not exempt from the lane that still applies.
[ $rc -eq 1 ] && ok "a backfilled record still exits 1 on a real EN→PT finding" || bad "backfilled record exit $rc (expected 1)" "$out"
[ "$(grep -c 'NO-GROUND' <<<"$out")" = 1 ] \
  && ok "and the no-ground notice is ONE line, not one per item per lane" \
  || bad "no-ground repeated per item — the 81-alerts shape" "$out"
has "$out" "dropped in PT: LLM" && ok "and the finding it can still make is reported" || bad "finding suppressed" "$out"

echo "ARM 11 — a summary that IS its source is a tautology, not a pass"
# This is the --no-llm shape: the fallback is a slice of the excerpt, so every
# token is grounded by construction. Measured 2026-09-04, a --no-llm run logged
# "0 ungrounded findings, 42 tokens checked" and not one of the 42 could ever
# have been missing.
out="$(run "
const exc='GPT-4 Astra from OpenAI is now available in GitHub Copilot for agentic tasks.';
const taut=checkSummary({summary:exc.slice(0,60)+'…',grounds:[exc]});
console.log('taut='+taut.status+' checked='+taut.checked);
const real=checkSummary({summary:'GPT-4 Astra reaches Copilot for agentic work.',grounds:[exc]});
console.log('real='+real.status+' checked='+real.checked);
")"
has "$out" "taut=tautological checked=0" && ok "a summary sliced out of its source has no power to fail" || bad "tautology reported as a measurement" "$out"
# Both ends, and this is the one that stops the rule eating everything: a genuine
# summary that REWORDS its source must still be checked, not excused.
has "$out" "real=pass" && ! has "$out" "real=pass checked=0" \
  && ok "a reworded summary is still measured, with a non-zero token count" \
  || bad "the tautology rule swallowed a real check" "$out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
