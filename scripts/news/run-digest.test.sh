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
  # NEWS_PATH_PREPEND points at nothing so the node lookup CANNOT be satisfied by
  # whatever this machine happens to have installed. Measured 2026-09-02: on a
  # GitHub runner node sits in /usr/local/bin, which silently satisfied the
  # lookup and made three arms pass without exercising the nvm branch at all —
  # green locally, red on CI, and the local green was the wrong one.
  env -i HOME="$home" PATH=/usr/bin:/bin SHELL=/bin/sh \
      NEWS_PATH_PREPEND="$T/no-such-dir" NEWS_DIGEST_LOG="$log" "$@" \
      /bin/sh -c "$SCRIPT" >/dev/null 2>&1
  local st=$?
  printf '%s\n' "$st"
  cat "$log" 2>/dev/null
}

echo "ARM 1 — precondition: the arms below can actually reach the nvm branch"
# This is the assertion that would have caught the CI failure locally. If any
# node is reachable, the arms testing nvm resolution prove nothing.
NODE_REACHABLE="$(env -i PATH=/usr/bin:/bin NEWS_PATH_PREPEND="$T/no-such-dir" \
    /bin/sh -c 'PATH="$NEWS_PATH_PREPEND:$PATH"; command -v node' 2>/dev/null)"
[ -z "$NODE_REACHABLE" ] \
  && ok "no node reachable under the isolated PATH — the nvm arms are meaningful" \
  || bad "isolated PATH still reaches node at $NODE_REACHABLE" "arms 2-4 would pass without testing the nvm branch"

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

echo "ARM 6 — the script targets ITS OWN tree, not a hardcoded absolute path"
# CI caught this while the local suite passed: run-digest.sh had the author's
# repo path baked in, so it worked on one machine and pointed at nothing
# everywhere else. Copy the wrapper somewhere else and it must follow.
REL="$T/relocated"
mkdir -p "$REL/scripts/news"
cp "$SCRIPT" "$REL/scripts/news/"
printf '#!/usr/bin/env node\nconsole.log("REPO_SEEN=" + process.argv[1]);\n' > "$REL/scripts/news/fetch-news.mjs"
LOG6="$T/relocated.log"
env -i HOME="$HOME" PATH=/usr/bin:/bin SHELL=/bin/sh NEWS_DIGEST_LOG="$LOG6" \
    /bin/sh -c "$REL/scripts/news/run-digest.sh" >/dev/null 2>&1
OUT6="$(cat "$LOG6" 2>/dev/null)"
has "$OUT6" "$REL/scripts/news/fetch-news.mjs" \
  && ok "relocated copy runs its own fetch-news.mjs" \
  || bad "relocated copy runs its own fetch-news.mjs" "$OUT6"
# negative control: it must NOT have reached back into the real repo
has "$OUT6" "$REPO/scripts/news/fetch-news.mjs" \
  && bad "does not reach back into the original repo" "hardcoded path still in play" \
  || ok "does not reach back into the original repo"

echo "ARM 7 — a hang is killed and SAYS so; it is not silence"
# Measured 2026-09-03: Ollama's runner wedged, a 15-minute run wrote only START,
# and no RESULT line ever appeared. The rule for reading this log was "no line at
# all means the job never ran" — so a hang and a job that never fired produced
# identical evidence. This arm exists to keep those two states distinguishable.
HANG="$T/hang"
mkdir -p "$HANG/scripts/news"
cp "$SCRIPT" "$HANG/scripts/news/"
printf '#!/usr/bin/env node\nsetTimeout(()=>{},60000);\n' > "$HANG/scripts/news/fetch-news.mjs"
LOG7="$T/hang.log"
env -i HOME="$HOME" PATH=/usr/bin:/bin SHELL=/bin/sh NEWS_DIGEST_LOG="$LOG7" NEWS_RUN_TIMEOUT_S=3 \
    /bin/sh -c "$HANG/scripts/news/run-digest.sh" >/dev/null 2>&1
ST7=$?
OUT7="$(cat "$LOG7" 2>/dev/null)"
[ "$ST7" = 124 ] && ok "a hanging digest exits 124" || bad "hanging digest exits 124" "got $ST7"
has "$OUT7" "RESULT=timeout" && ok "the timeout is NAMED in the log, not silent" || bad "RESULT=timeout in log" "$OUT7"
has "$OUT7" "START" && ok "START is still logged (the hang is visible as a pair)" || bad "START logged" "$OUT7"
# negative control: a NORMAL run must not be killed, or a wrapper that timed out
# on everything would satisfy all three assertions above.
FAST="$T/fast"
mkdir -p "$FAST/scripts/news"
cp "$SCRIPT" "$FAST/scripts/news/"
printf '#!/usr/bin/env node\nconsole.log("[news] DIGEST_OK items=1 files=2");\n' > "$FAST/scripts/news/fetch-news.mjs"
LOG7B="$T/fast.log"
env -i HOME="$HOME" PATH=/usr/bin:/bin SHELL=/bin/sh NEWS_DIGEST_LOG="$LOG7B" NEWS_RUN_TIMEOUT_S=30 \
    /bin/sh -c "$FAST/scripts/news/run-digest.sh" >/dev/null 2>&1
ST7B=$?
OUT7B="$(cat "$LOG7B" 2>/dev/null)"
[ "$ST7B" = 0 ] && ok "control: a fast run is NOT killed" || bad "control: fast run not killed" "got $ST7B — wrapper kills everything: ARM 7 proves nothing"
has "$OUT7B" "RESULT=ok" && ok "control: a fast run still reports RESULT=ok" || bad "control: fast run RESULT=ok" "$OUT7B"
has "$OUT7B" "RESULT=timeout" && bad "control: fast run must not claim timeout" "timeout reported for a run that finished" || ok "control: fast run does not claim timeout"
echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
