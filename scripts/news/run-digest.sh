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

REPO="/home/hidekina/projetos/aethos/aethos-ideas/aethos-blog"
LOG="${NEWS_DIGEST_LOG:-$REPO/scripts/news/digest.log}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

PATH="/usr/local/bin:/usr/bin:/bin:/home/linuxbrew/.linuxbrew/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH"
export PATH

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  log "FATAL: node not found (PATH=$PATH) — digest did not run"
  exit 2
fi

# A dead Ollama and a quiet news week both end in "no post today"; the digest
# script separates them by exit code, and this log keeps that distinction.
log "START node=$NODE_BIN"
OUT="$("$NODE_BIN" "$REPO/scripts/news/fetch-news.mjs" 2>&1)"
STATUS=$?
printf '%s\n' "$OUT" >>"$LOG"

case "$STATUS" in
  0) log "RESULT=ok — drafts written, review them with: git -C $REPO status" ;;
  1) log "RESULT=no-new-items — feeds were reachable, nothing cleared the filters" ;;
  2) log "RESULT=BROKEN — instrument fault (network, Ollama, or config). Not a quiet news day." ;;
  *) log "RESULT=unexpected exit $STATUS" ;;
esac
log "END status=$STATUS"
exit "$STATUS"
