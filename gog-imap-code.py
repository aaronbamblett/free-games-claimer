#!/usr/bin/env python3
"""Fetch the latest GOG two-step security code from Gmail via IMAP.

Used by the hardened free-games-claimer fork to auto-complete GOG's email 2FA
(GOG only offers email codes, no TOTP — upstream prompts a human). Searches
in:anywhere so it works even if a Gmail filter trashes the code email.

Env: GMAIL_USER, GMAIL_APP_PASSWORD (app password; spaces ignored).
Args: --after EPOCH (only accept emails received at/after this; default 0)
      --timeout SEC (total poll budget; default 120)
      --poll SEC (interval; default 5)
Prints the 4-digit code to stdout and exits 0; exits 1 on timeout/error.
"""
import imaplib, email, html, re, sys, time, os, argparse, calendar

GOG_QUERY = "from:no-reply@email.gog.com subject:two-step in:anywhere newer_than:1d"
CODE_RE = re.compile(r"two-step security code:\s*(\d{4})", re.I)


def get_env(name):
    v = os.environ.get(name)
    return v.strip().strip('"') if v else None


def extract_code(raw):
    msg = email.message_from_bytes(raw)
    body = ""
    if msg.is_multipart():
        for part in msg.walk():
            ct = part.get_content_type()
            if ct in ("text/plain", "text/html"):
                try:
                    body = part.get_payload(decode=True).decode("utf-8", "replace")
                except Exception:
                    continue
                if ct == "text/plain":
                    break
    else:
        body = msg.get_payload(decode=True).decode("utf-8", "replace")
    text = html.unescape(re.sub("<[^>]+>", " ", body))
    text = re.sub(r"\s+", " ", text).strip()
    m = CODE_RE.search(text)
    return m.group(1) if m else None


def find_code(M, after):
    M.select('"[Gmail]/All Mail"')
    typ, data = M.search(None, "X-GM-RAW", '"%s"' % GOG_QUERY)
    ids = data[0].split()
    for num in reversed(ids):  # newest first
        typ, d = M.fetch(num, "(INTERNALDATE)")
        try:
            t = imaplib.Internaldate2tuple(d[0])  # local-time tuple, per imaplib
            epoch = int(time.mktime(t)) if t else 0
        except Exception:
            epoch = 0
        if epoch and epoch + 1 < after:
            continue  # stale code from before this login attempt
        typ, d = M.fetch(num, "(BODY.PEEK[])")
        code = extract_code(d[0][1])
        if code:
            return code
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--after", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--poll", type=int, default=5)
    a = ap.parse_args()
    user, pw = get_env("GMAIL_USER"), get_env("GMAIL_APP_PASSWORD")
    if not user or not pw:
        print("gog-imap-code: GMAIL_USER/GMAIL_APP_PASSWORD not set", file=sys.stderr)
        return 1
    pw = pw.replace(" ", "")
    deadline = time.time() + a.timeout
    while True:
        try:
            M = imaplib.IMAP4_SSL("imap.gmail.com")
            M.login(user, pw)
            code = find_code(M, a.after)
            try:
                M.logout()
            except Exception:
                pass
            if code:
                print(code)
                return 0
        except Exception as e:
            print("gog-imap-code: %r" % e, file=sys.stderr)
        if time.time() >= deadline:
            print("gog-imap-code: timed out waiting for GOG code email", file=sys.stderr)
            return 1
        time.sleep(a.poll)


if __name__ == "__main__":
    sys.exit(main())
