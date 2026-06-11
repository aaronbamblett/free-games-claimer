#!/usr/bin/env bash

set -eo pipefail # exit on error, error on any fail in pipe (not just last cmd); add -x to print each cmd; see gist bash_strict_mode.md

echo "Version: https://github.com/vogler/free-games-claimer/tree/${COMMIT}"
[ -n "$BRANCH" ] && [ "$BRANCH" != "main" ] && echo "Branch: ${BRANCH}"
echo "Build: $NOW"

BROWSER="${BROWSER_DIR:-data/browser}"

# Remove chromium profile lock.
# When running in docker and then killing it, on the next run chromium displayed a dialog to unlock the profile which made the script time out.
# Maybe due to changed hostname of container or due to how the docker container kills playwright - didn't check.
# https://bugs.chromium.org/p/chromium/issues/detail?id=367048
rm -f "/fgc/$BROWSER/SingletonLock"

# Self-heal stale VNC/X locks. Fork fix for upstream #562 (open/unfixed): with restart: unless-stopped
# docker reuses the same writable layer, so /tmp/.X11-unix/X1 + ~/.vnc/*:1.pid survive and vncserver
# aborts with "already running as :1" (set -eo pipefail) BEFORE claims run -> silent infinite loop.
# Upstream only removed /tmp/.X1-lock, which is insufficient. Clear all of them here.
/opt/TurboVNC/bin/vncserver -kill :1 >/dev/null 2>&1 || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 ~/.vnc/*:1.pid ~/.vnc/*:1.log 2>/dev/null || true

export DISPLAY=:1 # need to export this, otherwise playwright complains with 'Looks like you launched a headed browser without having a XServer running.'
if [ -z "$VNC_PASSWORD" ]; then
	pw="-SecurityTypes None"
	pwt="no password!"
else
	# pw="-passwd $VNC_PASSWORD" # not supported anymore
	pw="-rfbauth ~/.vnc/passwd"
	mkdir -p ~/.vnc/
	echo "$VNC_PASSWORD" | /opt/TurboVNC/bin/vncpasswd -f >~/.vnc/passwd
	pwt="with password"
fi
# TurboVNC server replaces Xvfb+x11vnc
# shellcheck disable=SC2086
/opt/TurboVNC/bin/vncserver $DISPLAY -geometry "${WIDTH}x${HEIGHT}" -depth "${DEPTH}" -rfbport "${VNC_PORT}" $pw -vgl -log /fgc/data/TurboVNC.log -xstartup /usr/bin/ratpoison 2>/dev/null # -noxstartup -novnc /usr/share/novnc/
echo "TurboVNC is running on port $VNC_PORT ($pwt) with resolution ${WIDTH}x${HEIGHT}"
# TODO keep websockify just for custom NOVNC_PORT? https://www.perplexity.ai/search/how-to-specify-the-novnc-port-rfv96C9tTZufnyFPRye5xA#0
websockify -D --web "/usr/share/novnc/" "$NOVNC_PORT" "localhost:$VNC_PORT" 2>/dev/null 1>&2 &
echo "noVNC (VNC via browser) is running on http://localhost:$NOVNC_PORT/?autoconnect=true"
echo
exec tini -g -- "$@" # https://github.com/krallin/tini/issues/8 node/playwright respond to signals like ctrl-c, but unsure about zombie processes
