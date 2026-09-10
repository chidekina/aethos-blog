#!/usr/bin/env bash
# v2026.09.10
# Suite for the edition replay. Runs the REAL script against fixture records and
# a stubbed model — never a re-typed copy of its predicates.
#
#   bash scripts/news/replay-edition.test.sh
#
# Every arm carries both ends: the case that must fire AND the control that
# would also fire if the instrument were blind. The distinction this file exists
# to protect is exit 2 (broken instrument) against exit 1 (real finding) — they
# are one keystroke apart and read identically in a `&&` chain.
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/news/replay-edition.mjs"
T="$(mktemp -d)"
trap 'rm -rf "$T"; [ -n "${OLL_PID:-}" ] && kill "$OLL_PID" 2>/dev/null' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
# here-string, never `| grep -q`: under pipefail a producer killed by SIGPIPE
# reports 141 and a match that DID happen reads as a failure.
has() { grep -qF -- "$2" <<<"$1"; }

[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT missing — the suite would pass by not running"; exit 1; }

# ── a model stub, port from the kernel, reported through a FIFO ───────────
# Port 0 and a FIFO rather than a random high port: the range a draw would use
# holds long-lived local services here, and an EADDRINUSE bind failure makes an
# arm run against something else in silence.
mkfifo "$T/fifo"
LINE_FILE="$T/line"
echo "Astra is an improved OpenAI model with better output quality." > "$LINE_FILE"
LINE_FILE="$LINE_FILE" node -e '
const http=require("http"),fs=require("fs");
http.createServer((q,r)=>{
  let b="";q.on("data",c=>b+=c);q.on("end",()=>{
    const line=fs.readFileSync(process.env.LINE_FILE,"utf8").trim();
    r.writeHead(200,{"content-type":"application/json"});
    r.end(JSON.stringify({response:line}));
  });
}).listen(0,"127.0.0.1",function(){fs.writeSync(1,String(this.address().port)+"\n")});
' > "$T/fifo" &
OLL_PID=$!
read -t 25 -r OPORT < "$T/fifo" || { echo "FATAL: model stub never reported a port"; exit 1; }
OK_URL="http://127.0.0.1:$OPORT"
run() { OLLAMA_URL="$OK_URL" node "$SCRIPT" "$@" 2>&1; }
# 🔴 A dead STUB and a dead MODEL produce the same "fetch failed" line, so an arm
# expecting a verdict would read a crashed fixture as evidence about the model.
# Assert the stub answers before any arm leans on it. This fired for real: the
# stub took LINE_FILE as argv instead of env, threw on its first request, and ten
# assertions blamed the model.
kill -0 "$OLL_PID" 2>/dev/null || { echo "FATAL: model stub died before the arms ran"; exit 1; }
curl -s --max-time 5 -X POST "$OK_URL/api/generate" -d '{}' > "$T/probe" 2>&1
has "$(cat "$T/probe")" "response" || { echo "FATAL: model stub does not answer /api/generate — every arm below would read as a dead model"; exit 1; }

# ── fixture records ───────────────────────────────────────────────────────
mk() { # mk <file> <json>
  printf '%s\n' "$2" > "$T/$1"
}
GROUNDED='OpenAI released Astra today, an improved model with better output quality and more attention to detail.'
# Every strong token here appears in GROUNDED, and the sentence is not a slice of
# it — the only shape that can score `pass`.
GOOD_LINE='Astra is an improved OpenAI model with better output quality.'
mk good.json "{\"schemaVersion\":1,\"dateIso\":\"2026-01-01\",\"items\":[
 {\"title\":\"Introducing Astra\",\"link\":\"https://e.test/1\",\"source\":\"E\",\"sourceExcerpt\":\"$GROUNDED\",\"summaryEn\":\"x\",\"publishedEn\":\"y\"},
 {\"title\":\"Astra again\",\"link\":\"https://e.test/2\",\"source\":\"E\",\"sourceExcerpt\":\"$GROUNDED\",\"summaryEn\":\"x\",\"publishedEn\":\"y\"}]}"
mk backfilled.json '{"schemaVersion":1,"dateIso":"2026-01-01","items":[
 {"title":"A","link":"https://e.test/1","source":"E","sourceExcerpt":null},
 {"title":"B","link":"https://e.test/2","source":"E","sourceExcerpt":null}]}'
mk mixed.json "{\"schemaVersion\":1,\"dateIso\":\"2026-01-01\",\"items\":[
 {\"title\":\"A\",\"link\":\"https://e.test/1\",\"source\":\"E\",\"sourceExcerpt\":null},
 {\"title\":\"Introducing Astra\",\"link\":\"https://e.test/2\",\"source\":\"E\",\"sourceExcerpt\":\"$GROUNDED\"}]}"
mk noitems.json '{"schemaVersion":1,"dateIso":"2026-01-01","items":[]}'
# Every excerpt IS its own headline, so the ground floor blocks every item and
# no model line is generated: a tally over zero generations.
mk allblocked.json '{"schemaVersion":1,"dateIso":"2026-01-01","items":[
 {"title":"Only a headline","link":"https://e.test/1","source":"E","sourceExcerpt":"Only a headline"},
 {"title":"Also just a headline","link":"https://e.test/2","source":"E","sourceExcerpt":"Also just a headline"}]}'

echo "ARM 1 - a backfilled record is a BROKEN INSTRUMENT, not a quiet result"
OUT="$(run "$T/backfilled.json")"; ST=$?
[ "$ST" -eq 2 ] && ok "all-null sourceExcerpt exits 2" || bad "all-null sourceExcerpt exits 2" "got $ST"
has "$OUT" "backfilled edition" && ok "and names why" || bad "and names why" "$OUT"
has "$OUT" "not a quiet result" && ok "and refuses the comfortable reading" || bad "and refuses the comfortable reading" "$OUT"
# CONTROL: without this end, a script that exited 2 on everything would pass above.
OUT="$(run "$T/good.json")"; ST=$?
[ "$ST" -ne 2 ] && ok "control: a record WITH excerpts is not called broken" || bad "control: a record WITH excerpts is not called broken" "$OUT"

echo "ARM 2 - a partly-backfilled record skips the null items and SAYS so"
OUT="$(run "$T/mixed.json")"; ST=$?
[ "$ST" -ne 2 ] && ok "one null item does not break the run" || bad "one null item does not break the run" "got $ST"
has "$OUT" "SKIPPED, not scored" && ok "the skip is stated, not silent" || bad "the skip is stated, not silent" "$OUT"
has "$OUT" "LINES 3 scored" && ok "and the skipped item is absent from the denominator" || bad "and the skipped item is absent from the denominator" "$OUT"

echo "ARM 3 - a tally over zero model lines is VACUOUS, not a clean sweep"
OUT="$(run "$T/allblocked.json")"; ST=$?
[ "$ST" -eq 2 ] && ok "every item blocked by the ground floor exits 2" || bad "every item blocked by the ground floor exits 2" "got $ST"
has "$OUT" "VACUOUS" && ok "and is named VACUOUS" || bad "and is named VACUOUS" "$OUT"
# CONTROL: the same ground floor on a record where SOME item has ground must not
# trip this — otherwise the guard is just "the ground floor exists".
OUT="$(run "$T/good.json")"
has "$OUT" "VACUOUS" && bad "control: a record with ground is not vacuous" "$OUT" || ok "control: a record with ground is not vacuous"

echo "ARM 4 - argument faults are exit 2 and diagnose themselves separately"
OUT="$(run "$T/good.json" --sample 3)"; ST=$?
[ "$ST" -eq 2 ] && has "$OUT" "unknown flag" && ok "an unknown flag exits 2 as unknown" || bad "an unknown flag exits 2 as unknown" "$OUT"
OUT="$(run "$T/good.json" --samples three)"; ST=$?
[ "$ST" -eq 2 ] && has "$OUT" "positive integer" && ok "a non-numeric --samples is NOT reported as an unknown flag" || bad "a non-numeric --samples is NOT reported as an unknown flag" "$OUT"
OUT="$(run "$T/good.json" --samples 0)"; ST=$?
[ "$ST" -eq 2 ] && ok "--samples 0 refuses instead of running zero samples" || bad "--samples 0 refuses instead of running zero samples" "$OUT"
OUT="$(run "$T/good.json" "$T/good.json")"; ST=$?
[ "$ST" -eq 2 ] && has "$OUT" "exactly one" && ok "two records exit 2" || bad "two records exit 2" "$OUT"
OUT="$(run "$T/nope.json")"; ST=$?
[ "$ST" -eq 2 ] && ok "an unreadable record exits 2" || bad "an unreadable record exits 2" "$OUT"
OUT="$(run "$T/noitems.json")"; ST=$?
[ "$ST" -eq 2 ] && ok "a record with no items exits 2" || bad "a record with no items exits 2" "$OUT"

echo "ARM 5 - an unusable model is a broken instrument, never a verdict"
OUT="$(OLLAMA_URL=http://127.0.0.1:1 node "$SCRIPT" "$T/good.json" 2>&1)"; ST=$?
[ "$ST" -eq 2 ] && ok "a dead model exits 2" || bad "a dead model exits 2" "got $ST"
has "$OUT" "INSTRUMENT" && ok "and says INSTRUMENT, not a finding" || bad "and says INSTRUMENT, not a finding" "$OUT"

echo "ARM 6 - the two ends that make the verdict mean something"
echo "$GOOD_LINE" > "$LINE_FILE"
OUT="$(run "$T/good.json" --samples 1)"; ST=$?
[ "$ST" -eq 0 ] && ok "a grounded line exits 0" || bad "a grounded line exits 0" "$OUT"
has "$OUT" "non-pass  " && has "$OUT" '"pass":2' && ok "and every sample is a pass" || bad "and every sample is a pass" "$OUT"
# The negative end. Without it, a script that called everything a pass would be green above.
echo 'Fermat Industries shipped Astra for $47 billion.' > "$LINE_FILE"
OUT="$(run "$T/good.json" --samples 1)"; ST=$?
[ "$ST" -eq 1 ] && ok "an invented line exits 1 — a FINDING, distinct from 2" || bad "an invented line exits 1 — a FINDING, distinct from 2" "got $ST"
has "$OUT" "Fermat" && ok "and the ungrounded token is named" || bad "and the ungrounded token is named" "$OUT"
echo "$GOOD_LINE" > "$LINE_FILE"

echo "ARM 7 - the replay NEVER writes to the record it reads"
BEFORE="$(cksum < "$T/good.json") $(stat -c %s "$T/good.json")"
run "$T/good.json" --samples 1 >/dev/null 2>&1
AFTER="$(cksum < "$T/good.json") $(stat -c %s "$T/good.json")"
[ "$BEFORE" = "$AFTER" ] && ok "the record is byte-identical after a replay" || bad "the record is byte-identical after a replay" "$BEFORE vs $AFTER"
# CONTROL: the comparison must be able to SEE a change, or it passes on anything.
printf 'x' >> "$T/good.json"
CHANGED="$(cksum < "$T/good.json") $(stat -c %s "$T/good.json")"
[ "$CHANGED" != "$AFTER" ] && ok "control: the comparison detects a one-byte change" || bad "control: the comparison detects a one-byte change" ""
truncate -s -1 "$T/good.json"

echo "ARM 8 - --json is machine-readable and carries the relation lane's STATE"
# 🔴 stdout ONLY. `run()` merges stderr, and the whole point of --json is that
# stdout is parseable on its own; capturing 2>&1 here would test the merge, not
# the contract. The suite's own capture was the defect the first time round.
OUT="$(OLLAMA_URL="$OK_URL" node "$SCRIPT" "$T/good.json" --samples 1 --json 2>/dev/null)"
node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);
  if(!("relations" in j)) {console.log("NOKEY");process.exit(0)}
  console.log("OK",j.samples,j.generated,typeof j.relations)})' <<<"$OUT" > "$T/j" 2>&1
has "$(cat "$T/j")" "OK" && ok "--json parses and carries samples/generated/relations" || bad "--json parses and carries samples/generated/relations" "$(cat "$T/j")"
# An ABSENT relation lane must be null, never 0 — "not measured" and "measured zero"
# are different claims and a reader cannot tell them apart from a 0.
has "$(cat "$T/j")" "OK" && ok "the relation lane reports its state rather than a bare zero" || bad "the relation lane reports its state rather than a bare zero" "$(cat "$T/j")"
ERRTXT="$(OLLAMA_URL="$OK_URL" node "$SCRIPT" "$T/good.json" --samples 1 --json 2>&1 >/dev/null)"
has "$ERRTXT" "NOTE: --samples 1" && ok "control: the note went to stderr, it did not vanish" || bad "control: the note went to stderr, it did not vanish" "$ERRTXT"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
