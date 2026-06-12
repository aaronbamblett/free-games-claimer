# free-games-claimer — hardened fork (configure & operate)

A hardened fork of [vogler/free-games-claimer](https://github.com/vogler/free-games-claimer)
that auto-claims free games from **Epic**, **Amazon Prime Gaming**, and **GOG**.

What this fork adds over upstream:

- **No more restart loop** (upstream issue #562). The entrypoint self-heals stale VNC/X
  locks, and we run one fresh throwaway container per run instead of a long-lived one — so a
  crash or hang can never become an infinite silent restart loop.
- **Runs all three platforms** every run (upstream defaults to this; the old deploy only ran GOG).
- **GOG email-2FA solved.** GOG only sends 4-digit codes by email (no TOTP). The fork reads
  the code from Gmail over IMAP and enters it automatically. Also fixes GOG's current login
  flow (per-digit code entry, the `.js-menu-account` header selector, attached-state waits).
- **Epic 2026 checkout/success-copy fixes** (Epic changes these periodically — see Troubleshooting).
- **Real alerting.** A wrapper sends a Telegram message **only** when something happens
  (a game was claimed, a claim failed, the run crashed, or a login needs you). Routine
  "nothing new" runs stay silent.

---

## Layout

| Path | What |
|---|---|
| `~/src/free-games-claimer` (your-host) | the fork source (branch `hardened`) + `Dockerfile.overlay` |
| `/mnt/pool/appdata/free-games-claimer/` | deployment dir: `.env`, `data/`, and `fgc-run.sh` |
| `/mnt/pool/appdata/free-games-claimer/data/` | persistent browser profile, per-platform result JSON DBs, run logs |
| Docker image `fgc-hardened:local` | the built image (thin overlay over `ghcr.io/vogler/free-games-claimer:dev`) |
| TrueNAS cronjob (id 2) | runs `fgc-run.sh` daily at 10:15 AM PDT as root |

The image is a **thin overlay**: `Dockerfile.overlay` starts FROM the upstream `:dev` image and
copies in the patched entrypoint, the reconciled platform scripts, a matching `src/`, and the
Gmail 2FA helper. Rebuilding is fast (no Playwright-from-source build).

---

## 1. Configure `.env`

Copy `.env.example` to `/mnt/pool/appdata/free-games-claimer/.env` and fill it in. The `.env`
is **gitignored** and must never be committed — it holds all credentials.

Key items (full details in `.env.example`):

- **`NOTIFY`** — `tgram://<bot_token>/<chat_id>` for Telegram alerts.
- **Prime** — `PG_EMAIL` / `PG_PASSWORD` / `PG_OTPKEY` (the TOTP *secret*, not a 6-digit code).
- **GOG** — `GOG_EMAIL` / `GOG_PASSWORD`.
- **Gmail (for GOG 2FA)** — `GMAIL_USER` and `GMAIL_APP_PASSWORD`.
  - The app password is a Google **App Password** (Google Account → Security → 2-Step
    Verification → App passwords). 2-Step Verification must be enabled. Spaces are ignored.
  - The reader searches **all mail including Trash/Spam**, so it still works even if a Gmail
    filter archives or trashes the GOG code email. (Worth fixing such a filter anyway.)
- **Epic** — no env vars; logged in once manually (below).

---

## 2. First-time logins (one-time, via noVNC)

Some platforms need a one-time interactive login. To watch/intervene, run with the noVNC port
exposed and open **http://your-host:6080** in a browser:

```bash
cd ~/src/free-games-claimer
docker run --rm -p 6080:6080 \
  --env-file /mnt/pool/appdata/free-games-claimer/.env \
  -v /mnt/pool/appdata/free-games-claimer/data:/fgc/data \
  fgc-hardened:local bash -c "node epic-games; node prime-gaming; node gog"
```

- **Epic** logs in via Google — do this once in the noVNC browser; the session then persists
  in `data/browser`.
- **GOG** triggers email 2FA on a new device; the fork auto-reads the code from Gmail. After the
  first successful login the session persists and later runs skip 2FA.
- **Prime** logs in headlessly via its TOTP key.

---

## 3. Build the image

After any change to the scripts/entrypoint:

```bash
cd ~/src/free-games-claimer
docker build -f Dockerfile.overlay -t fgc-hardened:local .
```

---

## 4. Run & schedule

**Manual run** (exactly what the schedule does):

```bash
sudo /mnt/pool/appdata/free-games-claimer/fgc-run.sh
```

`fgc-run.sh` runs one fresh container (`node epic-games; node prime-gaming; node gog`), diffs the
per-platform result DBs to count what was newly claimed/failed, writes `data/run-history.log` and
`data/last-run.log`, and sends a Telegram alert only on a claim / failure / crash / manual-2FA.

**Schedule** — a TrueNAS cronjob (id 2) runs it daily at 10:15 AM PDT as root. Manage via the
TrueNAS UI (Tasks → Cron Jobs) or:

```bash
midclt call cronjob.query            # list
midclt call cronjob.run 2            # trigger now
```

Useful wrapper env overrides: `FGC_IMAGE`, `FGC_PLATFORMS`, `FGC_TIMEOUT`, `FGC_APPDIR`.

---

## 5. Troubleshooting

**Epic/GOG change their pages periodically** (checkout button text, success copy, header
selectors). When a platform breaks, **observe the real page — do not guess**:

1. Add a debug screenshot in the script's `catch` block:
   `await page.screenshot({ path: '/fgc/data/debug.png', fullPage: true }).catch(()=>{});`
   then read `data/debug.png`.
2. Dump the relevant DOM via `page.evaluate(() => document.querySelector(sel)?.outerHTML)`.
3. Repoint the selector / copy, rebuild, re-run the single platform (`bash -c "node gog"`),
   bind-mounting the edited script so you can iterate without rebuilds:
   `-v "$PWD/gog.js":/fgc/gog.js:ro`.

Known moving parts already handled (re-check if they regress):
- **Epic** checkout button polls for either "Add to library" or "Place Order"; success matched by
  regex `text=/Thanks for your order!|It.s all yours|In Library/`.
- **GOG** login uses `.js-menu-account` (not the removed `#menuUsername`), waits `attached`, reads
  the username from `.menu-account__user-name`, and fills each of the four 2FA boxes individually.

**No alert but expected one?** Check `data/run-history.log` (per-run summary) and
`data/last-run.log` (full stdout of the last run).

**GOG keeps asking for 2FA every run?** The session isn't persisting — usually because a run
errored before completing login. Get one clean login (watch via noVNC), after which the cookie in
`data/browser` keeps you signed in.
