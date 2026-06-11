#!/usr/bin/env bash
# fgc-run.sh — run the hardened free-games-claimer once to completion, diff the per-platform
# JSON result DBs, and alert via Telegram ONLY when something happened (claimed) or went wrong
# (crash / failed claim / manual 2FA-captcha needed). Clean "nothing new" runs stay silent.
#
# Replaces the old `sleep 1d` + restart: unless-stopped self-loop with a fresh-container-per-run
# model: a hung or crashed run can never become an infinite restart loop, and every run yields a
# real exit code + a parsed summary. Schedule this daily (TrueNAS cron / systemd timer).
set -uo pipefail

APPDIR="${FGC_APPDIR:-/mnt/pool/appdata/free-games-claimer}"
DATA="$APPDIR/data"
IMAGE="${FGC_IMAGE:-fgc-hardened:local}"
PLATFORMS="${FGC_PLATFORMS:-node epic-games; node prime-gaming; node gog}"
RUN_TIMEOUT="${FGC_TIMEOUT:-1200}"   # hard cap (s) so a hung run can never wedge
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

# --- count entries by status across a platform JSON DB (nested user->game) ---
count_status() {  # $1=jsonfile  $2=prefix(claimed|failed)
  local f="$1" pfx="$2"
  [ -f "$f" ] || { echo 0; return; }
  python3 - "$f" "$pfx" <<'PY'
import json,sys
f,pfx=sys.argv[1],sys.argv[2]
try: d=json.load(open(f))
except Exception: print(0); sys.exit()
def walk(o):
    if isinstance(o,dict):
        s=o.get("status")
        if isinstance(s,str) and s.startswith(pfx): yield 1
        for v in o.values(): yield from walk(v)
    elif isinstance(o,list):
        for v in o: yield from walk(v)
print(sum(walk(d)))
PY
}

declare -A B_CLAIM B_FAIL
for p in epic-games prime-gaming gog; do
  B_CLAIM[$p]=$(count_status "$DATA/$p.json" claimed)
  B_FAIL[$p]=$(count_status "$DATA/$p.json" failed)
done

log "run start (image=$IMAGE)"
out=$(timeout "$RUN_TIMEOUT" docker run --rm --name fgc-oneshot \
        --env-file "$APPDIR/.env" \
        -v "$DATA":/fgc/data \
        "$IMAGE" bash -c "$PLATFORMS" 2>&1)
code=$?
printf "%s\n" "$out" > "$LASTOUT"

# --- per-platform deltas ---
summary=""; problems=0; claimed_total=0
for p in epic-games prime-gaming gog; do
  ac=$(count_status "$DATA/$p.json" claimed); af=$(count_status "$DATA/$p.json" failed)
  newc=$(( ac - ${B_CLAIM[$p]:-0} )); newf=$(( af - ${B_FAIL[$p]:-0} ))
  [ "$newc" -lt 0 ] && newc=0; [ "$newf" -lt 0 ] && newf=0
  claimed_total=$(( claimed_total + newc ))
  line="$p: "
  if [ "$newc" -gt 0 ]; then line+="🎁 claimed $newc "; else line+="— "; fi
  if [ "$newf" -gt 0 ]; then line+="⚠️ failed $newf"; problems=$(( problems + 1 )); fi
  summary+="${line}${NL}"
done

# --- run-level problems from exit code + stdout markers ---
manual=0
echo "$out" | grep -qiE "Two-Step Verification|security code has been sent|got a captcha|hcaptcha" && manual=1
crashed=0
if [ "$code" -eq 124 ]; then crashed=1; summary+="⏱️ run hit ${RUN_TIMEOUT}s timeout${NL}"; fi
if [ "$code" -ne 0 ] && [ "$code" -ne 124 ]; then crashed=1; fi

log "run end code=$code claimed=$claimed_total problems=$problems manual=$manual crashed=$crashed"

# --- alert policy: notify on good news (claimed) OR any problem; silent on clean no-op ---
if [ "$claimed_total" -gt 0 ] || [ "$problems" -gt 0 ] || [ "$manual" -eq 1 ] || [ "$crashed" -eq 1 ]; then
  head="🎮 <b>free-games-claimer</b>"
  if [ "$crashed" -eq 1 ]; then
    head="🔴 <b>free-games-claimer CRASHED</b> (exit $code)"
  elif [ "$problems" -gt 0 ]; then
    head="⚠️ <b>free-games-claimer: claim failures</b>"
  elif [ "$manual" -eq 1 ]; then
    head="🔐 <b>free-games-claimer needs you (2FA/captcha)</b>"
  fi
  msg="${head}${NL}${summary}"
  [ "$manual" -eq 1 ] && msg+="${NL}A login needs a manual code/captcha. Open noVNC or check the run log."
  send_tg "$msg"
  log "alert sent"
else
  log "clean run, nothing new — no alert"
fi
exit "$code"
