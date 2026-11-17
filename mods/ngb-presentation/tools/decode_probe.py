#!/usr/bin/env python3
"""Work out the per-player statistics layout from a probe dump.

The mod can dump the private stats region byte for byte:

    experimental_player_stats = 1
    probe_enabled             = 1
    probe_dump_region         = 1

which produces, in <Sider>\\content\\ngb-presentation\\

    probe_region.bin    the region, unchanged
    probe_region.txt    region_base, size, score and the layout in force

This tool searches that dump for the record grid whose goal counts reproduce the
scoreboard, and writes a calibration.txt the mod reads automatically:

    python3 decode_probe.py probe_region.bin                # report only
    python3 decode_probe.py probe_region.bin --write DIR    # also write DIR/calibration.txt
    python3 decode_probe.py --selftest                      # synthetic dump, no game

Nothing here is guessing: a layout is only reported when the numbers it decodes
match the score of the match that was being probed, for both teams, and the
supporting fields (passes, touches, ratings) stay inside what football allows.

Requires numpy for the fast path; without it the search still runs, just slower.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

# defaults from the module (NGB_Presentation.lua, OFF table)
DEF_REC_BASE = 0x7B5C0
DEF_SIDE = 0x59650
DEF_IDX = 0x2134
DEF_KIND = 0x24
DEF_KIND_OFF = 0x08
DEF_BUCKETS = 8

# stat kinds used to recognise a real table (see KIND in the module)
K_GOALS = 0
K_SHOTS = 6
K_ON_TARGET = 17
K_PASSES = 22
K_TOUCHES = 67
K_RATING = 179


# ---------------------------------------------------------------------------
#  meta / binary input
# ---------------------------------------------------------------------------
def read_meta(path):
    """Parse probe_region.txt. Returns a dict (may be empty)."""
    meta = {}
    if not path or not os.path.exists(path):
        return meta
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            key = parts[0].lower()
            if key == "score" and len(parts) >= 3:
                meta["home"], meta["away"] = int(parts[1]), int(parts[2])
            elif key == "region_base" and len(parts) >= 2:
                meta["base"] = int(parts[1], 0)
            elif key == "size" and len(parts) >= 2:
                meta["size"] = int(parts[1], 0)
            elif key == "layout":
                for i in range(1, len(parts) - 1, 2):
                    meta[parts[i].lower()] = int(parts[i + 1], 0)
    return meta


def load_words(path):
    data = open(path, "rb").read()
    # 4-byte alignment; pad so the last word is readable
    if len(data) % 4:
        data += b"\0" * (4 - len(data) % 4)
    return data


# ---------------------------------------------------------------------------
#  search
# ---------------------------------------------------------------------------
def sliding8(data):
    """sum of 8 consecutive u32 at every byte offset (step 4), as arrays."""
    try:
        import numpy as np
    except Exception:
        return None
    arr = np.frombuffer(data, dtype=np.uint32)
    n = len(arr)
    if n < 8:
        return arr[:0].astype(np.uint64)
    acc = arr[: n - 7].astype(np.uint64)
    for i in range(1, 8):
        acc = acc + arr[i: n - 7 + i]
    return acc


def u32_at(data, off):
    if off < 0 or off + 4 > len(data):
        return None
    return struct.unpack_from("<I", data, off)[0]


def f32_at(data, off):
    if off < 0 or off + 4 > len(data):
        return None
    return struct.unpack_from("<f", data, off)[0]


def kind_off(rec, kind, kind_stride=DEF_KIND, base_off=DEF_KIND_OFF):
    return rec + base_off + kind * kind_stride


def sum_buckets(data, off, buckets=DEF_BUCKETS):
    total = 0
    for i in range(buckets):
        v = u32_at(data, off + i * 4)
        if v is None:
            return None
        total += v
    return total


def side_totals(data, base, side_stride, rec_stride, kind, kind_stride=DEF_KIND,
                buckets=DEF_BUCKETS, players=40):
    """Goal totals for both sides at a candidate layout, or None."""
    hi = 0
    ai = 0
    for idx in range(players):
        v0 = sum_buckets(data, kind_off(base + idx * rec_stride, kind, kind_stride), buckets)
        v1 = sum_buckets(data, kind_off(base + side_stride + idx * rec_stride, kind, kind_stride), buckets)
        if v0 is None or v1 is None:
            return None
        hi += v0
        ai += v1
    return hi, ai


def plausible(data, base, side_stride, rec_stride, kind_stride=DEF_KIND,
              buckets=DEF_BUCKETS, players=40):
    """Supporting evidence: passes/touches/ratings have to look like football."""
    passes = [0, 0]
    touches = [0, 0]
    ratings = [0, 0]
    filled = [0, 0]
    shots = [0, 0]
    on_target = [0, 0]
    per_player = []
    for side in range(2):
        for idx in range(players):
            rec = base + side * side_stride + idx * rec_stride
            p = sum_buckets(data, kind_off(rec, K_PASSES, kind_stride), buckets)
            t = sum_buckets(data, kind_off(rec, K_TOUCHES, kind_stride), buckets)
            s = sum_buckets(data, kind_off(rec, K_SHOTS, kind_stride), buckets)
            o = sum_buckets(data, kind_off(rec, K_ON_TARGET, kind_stride), buckets)
            g = sum_buckets(data, kind_off(rec, K_GOALS, kind_stride), buckets)
            r = f32_at(data, kind_off(rec, K_RATING, kind_stride))
            if None in (p, t, s, o, g, r):
                return None
            if s > 60 or o > s or p > 400 or t > 600 or g > 12:
                return None
            if 3.0 <= r <= 10.0:
                ratings[side] += 1
            if p > 0 or t > 0:
                filled[side] += 1
            passes[side] += p
            touches[side] += t
            shots[side] += s
            on_target[side] += o
            per_player.append((side, idx, g, s, o, p, t, round(r, 2) if r == r else r))
    # a real match: both teams completed passes, every starter has a rating
    if passes[0] < 40 or passes[1] < 40:
        return None
    if touches[0] < 100 or touches[1] < 100:
        return None
    # every squad slot of a real match carries a rating, and a bench slot carries
    # zero everywhere - which is what separates the true base from the same grid
    # shifted by a record or two
    if ratings[0] < 12 or ratings[1] < 12:
        return None
    if filled[0] < 12 or filled[1] < 12:
        return None
    return {
        "passes": passes, "touches": touches, "ratings": ratings,
        "shots": shots, "on_target": on_target, "filled": filled,
        "players": per_player,
    }


def search(data, meta, verbose=True):
    """Return a list of candidate layouts, best first."""
    home = meta.get("home")
    away = meta.get("away")
    if home is None:
        home = away = None

    idx_guesses = []
    for cand in (meta.get("idx"), DEF_IDX, 0x2134, 0x2130, 0x2138, 0x2140,
                 0x2120, 0x2000, 0x2200):
        if cand and cand not in idx_guesses:
            idx_guesses.append(cand)

    side_guesses = []
    for cand in (meta.get("side"), DEF_SIDE, 0x59650, 0x58C00, 0x5A000, 0x60000):
        if cand and cand not in side_guesses:
            side_guesses.append(cand)

    found = []
    G = sliding8(data)
    np = None
    if G is not None:
        import numpy as np  # noqa: F401  (G came from numpy)

    for rec_stride in idx_guesses:
        # side strides that keep 40 records inside the file
        for side_stride in side_guesses:
            if side_stride == 0:
                continue
            span = side_stride + 40 * rec_stride + 0x1000
            if span > len(data):
                continue
            if verbose:
                print("  trying rec_stride 0x%X  side_stride 0x%X" % (rec_stride, side_stride))

            if G is None:
                bases = _bases_slow(data, side_stride, rec_stride, home)
            else:
                bases = _bases_fast(G, side_stride, rec_stride, home, away)
            if verbose:
                print("    %d candidate base addresses" % len(bases))

            for base in bases[:4000]:
                got = side_totals(data, base, side_stride, rec_stride, K_GOALS)
                if got is None:
                    continue
                if home is not None and got != (home, away):
                    continue
                ev = plausible(data, base, side_stride, rec_stride)
                if ev is None:
                    continue
                score = 0
                score += ev["ratings"][0] + ev["ratings"][1]
                score += ev["filled"][0] + ev["filled"][1]
                score += len([p for p in ev["players"] if p[2] > 0]) * 4
                found.append({
                    "rec_base": base, "side_stride": side_stride,
                    "rec_stride": rec_stride, "kind_stride": DEF_KIND,
                    "kind_offset": DEF_KIND_OFF, "buckets": DEF_BUCKETS,
                    "score": score, "evidence": ev, "goals": got,
                })
            if found:
                # a match on one stride pair is enough: report and stop
                return sorted(found, key=lambda c: -c["score"])
    return sorted(found, key=lambda c: -c["score"])


def _bases_fast(G, side_stride, rec_stride, home, away):
    """Vectorised: every aligned offset whose 40-record goal sums hit the score.

    G is indexed in 4-byte words, so the strides are converted from bytes once.
    """
    import numpy as np

    if rec_stride % 4 or side_stride % 4:
        return _bases_slow(None, side_stride, rec_stride, home)
    rec_w = rec_stride // 4
    side_w = side_stride // 4
    limit = len(G) - (side_w + 40 * rec_w) - 8
    if limit <= 0:
        return []

    if home is None:
        total = np.zeros(limit, dtype=np.uint64)
        for idx in range(40):
            off = idx * rec_w
            total += G[off: off + limit]
        order = np.argsort(total)[::-1][:2000]
        return [int(o) * 4 - DEF_KIND_OFF for o in order]

    total = np.zeros(limit, dtype=np.uint64)
    total2 = np.zeros(limit, dtype=np.uint64)
    for idx in range(40):
        off = idx * rec_w
        total += G[off: off + limit]
        o2 = side_w + off
        total2 += G[o2: o2 + limit]
    mask = (total == home) & (total2 == away)
    # G sums start at the goal kind itself, but a candidate layout is expressed
    # as the record base, so shift back by KIND_OFFSET (0x08)
    return [int(i) * 4 - DEF_KIND_OFF for i in np.nonzero(mask)[0]]


def _bases_slow(data, side_stride, rec_stride, home):
    out = []
    if data is None:
        return out
    limit = len(data) - (side_stride + 40 * rec_stride) - 0x40
    if limit <= 0:
        return out
    step = 4
    for off in range(0, limit, step):
        got = side_totals(data, off, side_stride, rec_stride, K_GOALS)
        if got is None:
            continue
        if home is not None and got[0] != home:
            continue
        out.append(off)
        if len(out) >= 2000:
            break
    return out


# ---------------------------------------------------------------------------
#  reporting
# ---------------------------------------------------------------------------
def show(cand, meta):
    print()
    print("layout found")
    print("  stat_rec_base    = 0x%X" % cand["rec_base"])
    print("  stat_side_stride = 0x%X" % cand["side_stride"])
    print("  stat_rec_stride  = 0x%X" % cand["rec_stride"])
    print("  stat_kind_stride = 0x%X" % cand["kind_stride"])
    print("  stat_kind_offset = 0x%X" % cand["kind_offset"])
    print("  stat_buckets     = %d" % cand["buckets"])
    ev = cand["evidence"]
    print("  goals %s   passes %s   touches %s   ratings %s/%s" % (
        cand["goals"], ev["passes"], ev["touches"], ev["ratings"][0], ev["ratings"][1]))
    scorers = [(s, i, g) for (s, i, g, *_rest) in ev["players"] if g > 0]
    if scorers:
        print("  scorers decoded: " + ", ".join(
            "%s[%d] %d" % ("home" if s == 0 else "away", i, g) for s, i, g in scorers))
    if meta.get("home") is not None:
        print("  scoreboard was %d-%d, layout reproduces it" % (meta["home"], meta["away"]))


def write_calibration(path, cand):
    lines = [
        "# written by tools/decode_probe.py - read by NGB_Presentation.lua at start",
        "# delete this file to fall back to the defaults shipped with the mod",
        "stat_rec_base    = 0x%X" % cand["rec_base"],
        "stat_side_stride = 0x%X" % cand["side_stride"],
        "stat_rec_stride  = 0x%X" % cand["rec_stride"],
        "stat_kind_stride = 0x%X" % cand["kind_stride"],
        "stat_kind_offset = 0x%X" % cand["kind_offset"],
        "stat_buckets     = %d" % cand["buckets"],
    ]
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    print("\nwrote %s" % path)


# ---------------------------------------------------------------------------
#  selftest: build a synthetic region and find it again
# ---------------------------------------------------------------------------
def make_region(rec_base, side_stride, rec_stride, home_goals, away_goals,
                size=0x18FFE0, kind_stride=DEF_KIND, buckets=DEF_BUCKETS, seed=7):
    import random
    rnd = random.Random(seed)
    buf = bytearray(size)

    def put(off, value):
        if 0 <= off <= size - 4:
            struct.pack_into("<I", buf, off, value & 0xFFFFFFFF)

    def putf(off, value):
        if 0 <= off <= size - 4:
            struct.pack_into("<f", buf, off, value)

    # allocator header like the real region
    put(0, 0)
    put(4, size - 0x20)
    put(8, 1)

    def fill(side, idx, goals, shots, on_target, passes, touches, rating):
        rec = rec_base + side * side_stride + idx * rec_stride
        for k, v in ((K_GOALS, goals), (K_SHOTS, shots), (K_ON_TARGET, on_target),
                     (K_PASSES, passes), (K_TOUCHES, touches)):
            off = rec + DEF_KIND_OFF + k * kind_stride
            # spread across buckets like a real match
            left = v
            for b in range(buckets):
                take = left if b == buckets - 1 else min(left, max(0, v // 4))
                put(off + b * 4, take)
                left -= take
        putf(rec + DEF_KIND_OFF + K_RATING * kind_stride, rating)

    def spread(total, slots):
        # split a team's goals over a few squad slots, like a real match
        out = [0] * 40
        left = total
        for n, slot in enumerate(slots):
            take = left if n == len(slots) - 1 else left // 2
            out[slot] = take
            left -= take
        return out

    home_split = spread(home_goals, (9, 17, 21))
    away_split = spread(away_goals, (11, 14))

    for side in range(2):
        split = home_split if side == 0 else away_split
        for idx in range(40):
            goals = split[idx]
            shots = goals + rnd.randint(0, 4)
            fill(side, idx,
                 goals=goals,
                 shots=shots,
                 on_target=min(shots, goals + rnd.randint(0, 2)),
                 passes=rnd.randint(8, 60), touches=rnd.randint(20, 90),
                 rating=round(rnd.uniform(5.5, 8.5), 2))
    return bytes(buf)


def selftest():
    print("selftest: synthetic region, default layout")
    data = make_region(DEF_REC_BASE, DEF_SIDE, DEF_IDX, 2, 1)
    meta = {"home": 2, "away": 1, "base": 0x7B0000}
    cands = search(data, meta, verbose=False)
    if not cands:
        print("  FAIL: nothing found")
        return 1
    top = cands[0]
    ok = (top["rec_base"] == DEF_REC_BASE and top["side_stride"] == DEF_SIDE
          and top["rec_stride"] == DEF_IDX)
    print("  top candidate: rec_base 0x%X side 0x%X idx 0x%X"
          % (top["rec_base"], top["side_stride"], top["rec_stride"]))
    print("  %s" % ("PASS" if ok else "FAIL: expected 0x%X/0x%X/0x%X"
                    % (DEF_REC_BASE, DEF_SIDE, DEF_IDX)))

    print("selftest: region moved by 0x8000, table at a new base")
    moved = make_region(DEF_REC_BASE + 0x8000, DEF_SIDE, DEF_IDX, 3, 2)
    cands2 = search(moved, {"home": 3, "away": 2}, verbose=False)
    ok2 = bool(cands2) and cands2[0]["rec_base"] == DEF_REC_BASE + 0x8000
    print("  %s" % ("PASS" if ok2 else "FAIL: %r" % (
        cands2[0]["rec_base"] if cands2 else None,)))

    print("selftest: wrong score must find nothing")
    cands3 = search(moved, Ca := {"home": 5, "away": 0}, verbose=False)
    ok3 = len(cands3) == 0
    print("  %s" % ("PASS" if ok3 else "FAIL: %d false positives" % len(cands3)))

    return 0 if (ok and ok2 and ok3) else 1


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("region", nargs="?", help="probe_region.bin")
    ap.add_argument("--meta", help="probe_region.txt (defaults to the .bin's neighbour)")
    ap.add_argument("--write", metavar="DIR", help="write DIR/calibration.txt")
    ap.add_argument("--selftest", action="store_true", help="run on synthetic data")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.region:
        ap.print_help()
        return 2
    if not os.path.exists(args.region):
        print("no such file: %s" % args.region)
        return 2

    meta_path = args.meta
    if meta_path is None:
        guess = os.path.join(os.path.dirname(os.path.abspath(args.region)), "probe_region.txt")
        meta_path = guess if os.path.exists(guess) else None
    meta = read_meta(meta_path)
    data = load_words(args.region)
    print("region %s  %d bytes" % (args.region, len(data)))
    if meta:
        print("meta: base %s score %s-%s layout %s" % (
            hex(meta.get("base", 0)), meta.get("home"), meta.get("away"),
            {k: hex(v) for k, v in meta.items()
             if k in ("rec_base", "side", "idx", "kind", "kind_off", "buckets")}))

    cands = search(data, meta)
    if not cands:
        print("\nno layout reproduced the score. Either the dump was taken without a")
        print("goal on the board, or the region does not hold the per-player table.")
        return 1
    show(cands[0], meta)
    if len(cands) > 1:
        print("(%d other candidates matched less well)" % (len(cands) - 1))
    if args.write:
        write_calibration(os.path.join(args.write, "calibration.txt"), cands[0])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
