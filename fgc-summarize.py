#!/usr/bin/env python3
"""Summarize a free-games-claimer run by diffing per-platform JSON DBs (before vs after).

Usage: fgc-summarize.py <before_dir> <after_dir>
Prints JSON: {"alert": bool, "text": "<telegram html>", "counts": {...}}
- Lists games that BECAME claimed or BECAME a problem THIS run, deduplicated by title
  (Epic lists android/ios as separate ids with the same title -> collapsed).
- Stale statuses don't re-alert (diff-based); routine no-change runs produce alert=false.
"""
import json, sys, os

PLATFORMS = [("epic-games", "Epic"), ("prime-gaming", "Prime"), ("gog", "GOG")]
GOOD = {"claimed", "claimed and redeemed", "manual"}
PRETTY = {"epic-games": "Epic", "prime-gaming": "Prime", "gog": "GOG"}


def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}


def games(d):  # -> {(user,gid): (title, status)}
    out = {}
    if not isinstance(d, dict):
        return out
    for user, gv in d.items():
        if not isinstance(gv, dict):
            continue
        for gid, g in gv.items():
            if isinstance(g, dict) and isinstance(g.get("status"), str):
                out[(user, gid)] = (g.get("title") or gid, g["status"])
    return out


def reason_of(status):
    if "account linking" in status:
        return "needs account link"
    if status.startswith("unavailable"):
        return "unavailable in region"
    if status.startswith("failed"):
        r = status.split(":", 1)[1].strip() if ":" in status else "failed"
        return r or "failed"
    return status


def main():
    before_dir, after_dir = sys.argv[1], sys.argv[2]
    lines = []
    total_claimed = total_problems = 0
    for key, label in PLATFORMS:
        before = games(load(os.path.join(before_dir, key + ".json")))
        after = games(load(os.path.join(after_dir, key + ".json")))
        claimed, problems = [], {}
        for gk, (title, st) in after.items():
            bst = before.get(gk, (None, None))[1]
            if st in GOOD and bst not in GOOD:
                claimed.append(title)
            elif (st.startswith("failed") or st.startswith("unavailable")) and bst != st:
                problems.setdefault(title, reason_of(st))
        claimed = sorted(set(claimed))
        total_claimed += len(claimed)
        total_problems += len(problems)
        if claimed:
            lines.append("✅ <b>%s</b> claimed: %s" % (label, ", ".join(claimed)))
        for title, reason in sorted(problems.items()):
            lines.append("⚠️ <b>%s</b> couldn't claim: %s (%s)" % (label, title, reason))
    alert = bool(total_claimed or total_problems)
    text = ""
    if alert:
        head = "\U0001f3ae <b>free-games-claimer</b>"
        text = head + "\n" + "\n".join(lines)
    print(json.dumps({"alert": alert, "text": text,
                      "counts": {"claimed": total_claimed, "problems": total_problems}}))


if __name__ == "__main__":
    main()
