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
# Steps run sequentially in ONE container (shared browser profile). Each step emits an
# "FGC_RC <step> <rc>" marker so the wrapper can tell a real claim-step crash from a benign
# redeem hiccup — a bash `;` chain's exit code only reflects the LAST step, which hid both
# earlier-step crashes and made a transient redeem-gog failure look like a whole-run crash.
STEPS="${FGC_STEPS:-epic-games prime-gaming gog redeem-gog}"
CLAIM_STEPS="epic-games prime-gaming gog"   # a non-zero from any of these = a real crash
REDEEM_MAX="${REDEEM_MAX:-${FGC_REDEEM_MAX:-5}}"   # exported REDEEM_MAX wins, then FGC_REDEEM_MAX, default 5
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
# Build a marker-emitting command: run each step, then echo its exit code on a tagged line.
runcmd=""
for s in $STEPS; do runcmd+="node $s; echo \"FGC_RC $s \$?\"; "; done
out=$(timeout "$RUN_TIMEOUT" docker run --rm --name fgc-oneshot \
        --env-file "$APPDIR/.env" \
        -e NOTIFY= \
        -e REDEEM_MAX="$REDEEM_MAX" \
        -v "$DATA":/fgc/data \
        "$IMAGE" bash -c "$runcmd" 2>&1)
code=$?
printf "%s\n" "$out" > "$LASTOUT"

# --- summarize via before/after DB diff (deduplicated, game-name level) ---
summary=$(python3 "$SUMMARIZER" "$SNAP" "$DATA" 2>/dev/null || echo '{}')
rm -rf "$SNAP"
alert=$(printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin).get('alert',False))" 2>/dev/null || echo False)
body=$(printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin).get('text',''))" 2>/dev/null || echo "")
claimed=$(printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin).get('counts',{}).get('claimed',0))" 2>/dev/null || echo 0)
problems=$(printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin).get('counts',{}).get('problems',0))" 2>/dev/null || echo 0)

# --- per-step exit codes from the FGC_RC markers ---
declare -A RC
while read -r _ step rc; do RC["$step"]="$rc"; done < <(printf '%s\n' "$out" | grep '^FGC_RC ')
marker_count=$(printf '%s\n' "$out" | grep -c '^FGC_RC ')

# A crash means a CLAIM step (epic/prime/gog) failed, the whole run timed out, or the
# container died before any step reported (infra failure). A redeem-gog non-zero is NOT a
# crash — it's handled as a soft notice below.
claim_crash=0
for s in $CLAIM_STEPS; do [ "${RC[$s]:-0}" -ne 0 ] && claim_crash=1; done
redeem_rc="${RC[redeem-gog]:-0}"
deferred=0
printf '%s\n' "$out" | grep -q "REDEEM_DEFERRED:" && deferred=1

# --- run-level signals from exit code + stdout markers ---
manual=0
echo "$out" | grep -qiE "Two-Step Verification|security code has been sent|got a captcha|hcaptcha" && manual=1
crashed=0
[ "$code" -eq 124 ] && crashed=1                                   # whole-run hard timeout
[ "$claim_crash" -eq 1 ] && crashed=1                              # a claim step failed
[ "$code" -ne 0 ] && [ "$code" -ne 124 ] && [ "$marker_count" -eq 0 ] && crashed=1  # container died before any step ran

# --- GOG keys redeemed this run (redeem-gog.js prints "  Redeemed: <title>") ---
redeemed_n=$(printf '%s\n' "$out" | grep -c "^  Redeemed:")
redeemed_list=$(printf '%s\n' "$out" | sed -n 's/^  Redeemed: /• /p')

# Parse redeem-gog's summary line: "REDEEM_SUMMARY redeemed=R already=A expired=E failed=F".
# A genuine failure (failed>0, e.g. timeout/captcha/unexpected) is a REAL problem worth an
# alert — this is the silent-failure hole. An expired/terminal code is informational (the key
# is now marked done and won't retry), worth a one-time heads-up.
sumline=$(printf '%s\n' "$out" | grep -m1 '^REDEEM_SUMMARY ')
redeem_failed=$(printf '%s' "$sumline" | sed -n 's/.*failed=\([0-9]\{1,\}\).*/\1/p'); redeem_failed=${redeem_failed:-0}
redeem_expired=$(printf '%s' "$sumline" | sed -n 's/.*expired=\([0-9]\{1,\}\).*/\1/p'); redeem_expired=${redeem_expired:-0}
# A redeem step that died with no summary and no deferral marker is itself a failure.
[ -z "$sumline" ] && [ "$deferred" -eq 0 ] && [ "$redeem_rc" -ne 0 ] && redeem_failed=$((redeem_failed + 1))
redeem_problem=0
[ "$redeem_failed" -gt 0 ] && redeem_problem=1

log "run end code=$code claim_crash=$claim_crash redeem_rc=$redeem_rc deferred=$deferred redeem_failed=$redeem_failed redeem_expired=$redeem_expired claimed=$claimed problems=$problems redeemed=$redeemed_n manual=$manual crashed=$crashed"

# --- stalled GOG redemption alert: Prime->GOG keys pending 3+ days, or redeem
#     deferred 3 runs in a row. Both used to stay silent indefinitely. ---
STALLED_DAYS="${FGC_STALLED_DAYS:-3}"
STALLED_STREAK="${FGC_STALLED_STREAK:-3}"
stalled_list=$(python3 - "$DATA/prime-gaming.json" "$STALLED_DAYS" 2>/dev/null <<'EOF'
import json, sys, datetime
TERMINAL = {'claimed and redeemed', 'redeem: not found', 'redeem: expired'}
try:
    db = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
days = int(sys.argv[2]) if len(sys.argv) > 2 else 3
cutoff = datetime.datetime.now() - datetime.timedelta(days=days)
out = []
if isinstance(db, dict):
    for games in db.values():
        if not isinstance(games, dict):
            continue
        for gid, g in games.items():
            if not isinstance(g, dict) or not g.get('code'):
                continue
            if 'gog' not in str(g.get('store', '')):
                continue
            if str(g.get('status', '')) in TERMINAL:
                continue
            try:
                t = datetime.datetime.strptime(str(g.get('time', ''))[:19], '%Y-%m-%d %H:%M:%S')
            except ValueError:
                continue
            if t < cutoff:
                out.append('• %s (pending since %s)' % (g.get('title', gid), str(g.get('time', ''))[:10]))
print('\n'.join(out))
EOF
)
streak=0
while read -r hline; do
  case "$hline" in
    *deferred=1*) streak=$((streak + 1)) ;;
    *) break ;;
  esac
done < <(grep 'run end ' "$HIST" 2>/dev/null | tail -"$STALLED_STREAK" | tac)
stalled=0
[ -n "$stalled_list" ] && stalled=1
[ "$STALLED_STREAK" -gt 0 ] && [ "$streak" -ge "$STALLED_STREAK" ] && stalled=1

# --- alert policy: notify on claim/problem/redeem OR crash OR manual OR an unexpected
#     redeem error OR stalled GOG redemption; a clean no-op and a benign
#     short GOG-deferral stay silent. ---
if [ "$alert" = "True" ] || [ "$redeemed_n" -gt 0 ] || [ "$manual" -eq 1 ] || [ "$crashed" -eq 1 ] || [ "$redeem_problem" -eq 1 ] || [ "$redeem_expired" -gt 0 ] || [ "$stalled" -eq 1 ]; then
  msg="$body"
  [ -z "$msg" ] && msg="🎮 <b>free-games-claimer</b>"
  [ "$redeemed_n" -gt 0 ] && msg+="${NL}🎁 <b>Redeemed $redeemed_n GOG key(s):</b>${NL}${redeemed_list}"
  if [ "$crashed" -eq 1 ]; then
    [ "$code" -eq 124 ] && msg+="${NL}⏱️ run hit the ${RUN_TIMEOUT}s timeout" || msg+="${NL}🔴 a claim step crashed — check the run log."
  fi
  [ "$manual" -eq 1 ] && msg+="${NL}🔐 a login needs a manual code/captcha — open noVNC or check the run log."
  [ "$redeem_problem" -eq 1 ] && msg+="${NL}⚠️ GOG redeem FAILED for $redeem_failed key(s) (timeout/captcha/unexpected) — check the run log."
  [ "$redeem_expired" -gt 0 ] && msg+="${NL}ℹ️ $redeem_expired Prime→GOG code(s) had already EXPIRED before redemption — now marked done, won't retry."
  # If we're already alerting for another reason, mention any benign deferral for context.
  [ "$deferred" -eq 1 ] && [ "$stalled" -eq 0 ] && msg+="${NL}⏭️ GOG redeem deferred (gog.com unreachable) — keys retry next run."
  [ "$stalled" -eq 1 ] && [ "$streak" -ge "$STALLED_STREAK" ] && [ "$STALLED_STREAK" -gt 0 ] && msg+="${NL}⏳ GOG redeem deferred $streak runs in a row — check the run log."
  [ -n "$stalled_list" ] && msg+="${NL}⏳ Prime→GOG key(s) pending ${STALLED_DAYS}+ days:${NL}${stalled_list}"
  send_tg "$msg"
  log "alert sent"
else
  [ "$deferred" -eq 1 ] && log "GOG redeem deferred — keys carry to next run (silent)"
  log "clean run, nothing new — no alert"
fi

# Exit non-zero only on a real crash, so the cron's own failure signal stays meaningful.
if [ "$crashed" -eq 1 ]; then
  [ "$code" -eq 124 ] && exit 124 || exit 1
fi
exit 0
