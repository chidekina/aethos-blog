#!/usr/bin/env bash
# v2026.09.02
# Suite for run-digest.sh — the cron entry point, which is the surface that
# fails silently. Every arm runs the REAL script under `env -i`, the same way
# cron does, rather than inheriting this shell's PATH.
#
#   bash scripts/news/run-digest.test.sh
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/news/run-digest.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { grep -qF -- "$2" <<<"$1"; }

# Runs the script with a fake HOME so the nvm lookup can be controlled, and a
# stub repo so no network call happens. $1 = HOME, rest = extra env assignments.
run() {
  local home="$1"; shift
  local log="$T/log.$RANDOM"
  env -i HOME="$home" PATH=/usr/bin:/bin SHELL=/bin/sh NEWS_DIGEST_LOG="$log" "$@" \
      /bin/sh -c "$SCRIPT" >/dev/null 2>&1
  local st=$?
  printf '%s\n' "$st"
  cat "$log" 2>/dev/null
}

echo "ARM 1 — precondition: cron's PATH really does not reach node"
NODE_ON_CRON_PATH="$(env -i PATH=/usr/bin:/bin /bin/sh -c 'command -v node' 2>/dev/null)"
[ -z "$NODE_ON_CRON_PATH" ] \
  && ok "node absent from /usr/bin:/bin (the trap this script exists for)" \
  || ok "node present at $NODE_ON_CRON_PATH — arms 2-3 still valid, trap simply does not apply here"

echo "ARM 2 — no node anywhere is FATAL with a log line, never a silent 127"
mkdir -p "$T/emptyhome"
OUT2="$(run "$T/emptyhome")"
ST2="$(head -1 <<<"$OUT2")"
[ "$ST2" = 2 ] && ok "missing node -> exit 2" || bad "missing node -> exit 2" "got $ST2"
has "$OUT2" "FATAL" && ok "FATAL is written to the log, not lost to a dead PATH" || bad "FATAL logged" "$OUT2"
# The whole point: the failure must be VISIBLE. A 127 death writes nothing.
[ "$(wc -l <<<"$OUT2")" -ge 2 ] && ok "log is non-empty on failure" || bad "log non-empty on failure" "nothing logged"

echo "ARM 3 — a too-old nvm node is refused by version, not run and left to fail deep"
mkdir -p "$T/oldhome/.nvm/versions/node/v14.21.3/bin"
cat > "$T/oldhome/.nvm/versions/node/v14.21.3/bin/node" <<'STUB'
#!/bin/sh
[ "$1" = "-v" ] && { echo "v14.21.3"; exit 0; }
echo "this stub should never be asked to run the pipeline" >&2; exit 99
STUB
chmod +x "$T/oldhome/.nvm/versions/node/v14.21.3/bin/node"
OUT3="$(run "$T/oldhome")"
ST3="$(head -1 <<<"$OUT3")"
[ "$ST3" = 2 ] && ok "Node 14 -> exit 2" || bad "Node 14 -> exit 2" "got $ST3"
has "$OUT3" "needs Node 18+" && ok "refusal names the version requirement" || bad "version named" "$OUT3"
has "$OUT3" "should never be asked" && bad "stub was not executed" "the old node ran the pipeline" || ok "stub was not executed"

echo "ARM 4 — the newest installed version wins, and sort is version-aware"
mkdir -p "$T/multihome/.nvm/versions/node"/{v9.99.9,v10.0.0,v22.16.0}/bin
for v in v9.99.9 v10.0.0 v22.16.0; do
  printf '#!/bin/sh\n[ "$1" = "-v" ] && { echo "%s"; exit 0; }\necho PICKED_%s\nexit 0\n' "$v" "$v" \
    > "$T/multihome/.nvm/versions/node/$v/bin/node"
  chmod +x "$T/multihome/.nvm/versions/node/$v/bin/node"
done
OUT4="$(run "$T/multihome")"
has "$OUT4" "v22.16.0/bin/node" && ok "newest version selected" || bad "newest version selected" "$OUT4"
# negative control: plain lexicographic sort puts v9 above v10 and v22
has "$OUT4" "v9.99.9/bin/node" && bad "sort is version-aware, not lexicographic" "picked v9 over v22" || ok "sort is version-aware, not lexicographic"

echo "ARM 5 — the three outcomes are distinguishable in the log"
grep -q 'RESULT=ok' "$SCRIPT"               && ok "success case named"  || bad "success case named"
grep -q 'RESULT=nothing-produced' "$SCRIPT" && ok "empty case named"    || bad "empty case named"
grep -q 'RESULT=BROKEN' "$SCRIPT"           && ok "instrument case named" || bad "instrument case named"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
