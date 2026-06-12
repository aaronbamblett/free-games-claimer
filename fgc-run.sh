#!/usr/bin/env bash
# fgc-run.sh — run the hardened free-games-claimer once to completion, diff the per-platform
# JSON result DBs, and send ONE clean Telegram message ONLY when something happened (a game was
# claimed) or went wrong (failed claim / crash / manual 2FA-captcha). Clean no-op runs stay silent.
#
# The in-container upstream notifier is suppressed (-e NOTIFY=) so this wrapper is the single,
# deduplicated notification source. Fresh container per run -> the #562 restart loop can't recur.
set -uo pipefail
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:${PATH:-}"   # cron runs with a minimal env

APPDIR="${FGC_APPDIR:-/mnt/pool/appdata/free-games-claimer}"
DATA="$APPDIR/data"
IMAGE="${FGC_IMAGE:-fgc-hardened:local}"
PLATFORMS="${FGC_PLATFORMS:-node epic-games; node prime-gaming; node gog}"
RUN_TIMEOUT="${FGC_TIMEOUT:-1200}"   # hard cap (s) so a hung run can never wedge
SUMMARIZER="${FGC_SUMMARIZER:-$APPDIR/fgc-summarize.py}"
HIST="$DATA/run-history.log"
LASTOUT="$DATA/last-run.log"
NL=$'\n'
ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "$(ts) $*" >> "$HIST"; }

# --- Telegram (parsed from apprise NOTIFY=tgram://<bot_token>/<chat_id>) ---
send_tg() {
  local text="$1" notify u bot chat
  notify=$(grep -E "^NOTIFY=" "$APPDIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\r\"")
  case "$notify" in tgram://*) ;; *) log "send_tg: NOTIFY not tgram, skip"; return 0;; esac
  u="${notify#tgram://}"; u="${u%/}"; bot="${u%%/*}"; chat="${u##*/}"
  curl -s --max-time 20 "https://api.telegram.org/bot${bot}/sendMessage" \
       --data-urlencode "chat_id=${chat}" \
       --data-urlencode "text=${text}" \
       -d parse_mode=HTML >/dev/null 2>&1 || log "send_tg: curl failed"
}

# --- snapshot result DBs before the run (for the before/after diff) ---
SNAP=$(mktemp -d)
for p in epic-games prime-gaming gog; do
  cp "$DATA/$p.json" "$SNAP/$p.json" 2>/dev/null || true
done

log "run start (image=$IMAGE)"
out=$(timeout "$RUN_TIMEOUT" docker run --rm --name fgc-oneshot \
        --env-file "$APPDIR/.env" \
        -e NOTIFY= \
        -v "$DATA":/fgc/data \
        "$IMAGE" bash -c "$PLATFORMS" 2>&1)
code=$?
printf "%s\n" "$out" > "$LASTOUT"

# --- summarize via before/after DB diff (deduplicated, game-name level) ---
summary=$(python3 "$SUMMARIZER" "$SNAP" "$DATA" 2>/dev/null || echo '{}')
rm -rf "$SNAP"
alert=$(printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin).get('alert',False))" 2>/dev/null || echo False)
body=$(printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin).get('text',''))" 2>/dev/null || echo "")
claimed=$(printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin).get('counts',{}).get('claimed',0))" 2>/dev/null || echo 0)
problems=$(printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin).get('counts',{}).get('problems',0))" 2>/dev/null || echo 0)

# --- run-level signals from exit code + stdout markers ---
manual=0
echo "$out" | grep -qiE "Two-Step Verification|security code has been sent|got a captcha|hcaptcha" && manual=1
crashed=0
[ "$code" -eq 124 ] && crashed=1
[ "$code" -ne 0 ] && [ "$code" -ne 124 ] && crashed=1

log "run end code=$code claimed=$claimed problems=$problems manual=$manual crashed=$crashed"

# --- alert policy: notify on claim/problem (from diff) OR crash OR manual; silent on clean no-op ---
if [ "$alert" = "True" ] || [ "$manual" -eq 1 ] || [ "$crashed" -eq 1 ]; then
  msg="$body"
  [ -z "$msg" ] && msg="🎮 <b>free-games-claimer</b>"
  if [ "$crashed" -eq 1 ]; then
    [ "$code" -eq 124 ] && msg+="${NL}⏱️ run hit the ${RUN_TIMEOUT}s timeout" || msg+="${NL}🔴 run crashed (exit $code)"
  fi
  [ "$manual" -eq 1 ] && msg+="${NL}🔐 a login needs a manual code/captcha — open noVNC or check the run log."
  send_tg "$msg"
  log "alert sent"
else
  log "clean run, nothing new — no alert"
fi
exit "$code"
