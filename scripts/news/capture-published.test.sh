#!/usr/bin/env bash
# v2026.09.04
# Suite for the published-half capture (DIGEST-EVAL item 2).
# Runs the REAL script against fixture posts; both ends on every arm.
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/news/capture-published.mjs"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { grep -qF -- "$2" <<<"$1"; }

[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT missing"; exit 1; }
node --check "$SCRIPT" || { echo "FATAL: $SCRIPT does not parse"; exit 1; }

mkrec() { # $1 path
  cat > "$1" <<'JSON'
{"schemaVersion":1,"dateIso":"2026-09-07","generatedAt":"2026-09-07T08:00:00Z","llm":true,
 "model":"llama3.2:3b","drafts":[],"published":null,
 "items":[
  {"title":"A ships","link":"https://e.test/a","source":"S","score":9,
   "sourceExcerpt":"A ships with GPT-4.","summaryEn":"A ships with GPT-4.","summaryPt":"A chega com GPT-4."},
  {"title":"B ships","link":"https://e.test/b","source":"S","score":8,
   "sourceExcerpt":"B ships too.","summaryEn":"B ships too.","summaryPt":"B também chega."}]}
JSON
}

mkpost() { # $1 file  $2 draftflag  $3 body
  cat > "$1" <<POST
---
title: "Radar"
date: 2026-09-07
lang: "en"
draft: $2
---

$3
POST
}

BODY_BOTH='### [A ships](https://e.test/a)

A ships, and the reviewer rewrote this line entirely.

<small>S · 2026-09-07</small>

### [B ships](https://e.test/b)

B ships too.

<small>S · 2026-09-07</small>'

BODY_ONE='### [A ships](https://e.test/a)

A ships, and the reviewer rewrote this line entirely.

<small>S · 2026-09-07</small>'

echo "ARM 1 — refuses while the post is still a draft"
P="$T/p1"; mkdir -p "$P"; mkrec "$T/r1.json"
mkpost "$P/2026-09-07-radar-ai-dev.mdx" true "$BODY_BOTH"
mkpost "$P/2026-09-07-radar-ai-dev-pt.mdx" false "$BODY_BOTH"
OUT="$(NEWS_POSTS_DIR="$P" node "$SCRIPT" "$T/r1.json" 2>&1)"; rc=$?
[ $rc -eq 1 ] && ok "still-draft is exit 1, not a successful capture" || bad "draft capture exit $rc (expected 1)" "$OUT"
has "$OUT" "NOT_PUBLISHED" && ok "and it says so by name" || bad "no NOT_PUBLISHED line" "$OUT"
node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).published===null?0:1)' "$T/r1.json" \
  && ok "and the record was left untouched" || bad "it wrote a published half from a draft" ""

echo "ARM 2 — captures a real publish, keyed by link"
P="$T/p2"; mkdir -p "$P"; mkrec "$T/r2.json"
mkpost "$P/2026-09-07-radar-ai-dev.mdx" false "$BODY_BOTH"
mkpost "$P/2026-09-07-radar-ai-dev-pt.mdx" false "$BODY_BOTH"
OUT="$(NEWS_POSTS_DIR="$P" node "$SCRIPT" "$T/r2.json" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "a published edition captures with exit 0" || bad "capture exit $rc" "$OUT"
R="$(node -e '
const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
const a=r.items.find(i=>i.link==="https://e.test/a");
console.log("kept="+r.published.kept+" cut="+r.published.cut+" verbatim="+r.published.survivedVerbatimEn);
console.log("aPub="+JSON.stringify(a.publishedEn)+" aDraft="+JSON.stringify(a.summaryEn));
' "$T/r2.json" 2>&1)"
has "$R" "kept=2 cut=0" && ok "both items recorded as kept" || bad "kept/cut wrong" "$R"
# The pair is only worth anything if the two halves DIFFER where the human
# rewrote. A capture that copied the draft into publishedEn would satisfy every
# count above and be entirely useless as an eval set.
has "$R" 'aPub="A ships, and the reviewer rewrote this line entirely."' \
  && ok "the published line is the HUMAN's text, not the draft's" || bad "published half is not the post body" "$R"
has "$R" "verbatim=1" && ok "and survivedVerbatimEn counts only the untouched one" || bad "verbatim count" "$R"

echo "ARM 3 — an item the human CUT is recorded as cut, not as missing data"
P="$T/p3"; mkdir -p "$P"; mkrec "$T/r3.json"
mkpost "$P/2026-09-07-radar-ai-dev.mdx" false "$BODY_ONE"
mkpost "$P/2026-09-07-radar-ai-dev-pt.mdx" false "$BODY_ONE"
OUT="$(NEWS_POSTS_DIR="$P" node "$SCRIPT" "$T/r3.json" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "dropping an item is a normal publish, exit 0" || bad "cut item exit $rc" "$OUT"
R="$(node -e '
const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
const b=r.items.find(i=>i.link==="https://e.test/b");
console.log("kept="+r.published.kept+" cut="+r.published.cut+" bKept="+b.keptByHuman+" bPub="+String(b.publishedEn));
' "$T/r3.json" 2>&1)"
has "$R" "kept=1 cut=1" && ok "the cut is counted" || bad "cut not counted" "$R"
has "$R" "bKept=false bPub=null" && ok "and the cut item carries keptByHuman:false, a label with signal" || bad "cut item shape" "$R"

echo "ARM 4 — broken instrument is never a verdict about the review"
P="$T/p4"; mkdir -p "$P"; mkrec "$T/r4.json"
# Every link changed: the parser matches nothing. Indistinguishable from
# "the human cut all 8" unless the script refuses.
mkpost "$P/2026-09-07-radar-ai-dev.mdx" false '### [X](https://other.test/x)

X.

<small>S · 2026-09-07</small>'
mkpost "$P/2026-09-07-radar-ai-dev-pt.mdx" false '### [X](https://other.test/x)

X.

<small>S · 2026-09-07</small>'
OUT="$(NEWS_POSTS_DIR="$P" node "$SCRIPT" "$T/r4.json" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "zero matches is exit 2, a broken instrument" || bad "zero-match exit $rc (expected 2)" "$OUT"
has "$OUT" "not a verdict about the review" && ok "and it says which two states it refuses to conflate" || bad "no reason given" "$OUT"
OUT="$(NEWS_POSTS_DIR="$T/nope" node "$SCRIPT" "$T/r4.json" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "absent post files are exit 2" || bad "missing posts exit $rc" "$OUT"
OUT="$(node "$SCRIPT" "$T/nothing.json" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "an unreadable record is exit 2" || bad "missing record exit $rc" "$OUT"
OUT="$(node "$SCRIPT" --json "$T/r4.json" 2>&1)"; rc=$?
[ $rc -eq 2 ] && has "$OUT" "unknown argument" && ok "an unknown flag refuses to run" || bad "unknown flag ignored" "$OUT"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
