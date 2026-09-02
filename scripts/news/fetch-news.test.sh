#!/usr/bin/env bash
# v2026.09.02
# Suite for the news digest. Runs the REAL script against fixture feeds served
# from a local HTTP server — never a re-typed copy of its predicates, because a
# re-typed predicate measures the copy and not what cron runs.
#
#   bash scripts/news/fetch-news.test.sh
#
# Every arm carries both ends: a case that must pass AND the negative control
# that would also pass if the instrument were blind.
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/news/fetch-news.mjs"
T="$(mktemp -d)"
trap 'rm -rf "$T"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
# here-string, never `| grep -q`: under pipefail a producer killed by SIGPIPE
# reports 141 and a match that DID happen reads as a failure.
has()  { grep -qF -- "$2" <<<"$1"; }

# ── fixture feeds ─────────────────────────────────────────────────────────
mkdir -p "$T/feeds"
NOW="$(date -u '+%a, %d %b %Y %H:%M:%S GMT')"

cat > "$T/feeds/good.xml" <<XML
<?xml version="1.0"?><rss version="2.0"><channel>
<item><title>New LLM agent testing framework ships</title><link>https://example.test/a</link>
<pubDate>$NOW</pubDate><description>An eval harness for agents with TDD support.</description></item>
<item><title>OpenAI&#8217;s router lands</title><link>https://example.test/b</link>
<pubDate>$NOW</pubDate><description>Model routing for inference workloads.</description></item>
<item><title>Crypto NFT valuation soars</title><link>https://example.test/blocked</link>
<pubDate>$NOW</pubDate><description>An llm-adjacent crypto NFT story about valuation.</description></item>
<item><title>Local bake sale</title><link>https://example.test/dull</link>
<pubDate>$NOW</pubDate><description>Cakes.</description></item>
</channel></rss>
XML

cat > "$T/feeds/atom.xml" <<XML
<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
<entry><title>Vitest coverage gains</title><link rel="alternate" href="https://example.test/atom1"/>
<updated>$(date -u '+%Y-%m-%dT%H:%M:%SZ')</updated><summary>Testing and coverage for typescript.</summary></entry>
</feed>
XML

PORT=$(( 20000 + RANDOM % 20000 ))
node -e '
const http=require("http"),fs=require("fs"),p=process.argv[1];
http.createServer((q,r)=>{
  const f=p+"/"+q.url.replace(/^\//,"").replace(/[^a-z0-9._-]/gi,"");
  if(q.url==="/dead"){r.writeHead(500);return r.end("boom");}
  try{r.writeHead(200,{"content-type":"application/xml"});r.end(fs.readFileSync(f));}
  catch{r.writeHead(404);r.end("nope");}
}).listen(process.argv[2]);
' "$T/feeds" "$PORT" &
SRV_PID=$!
for _ in $(seq 1 40); do curl -sf -m1 "http://127.0.0.1:$PORT/good.xml" >/dev/null && break; done

cfg() { # $1 = destination, $2 = sources json array
  cat > "$1" <<JSON
{ "maxAgeDays": 8, "maxItems": 8, "minScore": 4,
  "sources": $2,
  "keywords": { "llm": 3, "agent": 2, "test": 3, "testing": 3, "tdd": 3, "coverage": 2, "typescript": 2, "inference": 2, "router": 2, "model": 1 },
  "blocklist": ["crypto", "nft", "valuation"] }
JSON
}

run() { # env-isolated invocation of the real script
  NEWS_CONFIG="$1" NEWS_SEEN="$2" NEWS_POSTS_DIR="$3" \
    node "$SCRIPT" "${@:4}" 2>&1
}

echo "ARM 1 — shortlist: relevant in, blocked and dull out"
cfg "$T/c1.json" "[{\"name\":\"Good\",\"url\":\"http://127.0.0.1:$PORT/good.xml\",\"tag\":\"ai\",\"weight\":2}]"
OUT="$(run "$T/c1.json" "$T/seen1.json" "$T/posts1" --dry-run)"; ST=$?
[ "$ST" = 0 ] && ok "exit 0 with items" || bad "exit 0 with items" "got $ST"
has "$OUT" "https://example.test/a" && ok "relevant item shortlisted" || bad "relevant item shortlisted" "$OUT"
# negative control: without these, a script that shortlisted EVERYTHING passes above
has "$OUT" "https://example.test/blocked" && bad "blocklist drops crypto/NFT item" "blocked item present" || ok "blocklist drops crypto/NFT item"
has "$OUT" "https://example.test/dull" && bad "minScore drops irrelevant item" "dull item present" || ok "minScore drops irrelevant item"

echo "ARM 2 — numeric HTML entities decoded in titles"
has "$OUT" "OpenAI’s" && ok "&#8217; decoded to curly apostrophe" || bad "&#8217; decoded" "$OUT"
has "$OUT" "&#8217;" && bad "raw entity absent" "raw entity still present" || ok "raw entity absent"

echo "ARM 3 — Atom feeds parse, not just RSS"
cfg "$T/c3.json" "[{\"name\":\"Atom\",\"url\":\"http://127.0.0.1:$PORT/atom.xml\",\"tag\":\"testing\",\"weight\":2}]"
OUT3="$(run "$T/c3.json" "$T/seen3.json" "$T/posts3" --dry-run)"
has "$OUT3" "https://example.test/atom1" && ok "atom entry shortlisted" || bad "atom entry shortlisted" "$OUT3"

echo "ARM 4 — every feed dead is exit 2 (instrument), never a quiet news day"
cfg "$T/c4.json" "[{\"name\":\"Dead\",\"url\":\"http://127.0.0.1:$PORT/dead\",\"tag\":\"ai\",\"weight\":1}]"
OUT4="$(run "$T/c4.json" "$T/seen4.json" "$T/posts4" --dry-run)"; ST4=$?
[ "$ST4" = 2 ] && ok "all feeds dead -> exit 2" || bad "all feeds dead -> exit 2" "got $ST4: $OUT4"
has "$OUT4" "INSTRUMENT" && ok "exit 2 names itself an instrument fault" || bad "exit 2 names itself" "$OUT4"

echo "ARM 5 — reachable feeds with nothing relevant is exit 1, not exit 2"
cfg "$T/c5.json" "[{\"name\":\"Good\",\"url\":\"http://127.0.0.1:$PORT/good.xml\",\"tag\":\"ai\",\"weight\":1}]"
python3 - "$T/c5.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['minScore']=999; json.dump(d,open(p,'w'))
PY
OUT5="$(run "$T/c5.json" "$T/seen5.json" "$T/posts5" --dry-run)"; ST5=$?
[ "$ST5" = 1 ] && ok "quiet week -> exit 1 (distinct from 2)" || bad "quiet week -> exit 1" "got $ST5: $OUT5"
has "$OUT5" "NO_NEW_ITEMS" && ok "quiet week says so explicitly" || bad "quiet week says so" "$OUT5"

echo "ARM 6 — seen.json suppresses a repeat, and only after files exist"
cfg "$T/c6.json" "[{\"name\":\"Good\",\"url\":\"http://127.0.0.1:$PORT/good.xml\",\"tag\":\"ai\",\"weight\":2}]"
printf '{"links":["https://example.test/a","https://example.test/b"]}\n' > "$T/seen6.json"
OUT6="$(run "$T/c6.json" "$T/seen6.json" "$T/posts6" --dry-run)"; ST6=$?
[ "$ST6" = 1 ] && ok "already-seen links suppressed" || bad "already-seen links suppressed" "got $ST6: $OUT6"
# positive control on the SAME fixture: with an empty seen file the same run must find them
printf '{"links":[]}\n' > "$T/seen6b.json"
OUT6B="$(run "$T/c6.json" "$T/seen6b.json" "$T/posts6" --dry-run)"
has "$OUT6B" "https://example.test/a" && ok "control: unseen links still found" || bad "control: unseen links still found" "predicate is blind — ARM 6 proves nothing"

echo "ARM 7 — --dry-run writes nothing"
[ -d "$T/posts1" ] && bad "dry-run creates no posts dir" "posts1 exists" || ok "dry-run creates no posts dir"
[ -f "$T/seen1.json" ] && bad "dry-run does not touch seen.json" "seen1 written" || ok "dry-run does not touch seen.json"

echo "ARM 8 — a real write produces BOTH languages, both drafts"
OUT8="$(run "$T/c1.json" "$T/seen8.json" "$T/posts8" --no-llm)"; ST8=$?
[ "$ST8" = 0 ] && ok "write run exits 0" || bad "write run exits 0" "got $ST8: $OUT8"
N="$(ls "$T/posts8" 2>/dev/null | wc -l)"
[ "$N" = 2 ] && ok "two files written (en + pt)" || bad "two files written" "got $N"
DRAFTS="$(grep -l 'draft: true' "$T/posts8"/*.mdx 2>/dev/null | wc -l)"
[ "$DRAFTS" = 2 ] && ok "both files are drafts" || bad "both files are drafts" "got $DRAFTS with draft: true"
[ -s "$T/seen8.json" ] && ok "seen.json updated after a real write" || bad "seen.json updated" "empty/missing"

echo "ARM 9 — a feed with no dates is named and capped, not silently immortal"
cat > "$T/feeds/nodate.xml" <<XML
<?xml version="1.0"?><rss version="2.0"><channel>
<item><title>LLM agent testing one</title><link>https://example.test/n1</link><description>agent testing tdd</description></item>
<item><title>LLM agent testing two</title><link>https://example.test/n2</link><description>agent testing tdd</description></item>
<item><title>LLM agent testing three</title><link>https://example.test/n3</link><description>agent testing tdd</description></item>
</channel></rss>
XML
cfg "$T/c9.json" "[{\"name\":\"NoDate\",\"url\":\"http://127.0.0.1:$PORT/nodate.xml\",\"tag\":\"ai\",\"weight\":3}]"
python3 - "$T/c9.json" <<'PYEOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['maxUndated']=2; json.dump(d,open(p,'w'))
PYEOF
OUT9="$(run "$T/c9.json" "$T/seen9.json" "$T/posts9" --dry-run)"
has "$OUT9" "NO DATES" && ok "dateless feed is named in the output" || bad "dateless feed named" "$OUT9"
N9="$(grep -c 'example.test/n' <<<"$OUT9")"
[ "$N9" = 2 ] && ok "undated items capped at maxUndated (2 of 3)" || bad "undated cap" "got $N9 of 3"
# negative control: capped must not mean banned — without it a generator that
# dropped every undated item would pass the assertion above just as well.
[ "$N9" -gt 0 ] && ok "control: undated items are still included, not dropped" || bad "control: undated still included" "cap became a ban"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
