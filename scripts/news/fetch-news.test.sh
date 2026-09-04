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
  if(q.url==="/slow"){return setTimeout(()=>{r.writeHead(200,{"content-type":"application/xml"});
    r.end(fs.readFileSync(p+"/good.xml"));},1500);}
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
  # NEWS_EDITIONS_DIR is redirected for the same reason NEWS_SEEN is: without it
  # this suite writes a fixture edition record into the tracked production
  # directory on every run. Measured 2026-09-04 — the first run of the new
  # record writer left scripts/news/editions/2026-09-04.json in the tree,
  # carrying example.test links. A suite's side effects are invisible to the
  # suite by construction; only an outside `git status` shows them.
  NEWS_CONFIG="$1" NEWS_SEEN="$2" NEWS_POSTS_DIR="$3" NEWS_EDITIONS_DIR="$T/editions" \
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

echo "ARM 10 — an unknown argument is exit 2, and known flags still work"
# Closes: `--config <file>` was silently ignored, so a verification run probed
# the live sources.json and reported a clean sweep for candidates it never
# fetched. An ignored flag answers confidently about the wrong input.
OUT10="$(run "$T/c1.json" "$T/seen10.json" "$T/posts10" --config /tmp/whatever.json)"; ST10=$?
[ "$ST10" = 2 ] && ok "unknown flag -> exit 2" || bad "unknown flag -> exit 2" "got $ST10: $OUT10"
has "$OUT10" "INSTRUMENT" && ok "unknown flag names itself an instrument fault" || bad "unknown flag names itself" "$OUT10"
has "$OUT10" "NEWS_CONFIG" && ok "error names the env var that actually works" || bad "error names NEWS_CONFIG" "$OUT10"
# negative control: without it, a script exiting 2 on EVERY invocation passes all three above.
OUT10B="$(run "$T/c1.json" "$T/seen10b.json" "$T/posts10b" --dry-run)"; ST10B=$?
[ "$ST10B" = 0 ] && ok "control: a KNOWN flag is still accepted" || bad "control: known flag accepted" "got $ST10B — guard rejects everything: ARM 10 proves nothing"

echo "ARM 11 — per-source cap is configurable, and a source may lower its own"
cat > "$T/feeds/loud.xml" <<XML
<?xml version="1.0"?><rss version="2.0"><channel>
<item><title>LLM agent testing L1</title><link>https://example.test/L1</link><pubDate>$NOW</pubDate><description>agent testing tdd coverage</description></item>
<item><title>LLM agent testing L2</title><link>https://example.test/L2</link><pubDate>$NOW</pubDate><description>agent testing tdd coverage</description></item>
<item><title>LLM agent testing L3</title><link>https://example.test/L3</link><pubDate>$NOW</pubDate><description>agent testing tdd coverage</description></item>
<item><title>LLM agent testing L4</title><link>https://example.test/L4</link><pubDate>$NOW</pubDate><description>agent testing tdd coverage</description></item>
<item><title>LLM agent testing L5</title><link>https://example.test/L5</link><pubDate>$NOW</pubDate><description>agent testing tdd coverage</description></item>
</channel></rss>
XML
cfg "$T/c11.json" "[{\"name\":\"Loud\",\"url\":\"http://127.0.0.1:$PORT/loud.xml\",\"tag\":\"ai\",\"weight\":3}]"
OUT11="$(run "$T/c11.json" "$T/seen11.json" "$T/posts11" --dry-run)"
N11="$(grep -c 'example.test/L' <<<"$OUT11")"
[ "$N11" = 3 ] && ok "default cap admits 3 of 5 from one source" || bad "default cap" "got $N11 of 5"

cfg "$T/c11b.json" "[{\"name\":\"Loud\",\"url\":\"http://127.0.0.1:$PORT/loud.xml\",\"tag\":\"ai\",\"weight\":3,\"maxPerDigest\":1}]"
OUT11B="$(run "$T/c11b.json" "$T/seen11b.json" "$T/posts11b" --dry-run)"
N11B="$(grep -c 'example.test/L' <<<"$OUT11B")"
[ "$N11B" = 1 ] && ok "maxPerDigest:1 lowers that source to 1" || bad "maxPerDigest override" "got $N11B, want 1"
# negative control: a script ignoring maxPerDigest gives 3 here; one that dropped
# the source gives 0. Both wrong, in opposite directions.
[ "$N11B" -gt 0 ] && ok "control: capped source still contributes, not banned" || bad "control: cap became a ban" "source vanished"

cfg "$T/c11c.json" "[{\"name\":\"Loud\",\"url\":\"http://127.0.0.1:$PORT/loud.xml\",\"tag\":\"ai\",\"weight\":3}]"
python3 - "$T/c11c.json" <<'PYEOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['maxPerSource']=2; json.dump(d,open(p,'w'))
PYEOF
OUT11C="$(run "$T/c11c.json" "$T/seen11c.json" "$T/posts11c" --dry-run)"
N11C="$(grep -c 'example.test/L' <<<"$OUT11C")"
[ "$N11C" = 2 ] && ok "global maxPerSource is honoured (2)" || bad "global maxPerSource" "got $N11C, want 2"

echo "ARM 12 — a source may raise its own fetch timeout"
# /slow stalls ~1.5s. At a 300ms budget it must fail; the SAME feed with its own
# timeoutMs must succeed. Without the failing end, a script ignoring timeoutMs
# passes the success case anyway.
cfg "$T/c12.json" "[{\"name\":\"Slow\",\"url\":\"http://127.0.0.1:$PORT/slow\",\"tag\":\"ai\",\"weight\":3}]"
OUT12="$(NEWS_FETCH_TIMEOUT_MS=300 run "$T/c12.json" "$T/seen12.json" "$T/posts12" --check-sources)"; ST12=$?
has "$OUT12" "timeout after 300ms" && ok "slow feed times out at the shared default" || bad "slow feed times out" "$OUT12"
[ "$ST12" = 2 ] && ok "only feed timing out is an instrument fault" || bad "timeout -> exit 2" "got $ST12"

cfg "$T/c12b.json" "[{\"name\":\"Slow\",\"url\":\"http://127.0.0.1:$PORT/slow\",\"tag\":\"ai\",\"weight\":3,\"timeoutMs\":8000}]"
OUT12B="$(NEWS_FETCH_TIMEOUT_MS=300 run "$T/c12b.json" "$T/seen12b.json" "$T/posts12b" --check-sources)"; ST12B=$?
[ "$ST12B" = 0 ] && ok "per-source timeoutMs overrides the shared default" || bad "timeoutMs override" "got $ST12B: $OUT12B"
has "$OUT12B" "1/1 feeds reachable" && ok "the same slow feed is reachable with its own budget" || bad "slow feed reachable" "$OUT12B"
echo "ARM 13 — a malformed numeric knob is exit 2, never an absent limit"
# Found in review of PR #10: Number("three") is NaN and `n >= NaN` is always
# false, so a typo'd cap silently admitted EVERY item from that source — the
# exact firehose the cap exists to stop, arriving as a config typo.
cfg "$T/c13.json" "[{\"name\":\"Loud\",\"url\":\"http://127.0.0.1:$PORT/loud.xml\",\"tag\":\"ai\",\"weight\":3,\"maxPerDigest\":\"three\"}]"
OUT13="$(run "$T/c13.json" "$T/seen13.json" "$T/posts13" --dry-run)"; ST13=$?
[ "$ST13" = 2 ] && ok "non-numeric maxPerDigest -> exit 2" || bad "non-numeric maxPerDigest -> exit 2" "got $ST13: $OUT13"
has "$OUT13" "INSTRUMENT" && ok "malformed knob names itself an instrument fault" || bad "malformed knob names itself" "$OUT13"
# the regression assertion: it must not have silently admitted everything
N13="$(grep -c 'example.test/L' <<<"$OUT13")"
[ "$N13" = 0 ] && ok "malformed cap admits nothing (no silent firehose)" || bad "malformed cap leaked items" "got $N13 items through a NaN cap"

cfg "$T/c13b.json" "[{\"name\":\"Loud\",\"url\":\"http://127.0.0.1:$PORT/loud.xml\",\"tag\":\"ai\",\"weight\":3,\"timeoutMs\":\"soon\"}]"
OUT13B="$(run "$T/c13b.json" "$T/seen13b.json" "$T/posts13b" --dry-run)"; ST13B=$?
[ "$ST13B" = 2 ] && ok "non-numeric timeoutMs -> exit 2" || bad "non-numeric timeoutMs -> exit 2" "got $ST13B: $OUT13B"

cfg "$T/c13c.json" "[{\"name\":\"Loud\",\"url\":\"http://127.0.0.1:$PORT/loud.xml\",\"tag\":\"ai\",\"weight\":3}]"
python3 - "$T/c13c.json" <<'PYEOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['maxPerSource']=0; json.dump(d,open(p,'w'))
PYEOF
OUT13C="$(run "$T/c13c.json" "$T/seen13c.json" "$T/posts13c" --dry-run)"; ST13C=$?
[ "$ST13C" = 2 ] && ok "maxPerSource: 0 is refused, not read as 'block everything'" || bad "zero cap refused" "got $ST13C"
# negative control: valid values must STILL run, or a validator that rejected
# everything would pass all five assertions above.
cfg "$T/c13d.json" "[{\"name\":\"Loud\",\"url\":\"http://127.0.0.1:$PORT/loud.xml\",\"tag\":\"ai\",\"weight\":3,\"maxPerDigest\":2,\"timeoutMs\":8000}]"
OUT13D="$(run "$T/c13d.json" "$T/seen13d.json" "$T/posts13d" --dry-run)"; ST13D=$?
[ "$ST13D" = 0 ] && ok "control: valid numeric knobs still run" || bad "control: valid knobs run" "got $ST13D — validator rejects everything: ARM 13 proves nothing"
N13D="$(grep -c 'example.test/L' <<<"$OUT13D")"
[ "$N13D" = 2 ] && ok "control: the valid cap is still applied (2)" || bad "control: valid cap applied" "got $N13D"
echo "ARM 14 — a wedged runner is caught: the catalogue answering is not generation working"
# Measured 2026-09-03: llama3.2:3b's runner sat at 0.0% CPU for 51 minutes while
# every /api/generate timed out at 600s — and /api/tags answered in under a
# second throughout, so the liveness check passed and the digest hung forever.
# Same false-green as pg_isready proving *a* postgres listens rather than yours.
OPORT=$(( 20000 + RANDOM % 20000 ))
node -e '
const http=require("http");
http.createServer((q,r)=>{
  if(q.url==="/api/tags"){r.writeHead(200,{"content-type":"application/json"});
    return r.end(JSON.stringify({models:[{name:"llama3.2:3b"}]}));}
  // /api/generate: accept the request and never answer — a wedged runner
}).listen(process.argv[1]);
' "$OPORT" &
OSRV_PID=$!
for _ in $(seq 1 40); do curl -sf -m1 "http://127.0.0.1:$OPORT/api/tags" >/dev/null && break; done

OUT14="$(OLLAMA_URL="http://127.0.0.1:$OPORT" NEWS_PROBE_TIMEOUT_MS=2000 \
  run "$T/c1.json" "$T/seen14.json" "$T/posts14")"; ST14=$?
kill "$OSRV_PID" 2>/dev/null
[ "$ST14" = 2 ] && ok "catalogue-ok / generation-wedged -> exit 2" || bad "wedged runner -> exit 2" "got $ST14: $OUT14"
has "$OUT14" "generation did not respond within" \
  && ok "the log reports the generation probe failing, which is what it observed" \
  || bad "log reports the probe failure" "$OUT14"
# 🔴 This stub answers /api/tags and nothing else, so /api/ps does not answer
# either. The message must say so instead of converting an unreadable reader
# into an empty subject. Before 2026-09-04 it printed "Nothing is reported
# loaded, so this looks like a genuinely wedged runner" — a cause asserted from
# a timeout it never distinguished from an empty list.
has "$OUT14" "could NOT be read" \
  && ok "and names /api/ps as unreadable rather than as empty" || bad "unreadable ps reported as empty" "$OUT14"
has "$OUT14" "genuinely wedged" \
  && bad "it still asserts a cause the data cannot support" "$OUT14" \
  || ok "and asserts no cause the data cannot support"
[ -d "$T/posts14" ] && bad "no drafts written when generation is wedged" "posts dir exists" || ok "no drafts written when generation is wedged"

# negative control: a server answering BOTH endpoints must pass the probe, or a
# check that always failed would satisfy all three assertions above.
OPORT2=$(( 20000 + RANDOM % 20000 ))
node -e '
const http=require("http");
http.createServer((q,r)=>{
  r.writeHead(200,{"content-type":"application/json"});
  if(q.url==="/api/tags") return r.end(JSON.stringify({models:[{name:"llama3.2:3b"}]}));
  r.end(JSON.stringify({response:"a summary sentence"}));
}).listen(process.argv[1]);
' "$OPORT2" &
OSRV2_PID=$!
for _ in $(seq 1 40); do curl -sf -m1 "http://127.0.0.1:$OPORT2/api/tags" >/dev/null && break; done
OUT14B="$(OLLAMA_URL="http://127.0.0.1:$OPORT2" NEWS_PROBE_TIMEOUT_MS=5000 \
  run "$T/c1.json" "$T/seen14b.json" "$T/posts14b")"; ST14B=$?
kill "$OSRV2_PID" 2>/dev/null
[ "$ST14B" = 0 ] && ok "control: a responsive server passes the probe" || bad "control: responsive server passes" "got $ST14B — probe fails everything: ARM 14 proves nothing: $OUT14B"
[ -d "$T/posts14b" ] && ok "control: drafts ARE written when generation works" || bad "control: drafts written" "probe blocked a healthy run"
echo "ARM 15 — the edition record is written, and the entity check actually runs"
# DIGEST-EVAL item 2. The draft half of the eval pair has to be captured on
# purpose; edition 1 was recoverable only by git archaeology and only by luck.
E15="$T/ed15"
OUT15="$(NEWS_EDITIONS_DIR="$E15" NEWS_CONFIG="$T/c1.json" NEWS_SEEN="$T/seen15.json" \
  NEWS_POSTS_DIR="$T/posts15" node "$SCRIPT" --no-llm 2>&1)"
REC15="$(command ls "$E15"/*.json 2>/dev/null | head -1)"
[ -n "$REC15" ] && ok "a record lands in NEWS_EDITIONS_DIR" || bad "no edition record written" "$OUT15"
if [ -n "$REC15" ]; then
  # The record must carry the SOURCE text, not only the summaries: without the
  # ground the pair is unusable as an eval set, which is the whole point of it.
  node -e '
    const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const it=r.items[0]||{};
    console.log("v="+r.schemaVersion+" n="+r.items.length+" pub="+String(r.published)
      +" ground="+(it.sourceExcerpt?"yes":"no")+" link="+(it.link?"yes":"no"));
  ' "$REC15" > "$T/rec15.txt" 2>&1
  R15="$(command cat "$T/rec15.txt")"
  has "$R15" "v=1" && has "$R15" "ground=yes" && has "$R15" "link=yes" \
    && ok "and it carries the source excerpt and link per item" || bad "record shape" "$R15"
  has "$R15" "n=0" && bad "record has zero items — it proves nothing" "$R15" || ok "and it is not an empty record"
  has "$R15" "pub=null" && ok "the published half starts null, to be filled after review" || bad "published half" "$R15"
fi
has "$OUT15" "ENTITY_CHECK" && ok "the entity check is INVOKED by the pipeline, not merely present on disk" \
  || bad "entity check never ran" "$OUT15"
# 🔴 Under --no-llm the check has NO POWER: the PT line is a copy of the EN line
# and each summary is a slice of its own excerpt. It must say so. Measured
# 2026-09-04, before this assertion existed, the same run logged
# "0 ungrounded finding(s) ... 42 tokens checked" — a reassuring zero out of 42
# tokens not one of which could have been missing.
has "$OUT15" "ENTITY_CHECK VACUOUS" \
  && ok "and it declares itself VACUOUS under --no-llm instead of reporting a clean zero" \
  || bad "a powerless check reported a reassuring zero" "$OUT15"
has "$OUT15" "ENTITY_CHECK 0 ungrounded" \
  && bad "it still printed the reassuring zero line as well" "$OUT15" \
  || ok "and the reassuring line is suppressed, not printed alongside"

# Both ends. A run that writes no draft must write no record — a record of an
# edition that never reached disk is a lie about what the model produced. This
# reuses the seen.json from the run above, so every link is already seen.
OUT15B="$(NEWS_EDITIONS_DIR="$T/ed15b" NEWS_CONFIG="$T/c1.json" NEWS_SEEN="$T/seen15.json" \
  NEWS_POSTS_DIR="$T/posts15b" node "$SCRIPT" --no-llm 2>&1)"
[ -z "$(command ls "$T/ed15b" 2>/dev/null)" ] \
  && ok "negative control: no draft written, so no record written" \
  || bad "a record was written for an edition that produced no draft" "$OUT15B"

echo "ARM 16 - a blocked load names the model HOLDING the slot, not ours"
# Measured 2026-09-04: a 4096 MiB GPU cannot hold llama3.2:3b (2.8 GB at ctx
# 4096) beside nomic-embed-text (595 MB), and ollama WAITS for a slot instead
# of evicting. The runner spawns, answers its own /health with
# {"status":2,"progress":0}, and never advances. The old advice - `ollama stop
# <our model>` - does nothing there: the model to stop is the OTHER one. A cold
# load with the slot free takes 7 s, so the timeout was never the problem.
#
# Servers start INLINE, mirroring ARM 14. A helper that backgrounded the server
# and returned its PID through $( ) hung the whole suite: command substitution
# waits for stdout to CLOSE, and redirecting the child did not release it.
OP16=$(( 20000 + RANDOM % 20000 ))
node -e '
const http=require("http"); const PS=process.argv[2];
http.createServer((q,r)=>{
  if(q.url==="/api/tags"){r.writeHead(200,{"content-type":"application/json"});
    return r.end(JSON.stringify({models:[{name:"llama3.2:3b"}]}));}
  if(q.url==="/api/ps"){r.writeHead(200,{"content-type":"application/json"});return r.end(PS);}
  // /api/generate: accept and never answer -- a load that never completes
}).listen(process.argv[1]);
' "$OP16" '{"models":[{"name":"nomic-embed-text:latest","size_vram":595000000},{"name":"llama3.2:3b","size_vram":2750261248}]}' &
P16=$!
for _ in $(seq 1 40); do curl -sf -m1 "http://127.0.0.1:$OP16/api/tags" >/dev/null && break; done
OUT16="$(OLLAMA_URL="http://127.0.0.1:$OP16" NEWS_PROBE_TIMEOUT_MS=2000 \
  run "$T/c1.json" "$T/seen16.json" "$T/posts16")"; ST16=$?
kill "$P16" 2>/dev/null
[ "$ST16" = 2 ] && ok "a blocked load is still exit 2" || bad "blocked load exit $ST16" "$OUT16"
has "$OUT16" "ollama stop nomic-embed-text:latest" \
  && ok "the log names the OTHER model as the one to stop" || bad "log does not name the blocker" "$OUT16"
has "$OUT16" "stopping llama3.2:3b would do nothing" \
  && ok "and says plainly that stopping ours would not help" || bad "the misleading advice survives" "$OUT16"

# Both ends. With only OUR model loaded the advice must flip back, otherwise
# the new branch is just a different fixed string.
OP16B=$(( 20000 + RANDOM % 20000 ))
node -e '
const http=require("http"); const PS=process.argv[2];
http.createServer((q,r)=>{
  if(q.url==="/api/tags"){r.writeHead(200,{"content-type":"application/json"});
    return r.end(JSON.stringify({models:[{name:"llama3.2:3b"}]}));}
  if(q.url==="/api/ps"){r.writeHead(200,{"content-type":"application/json"});return r.end(PS);}
  // /api/generate: accept and never answer -- a load that never completes
}).listen(process.argv[1]);
' "$OP16B" '{"models":[{"name":"llama3.2:3b","size_vram":2750261248}]}' &
P16B=$!
for _ in $(seq 1 40); do curl -sf -m1 "http://127.0.0.1:$OP16B/api/tags" >/dev/null && break; done
OUT16B="$(OLLAMA_URL="http://127.0.0.1:$OP16B" NEWS_PROBE_TIMEOUT_MS=2000 \
  run "$T/c1.json" "$T/seen16b.json" "$T/posts16b")"
kill "$P16B" 2>/dev/null
has "$OUT16B" "wedged rather than blocked" \
  && ok "only-ours-loaded flips the advice back to stopping ours" || bad "advice did not adapt" "$OUT16B"
has "$OUT16B" "nomic" && bad "it named a model that is not loaded" "$OUT16B" || ok "and it invents no blocker that is not there"

echo "ARM 17 - an EMPTY /api/ps names both hypotheses and picks neither"
# The third reading of /api/ps, and the one that produced RESULT=BROKEN on the
# 2026-09-04 cron rehearsal: the endpoint answers 200 with an empty list. A load
# queued waiting for a slot is invisible there BY CONSTRUCTION, so this reading
# is produced both by a genuinely wedged runner and by a card that was held and
# released. Naming one is a guess; the old code named the one whose fix cannot
# work.
OP17=$(( 20000 + RANDOM % 20000 ))
node -e '
const http=require("http");
http.createServer((q,r)=>{
  if(q.url==="/api/tags"){r.writeHead(200,{"content-type":"application/json"});
    return r.end(JSON.stringify({models:[{name:"llama3.2:3b"}]}));}
  if(q.url==="/api/ps"){r.writeHead(200,{"content-type":"application/json"});
    return r.end(JSON.stringify({models:[]}));}
  // /api/generate: accept and never answer
}).listen(process.argv[1]);
' "$OP17" &
P17=$!
for _ in $(seq 1 40); do curl -sf -m1 "http://127.0.0.1:$OP17/api/tags" >/dev/null && break; done
OUT17="$(OLLAMA_URL="http://127.0.0.1:$OP17" NEWS_PROBE_TIMEOUT_MS=2000 \
  run "$T/c1.json" "$T/seen17.json" "$T/posts17")"; ST17=$?
kill "$P17" 2>/dev/null
[ "$ST17" = 2 ] && ok "an empty ps is still exit 2" || bad "empty ps exit $ST17" "$OUT17"
has "$OUT17" "does not identify the cause" \
  && ok "the log says plainly that the reading identifies no cause" || bad "it still picks a cause" "$OUT17"
has "$OUT17" "invisible there by construction" \
  && ok "and names WHY the reading is ambiguous, not just that it is" || bad "ambiguity asserted without its mechanism" "$OUT17"
has "$OUT17" "ollama stop llama3.2:3b" \
  && bad "it still sends the operator to stop the model that stopping cannot help" "$OUT17" \
  || ok "and does not prescribe the fix that measurement refuted"
# Both ends. An empty ps and an UNREADABLE ps must not render identically —
# otherwise the queried/empty split this arm exists for buys nothing.
has "$OUT17" "could NOT be read" \
  && bad "empty ps and unreadable ps render the same" "$OUT17" \
  || ok "control: an empty ps reads differently from an unreadable one"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
