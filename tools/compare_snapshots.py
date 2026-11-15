#!/usr/bin/env python3
"""Compare LayerProbe snapshots taken on different realms (or layers).

Each player runs `/probe snapshot <dungeon>` in game, clicks "Take snapshot", copies the text
and pastes it into a file. Then:

    python3 tools/compare_snapshots.py snap_realm5.txt snap_realm2.txt ...

A file may hold several snapshots, and surrounding chat text is ignored. The question it answers:
does each realm's LFG tool show only its own players, and how much bigger does a merged list get?
"""
import os
import re
import sys
from itertools import combinations

PAIR_WINDOW = 300  # seconds: only compare snapshots taken this close together


def parse(text, source):
    snaps, cur = [], None
    for raw in text.splitlines():
        line = raw.strip().strip("`")
        if line.startswith("LFGSNAP"):
            cur = {"source": source, "rows": [], "meta": {}}
            for part in line.split("|")[1:]:
                if "=" in part:
                    k, v = part.split("=", 1)
                    cur["meta"][k.strip()] = v.strip()
            snaps.append(cur)
        elif cur is None:
            continue
        elif line.startswith("activity="):
            for part in line.split("|"):
                if "=" in part:
                    k, v = part.split("=", 1)
                    cur["meta"][k.strip()] = v.strip()
        elif line.startswith("END"):
            cur = None
        elif line.startswith("party |"):
            continue
        else:
            cols = [c.strip() for c in line.split("|")]
            if len(cols) >= 8:
                leader = cols[1]
                realm = leader.rsplit("-", 1)[1] if "-" in leader and not leader.startswith("(") else None
                cur["rows"].append({"party": cols[0], "leader": leader, "leader_realm": realm,
                                    "members": cols[2], "needs": cols[3], "level": cols[4],
                                    "class": cols[5], "zone": cols[6], "listed": cols[7]})
    return snaps


def describe(s):
    m = s["meta"]
    return f'{m.get("realm", "?")} {m.get("faction", "?")} layer {m.get("layer", "?")} @ {m.get("utc", "?")} ({os.path.basename(s["source"])})'


def main(paths):
    snaps = []
    for p in paths:
        with open(p, encoding="utf-8", errors="replace") as fh:
            snaps += parse(fh.read(), p)
    if not snaps:
        sys.exit("no LFGSNAP blocks found")

    print(f"== {len(snaps)} snapshots")
    for i, s in enumerate(snaps, 1):
        realms = {}
        for r in s["rows"]:
            realms[r["leader_realm"] or "?"] = realms.get(r["leader_realm"] or "?", 0) + 1
        m = s["meta"]
        print(f'  #{i} {describe(s)}: {m.get("activity", "?")} | {len(s["rows"])} listings, total={m.get("total")}, '
              f'complete={m.get("complete", "?")[:3]} | leader realms: '
              + ", ".join(f"{k} {v}" for k, v in sorted(realms.items(), key=lambda x: -x[1])))
        own = m.get("realm")
        foreign = sum(v for k, v in realms.items() if k not in (own, "?"))
        if foreign:
            print(f"     -> {foreign} leaders from OTHER realms appear: this tool is not realm-limited")

    print("\n== pairs (same activity, taken within 5 min)")
    verdicts = {"same realm": [], "other realm": []}
    for a, b in combinations(snaps, 2):
        if a["meta"].get("activity") != b["meta"].get("activity"):
            continue
        if abs(int(a["meta"].get("t", 0)) - int(b["meta"].get("t", 0))) > PAIR_WINDOW:
            continue
        pa = {r["party"] for r in a["rows"] if r["party"] != "?"}
        pb = {r["party"] for r in b["rows"] if r["party"] != "?"}
        if not pa and not pb:
            continue
        shared, union = len(pa & pb), len(pa | pb)
        kind = "same realm" if a["meta"].get("realm") == b["meta"].get("realm") else "other realm"
        pct = 100 * shared // union if union else 100
        verdicts[kind].append((pct, union, max(len(pa), len(pb), 1)))
        flag = "" if (a["meta"].get("complete", "").startswith("yes") and b["meta"].get("complete", "").startswith("yes")) \
            else "   (a snapshot was capped at 100: not a fair comparison)"
        print(f"  {kind:11} {pct:3d}% shared, merged {union} vs {len(pa)} / {len(pb)}: "
              f"{describe(a)}  <->  {describe(b)}{flag}")

    print("\n== verdict")
    for kind, rows in verdicts.items():
        if not rows:
            print(f"  {kind}: no comparable pairs yet")
            continue
        avg = sum(p for p, _, _ in rows) / len(rows)
        growth = sum(u / m for _, u, m in rows) / len(rows)
        if kind == "same realm":
            note = "control: should be near 100% (same realm sees the same list)" if avg >= 80 else \
                   "unexpectedly different on one realm: layers or timing matter - take snapshots closer together"
        else:
            note = "each realm sees only its own players: merging realms multiplies the list" if avg <= 30 else \
                   "realms see the same listings: the tool is already cross-realm" if avg >= 80 else "mixed - take more snapshots"
        print(f"  {kind}: {len(rows)} pairs, avg {avg:.0f}% shared, merged list {growth:.1f}x the larger one -> {note}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
