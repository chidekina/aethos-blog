#!/usr/bin/env bash
# v2026.09.02
# Cron entry point for the news digest. Everything cron-specific lives here so
# fetch-news.mjs stays runnable by hand.
#
#   crontab:  0 8 * * 1 /home/hidekina/projetos/aethos/aethos-ideas/aethos-blog/scripts/news/run-digest.sh
#
# Cron runs with PATH=/usr/bin:/bin. Node here comes from a version manager or
# brew, neither of which is on that PATH — so the binary is resolved and
# CHECKED before any work, and a missing one exits loudly instead of dying at
# 127 before the first log line (measured 2026-08-31: a daily job produced ~540
# silent runs exactly this way).
set -uo pipefail

# Derived from this script's own location, never hardcoded. An absolute path
# baked in here works on the machine it was written on and silently points at
# nothing everywhere else — CI caught exactly that on 2026-09-02, while the
# local suite passed because the hardcoded path happened to exist locally. A
# moved or re-cloned repo would have failed the same way, weekly and quietly.
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
LOG="${NEWS_DIGEST_LOG:-$REPO/scripts/news/digest.log}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

# NEWS_PATH_PREPEND exists so the suite can isolate this lookup. Without it a
# machine that happens to carry node in /usr/local/bin — a GitHub runner does —
# satisfies `command -v node` and the nvm branch below is never exercised, so
# its arms pass without testing anything. Production never sets it.
PATH="${NEWS_PATH_PREPEND:-/usr/local/bin:/usr/bin:/bin:/home/linuxbrew/.linuxbrew/bin:$HOME/.bun/bin:$HOME/.local/bin}:$PATH"
export PATH

# Measured 2026-09-02 by running this script under a real cron environment
# (`env -i PATH=/usr/bin:/bin`): node is installed by nvm at
# ~/.nvm/versions/node/<version>/bin/node and is on NO fixed PATH. Prepending
# the usual directories was not enough — the guard below fired FATAL, which is
# the right failure, but the job would still never have produced a digest.
#
# The version is part of the path, so hardcoding one breaks at the next nvm
# upgrade — silently, in a weekly job nobody watches. Resolve the newest
# installed version instead, and verify it actually runs.
NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ] && [ -d "$HOME/.nvm/versions/node" ]; then
  # `sort -V` orders v9 before v10; plain sort does not.
  for d in $(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V -r); do
    if [ -x "$HOME/.nvm/versions/node/$d/bin/node" ]; then
      NODE_BIN="$HOME/.nvm/versions/node/$d/bin/node"
      break
    fi
  done
fi

if [ -z "$NODE_BIN" ]; then
  log "FATAL: node not found (PATH=$PATH, no nvm versions under $HOME/.nvm) — digest did not run"
  exit 2
fi

# A path that exists is not a binary that runs. The pipeline needs global fetch,
# which is Node 18+; an old nvm version left on disk would otherwise fail deep
# inside the script with a confusing error instead of here with a clear one.
NODE_VER="$("$NODE_BIN" -v 2>/dev/null || true)"
case "$NODE_VER" in
  v[0-9]*) : ;;
  *) log "FATAL: $NODE_BIN did not answer -v — digest did not run"; exit 2 ;;
esac
NODE_MAJOR="$(printf '%s' "$NODE_VER" | sed 's/^v//; s/\..*//')"
if [ "$NODE_MAJOR" -lt 18 ]; then
  log "FATAL: $NODE_BIN is $NODE_VER; the digest needs Node 18+ for global fetch — digest did not run"
  exit 2
fi

# A dead Ollama and a quiet news week both end in "no post today"; the digest
# script separates them by exit code, and this log keeps that distinction.
log "START node=$NODE_BIN"

# Cron kills nothing, so without a wall clock a wedged Ollama leaves this job
# running forever and the log holds only START. Measured 2026-09-03: the
# llama3.2:3b runner sat idle at 0.0% CPU while every generate call hung, and a
# 15-minute run produced no RESULT line at all.
#
# That is the expensive part. The rule for reading this log was "no line at all
# means the job never ran" — a hang produces exactly the same evidence, so the
# two states were indistinguishable. A budget makes the hang say so.
#
# The real run takes ~52s with 36 feeds. 900s is ~17x that: generous enough that
# a slow week never trips it, short enough that Monday's failure is visible
# Monday.
TIMEOUT_S="${NEWS_RUN_TIMEOUT_S:-900}"
TIMEOUT_BIN="$(command -v timeout || true)"
if [ -n "$TIMEOUT_BIN" ]; then
  OUT="$("$TIMEOUT_BIN" "$TIMEOUT_S" "$NODE_BIN" "$REPO/scripts/news/fetch-news.mjs" 2>&1)"
  STATUS=$?
else
  # Never fail closed on a missing coreutils binary: no timeout is worse than
  # the old behaviour only if it also stops the digest from running at all.
  log "WARN: no timeout(1) on PATH — running without a wall clock; a hang will not be reported"
  OUT="$("$NODE_BIN" "$REPO/scripts/news/fetch-news.mjs" 2>&1)"
  STATUS=$?
fi
printf '%s\n' "$OUT" >>"$LOG"

case "$STATUS" in
  0) log "RESULT=ok — drafts written, review them with: git -C $REPO status" ;;
  1) log "RESULT=nothing-produced — feeds were reachable; either nothing cleared the filters or the target files already existed. The [news] lines above say which." ;;
  2) log "RESULT=BROKEN — instrument fault (network, Ollama, or config). Not a quiet news day." ;;
  124) log "RESULT=timeout — killed after ${TIMEOUT_S}s without finishing. Ollama is the usual cause: the runner can wedge while /api/tags still answers. Check with a REAL generate call, then \`ollama stop\` the model. Raise NEWS_RUN_TIMEOUT_S if the digest legitimately needs longer." ;;
  *) log "RESULT=unexpected exit $STATUS" ;;
esac
log "END status=$STATUS"
exit "$STATUS"
