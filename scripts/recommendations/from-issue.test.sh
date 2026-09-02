#!/usr/bin/env bash
# v2026.09.02
# Suite for from-issue.mjs. Runs the REAL script with a stub `gh` on PATH, so
# the issue-form parser under test is the one the operator runs — never a
# re-typed copy.
#
#   bash scripts/recommendations/from-issue.test.sh
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/recommendations/from-issue.mjs"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/out"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { grep -qF -- "$2" <<<"$1"; }

# Stub gh: echoes whatever JSON the arm put in $T/issue.json.
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "${GH_FAIL:-0}" = 1 ] && { echo "gh: could not find issue" >&2; exit 1; }
cat "$GH_ISSUE_JSON"
GH
chmod +x "$T/bin/gh"

issue() { # $1 = body (markdown), $2 = login
  python3 - "$T/issue.json" "$1" "$2" <<'PYEOF'
import json,sys
json.dump({"number":42,"title":"[rec] x","body":sys.argv[2],
           "author":{"login":sys.argv[3]}}, open(sys.argv[1],'w'))
PYEOF
}

run() { PATH="$T/bin:$PATH" GH_ISSUE_JSON="$T/issue.json" node "$SCRIPT" "$@" 2>&1; }

GOOD='### Title

Latent Space

### URL

https://www.latent.space/

### Category

newsletter

### Why is it worth someone'"'"'s time?

Newsletter on the AI engineer stack.

### Author / creator

_No response_

### Language of the content

en

### Tags

ai, Engineering'

echo "ARM 1 — a well-formed issue parses into a valid entry"
issue "$GOOD" reader1
OUT="$(run 42 --dry-run)"; ST=$?
[ "$ST" = 0 ] && ok "exit 0" || bad "exit 0" "got $ST: $OUT"
has "$OUT" '"title": "Latent Space"' && ok "title parsed" || bad "title parsed" "$OUT"
has "$OUT" '"category": "newsletter"' && ok "category parsed" || bad "category parsed" "$OUT"
has "$OUT" '"recommendedBy": "reader1"' && ok "credited to issue author" || bad "credited to author" "$OUT"
has "$OUT" 'WARNING' && ok "dry-run warns about the colliding slug but still shows the entry" || bad "dry-run collision warning" "$OUT"
has "$OUT" '"engineering"' && ok "tags split and lowercased" || bad "tags lowercased" "$OUT"
# the whole point of the _No response_ handling
has "$OUT" '_No response_' && bad "unanswered optional field omitted" "literal _No response_ leaked into the entry" || ok "unanswered optional field omitted"
has "$OUT" '"author"' && bad "absent author key omitted entirely" "author key present" || ok "absent author key omitted entirely"

echo "ARM 2 — dry-run writes nothing"
[ "$(ls "$REPO/src/content/recommendations" | grep -c latent-space)" = 1 ] \
  && ok "control: the seed file exists (so a write WOULD be visible)" \
  || bad "control: seed file exists" "cannot tell a write from a no-op"

echo "ARM 3 — bad input is rejected, and every problem is named at once"
issue "$(sed 's|https://www.latent.space/|not-a-url|; s|^newsletter$|podcast|' <<<"$GOOD")" reader1
OUT3="$(run 42 --dry-run)"; ST3=$?
[ "$ST3" = 1 ] && ok "invalid input -> exit 1" || bad "invalid input -> exit 1" "got $ST3: $OUT3"
has "$OUT3" "not a valid URL" && ok "bad URL named" || bad "bad URL named" "$OUT3"
has "$OUT3" "category must be one of" && ok "bad category named in the SAME run" || bad "bad category named" "$OUT3"

echo "ARM 4 — over-long description rejected (the schema cap, enforced early)"
LONG="$(python3 -c "print('x'*300)")"
issue "${GOOD/Newsletter on the AI engineer stack./$LONG}" reader1
OUT4="$(run 42 --dry-run)"; ST4=$?
[ "$ST4" = 1 ] && ok "300-char description -> exit 1" || bad "300-char description -> exit 1" "got $ST4"
has "$OUT4" "max 280" && ok "cap named in the message" || bad "cap named" "$OUT4"

echo "ARM 5 — duplicate slug refused, not silently overwritten"
issue "${GOOD/Latent Space/Fireship}" reader2
OUT5="$(run 42)"; ST5=$?
[ "$ST5" = 1 ] && ok "existing file -> exit 1" || bad "existing file -> exit 1" "got $ST5: $OUT5"
has "$OUT5" "already exists" && ok "duplicate named" || bad "duplicate named" "$OUT5"

echo "ARM 6 — gh failing is exit 2 (instrument), never 1 (bad input)"
issue "$GOOD" reader1
OUT6="$(GH_FAIL=1 run 42 --dry-run)"; ST6=$?
[ "$ST6" = 2 ] && ok "gh failure -> exit 2" || bad "gh failure -> exit 2" "got $ST6: $OUT6"
has "$OUT6" "INSTRUMENT" && ok "exit 2 names itself" || bad "exit 2 names itself" "$OUT6"

echo "ARM 7 — no issue number is a usage error, not a silent no-op"
OUT7="$(run --dry-run)"; ST7=$?
[ "$ST7" = 2 ] && ok "missing arg -> exit 2" || bad "missing arg -> exit 2" "got $ST7"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
