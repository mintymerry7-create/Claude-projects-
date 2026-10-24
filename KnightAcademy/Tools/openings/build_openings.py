#!/usr/bin/env python3
"""Builds and validates the Knight Academy opening database.

Inputs
  lichess/*.tsv   lichess-org/chess-openings (CC0): ECO codes, names, move orders
  data/*.yaml     hand-written course content: main lines, key variations,
                  traps, plans and explanations

Output
  ../../Packages/KnightAcademyKit/Sources/OpeningDatabase/Resources/openings.json

Every move sequence is replayed with python-chess; illegal moves abort the
build. Each opening's main line must pass through the position of its
canonical lichess entry, so names are attached to the right positions.
With --engine PATH, main lines, key variations and traps are also checked
with Stockfish: main/key lines must not contain moves that drop more than
--max-loss centipawns, and traps must end clearly winning for the trapper.

Usage
  python3 build_openings.py [--engine /usr/games/stockfish] [--list "Ruy Lopez"]
"""
import argparse
import glob
import json
import os
import re
import sys

import chess
import chess.engine
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "Packages", "KnightAcademyKit", "Sources",
                   "OpeningDatabase", "Resources", "openings.json")

errors = []
warnings = []


def err(msg):
    errors.append(msg)


def warn(msg):
    warnings.append(msg)


def load_lichess():
    entries = []
    for path in sorted(glob.glob(os.path.join(HERE, "lichess", "*.tsv"))):
        with open(path, encoding="utf-8") as f:
            next(f)
            for line in f:
                eco, name, pgn = line.rstrip("\n").split("\t")
                sans = [t for t in pgn.split() if not re.match(r"^\d+\.", t)]
                entries.append({"eco": eco, "name": name, "sans": sans})
    return entries


def parse_moves(text):
    """'1. e4 e5 2.Nf3 Nc6 3...a6' or a YAML list -> list of SAN."""
    if isinstance(text, list):
        return [str(t) for t in text]
    out = []
    for t in str(text).split():
        t = re.sub(r"^\d+\.+", "", t)
        if t:
            out.append(t)
    return out


def replay(sans, where):
    board = chess.Board()
    fens = [board.fen()]
    for i, san in enumerate(sans):
        try:
            move = board.parse_san(san)
        except ValueError:
            err(f"{where}: illegal/ambiguous move '{san}' at ply {i + 1} after {' '.join(sans[:i])}")
            return None, None
        canonical = board.san(move)
        if canonical.rstrip("+#") != san.rstrip("+#"):
            err(f"{where}: write '{canonical}' instead of '{san}' at ply {i + 1}")
        board.push(move)
        fens.append(board.fen())
    return board, fens


def move_label(ply):
    """1-based ply -> '3.' / '3...'"""
    n = (ply + 1) // 2
    return f"{n}." if ply % 2 == 1 else f"{n}..."


def san_list_with_check(sans):
    board = chess.Board()
    out = []
    for s in sans:
        m = board.parse_san(s)
        out.append(board.san(m))
        board.push(m)
    return out


def resolve_notes(notes, sans, where):
    """notes keyed by '3.Bb5' / '3...a6' -> {ply: text}"""
    out = {}
    for key, text in (notes or {}).items():
        m = re.match(r"^(\d+)(\.\.\.|\.)\s*(\S+)$", str(key))
        if not m:
            err(f"{where}: bad note key '{key}'")
            continue
        num, dots, san = int(m.group(1)), m.group(2), m.group(3)
        ply = num * 2 - (1 if dots == "." else 0)
        if ply > len(sans) or sans[ply - 1].rstrip("+#") != san.rstrip("+#"):
            err(f"{where}: note '{key}' does not match the line (ply {ply} is "
                f"'{sans[ply - 1] if ply <= len(sans) else '—'}')")
            continue
        out[str(ply)] = str(text).strip()
    return out


def slug(s):
    s = s.lower().replace("'", "").replace("’", "")
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")


def board_key(fen):
    return " ".join(fen.split()[:4])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine")
    ap.add_argument("--depth", type=int, default=16)
    ap.add_argument("--max-loss", type=int, default=110)
    ap.add_argument("--list")
    ap.add_argument("--only")
    args = ap.parse_args()

    lichess = load_lichess()
    if args.list:
        for e in lichess:
            if e["name"].startswith(args.list):
                print(f"{e['eco']}  {e['name']}  |  {' '.join(e['sans'])}")
        return

    openings = []
    for path in sorted(glob.glob(os.path.join(HERE, "data", "*.yaml"))):
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
        for o in doc["openings"]:
            o["_file"] = os.path.basename(path)
            o["_family"] = doc["family"]
            openings.append(o)

    by_name = {}
    for e in lichess:
        by_name.setdefault(e["name"], []).append(e)

    # Prefix ownership for pulling named sidelines from lichess.
    owners = []
    for o in openings:
        for p in o.get("prefixes", [o["canonical"]]):
            owners.append((p, o["id"]))
    owners.sort(key=lambda x: -len(x[0]))

    def owner_of(name):
        for p, oid in owners:
            if name == p or name.startswith(p + ",") or name.startswith(p + ":"):
                return oid
        return None

    sidelines = {}
    for e in lichess:
        oid = owner_of(e["name"])
        if oid:
            sidelines.setdefault(oid, []).append(e)

    engine = chess.engine.SimpleEngine.popen_uci(args.engine) if args.engine else None
    eval_cache = {}

    def evaluate(board):
        key = board.fen()
        if key not in eval_cache:
            info = engine.analyse(board, chess.engine.Limit(depth=args.depth))
            eval_cache[key] = info["score"].pov(board.turn).score(mate_score=100000)
        return eval_cache[key]

    def engine_check(sans, where, kind, trapper=None):
        board = chess.Board()
        prev = evaluate(board)
        for i, san in enumerate(sans):
            mover = board.turn
            board.push_san(san)
            if board.is_game_over():
                break
            cur = -evaluate(board)  # mover's point of view
            loss = prev - cur
            if kind in ("main", "key") and loss > args.max_loss and abs(prev) < 5000:
                warn(f"{where}: {move_label(i + 1)}{san} loses {loss}cp by engine (before {prev}, after {cur})")
            prev = -cur
        if kind in ("main", "key") and not board.is_game_over():
            final = evaluate(board) if board.turn == chess.WHITE else -evaluate(board)
            if abs(final) > 180:
                warn(f"{where}: final position is {final:+}cp for White")
        if kind == "trap":
            if board.is_checkmate():
                winner = not board.turn
            else:
                score = evaluate(board)
                white_score = score if board.turn == chess.WHITE else -score
                winner = chess.WHITE if white_score > 0 else chess.BLACK
                if abs(white_score) < 250:
                    err(f"{where}: trap does not end clearly winning ({white_score:+}cp for White)")
            want = chess.WHITE if trapper == "white" else chess.BLACK
            if winner != want:
                err(f"{where}: trap ends in favour of the wrong side")

    ids = set()
    out = []
    seen_canonical = {}
    for o in openings:
        if args.only and o["id"] != args.only:
            continue
        oid = o["id"]
        where = f"{o['_file']}:{oid}"
        if oid in ids:
            err(f"{where}: duplicate id")
        ids.add(oid)

        canon = by_name.get(o["canonical"])
        if not canon:
            err(f"{where}: canonical lichess name not found: {o['canonical']}")
            continue
        canon = min(canon, key=lambda e: len(e["sans"]))
        if o["canonical"] in seen_canonical:
            err(f"{where}: same canonical entry as {seen_canonical[o['canonical']]}")
        seen_canonical[o["canonical"]] = oid
        canon_board, _ = replay(canon["sans"], where + " (canonical)")
        canon_key = board_key(canon_board.fen())

        main_sans = parse_moves(o["main"])
        board, fens = replay(main_sans, where + " main")
        if board is None:
            continue
        main_keys = [board_key(f) for f in fens]
        if canon_key not in main_keys:
            err(f"{where}: main line never reaches the canonical position of '{o['canonical']}'")
        canon_ply = main_keys.index(canon_key) if canon_key in main_keys else len(canon["sans"])

        lines = []
        main_san_full = san_list_with_check(main_sans)
        lines.append({
            "id": f"{oid}-main", "name": o.get("mainName", o["name"]), "kind": "main",
            "moves": main_san_full, "notes": resolve_notes(o.get("notes"), main_sans, where + " main"),
            "description": str(o.get("mainDescription", "")).strip(),
        })
        if engine:
            engine_check(main_sans, where + " main", "main")

        for v in o.get("variations", []) or []:
            sans = parse_moves(v["moves"])
            vb, _ = replay(sans, f"{where} variation '{v['name']}'")
            if vb is None:
                continue
            kind = v.get("kind", "key")
            lines.append({
                "id": f"{oid}-{slug(v['name'])}", "name": v["name"], "kind": kind,
                "moves": san_list_with_check(sans),
                "notes": resolve_notes(v.get("notes"), sans, f"{where} variation '{v['name']}'"),
                "description": str(v.get("description", "")).strip(),
            })
            if engine and kind == "key" and not v.get("gambit"):
                engine_check(sans, f"{where} variation '{v['name']}'", "key")

        for t in o.get("traps", []) or []:
            sans = parse_moves(t["moves"])
            tb, _ = replay(sans, f"{where} trap '{t['name']}'")
            if tb is None:
                continue
            lines.append({
                "id": f"{oid}-trap-{slug(t['name'])}", "name": t["name"], "kind": "trap",
                "moves": san_list_with_check(sans), "trapper": t["trapper"],
                "notes": resolve_notes(t.get("notes"), sans, f"{where} trap '{t['name']}'"),
                "description": str(t.get("description", "")).strip(),
            })
            if engine:
                engine_check(sans, f"{where} trap '{t['name']}'", "trap", t["trapper"])

        # Named sidelines from lichess not already covered by a curated line.
        curated = [l["moves"] for l in lines]
        seen_side = set()
        for e in sidelines.get(oid, []):
            sb, _ = replay(e["sans"], f"{where} lichess '{e['name']}'")
            if sb is None:
                continue
            sans = san_list_with_check(e["sans"])
            if any(c[:len(sans)] == sans for c in curated):
                continue
            key = " ".join(sans)
            if key in seen_side:
                continue
            seen_side.add(key)
            sub = e["name"].split(":", 1)[1].strip() if ":" in e["name"] else e["name"]
            lines.append({
                "id": f"{oid}-lichess-{len(seen_side)}", "name": sub, "kind": "sideline",
                "eco": e["eco"], "moves": sans, "notes": {}, "description": "",
            })

        key_positions = []
        for kp in o.get("keyPositions", []) or []:
            m = re.match(r"^(\d+)(\.\.\.|\.)\s*(\S+)$", str(kp["after"]))
            ply = int(m.group(1)) * 2 - (1 if m.group(2) == "." else 0) if m else -1
            if not m or ply > len(main_sans) or main_sans[ply - 1].rstrip("+#") != m.group(3).rstrip("+#"):
                err(f"{where}: key position '{kp['after']}' not on main line")
                continue
            key_positions.append({"ply": ply, "title": kp["title"], "text": str(kp["text"]).strip()})

        for field in ("summary", "ideas", "whitePlans", "blackPlans", "mistakes", "tactics"):
            if not o.get(field):
                err(f"{where}: missing {field}")

        out.append({
            "id": oid,
            "name": o["name"],
            "aliases": o.get("aliases", []),
            "eco": o.get("eco", canon["eco"]),
            "family": o["_family"],
            "group": o.get("group", o["_family"]),
            "side": o["side"],
            "difficulty": o["difficulty"],
            "summary": str(o["summary"]).strip(),
            "ideas": o["ideas"],
            "tactics": o["tactics"],
            "whitePlans": o["whitePlans"],
            "blackPlans": o["blackPlans"],
            "mistakes": o["mistakes"],
            "keyPositions": key_positions,
            "canonicalName": o["canonical"],
            "canonicalPly": canon_ply,
            "fen": canon_board.fen(),
            "lines": lines,
            "source": "Names/ECO/move orders: lichess-org/chess-openings (CC0). "
                      "Course text and extended lines: Knight Academy, validated with python-chess"
                      + (" and Stockfish." if engine else "."),
        })

    if engine:
        engine.quit()

    for w in warnings:
        print("WARN ", w)
    for e in errors:
        print("ERROR", e)
    print(f"{len(out)} openings, {sum(len(o['lines']) for o in out)} lines, "
          f"{len(errors)} errors, {len(warnings)} warnings")
    if errors:
        sys.exit(1)
    if not args.only:
        with open(OUT, "w", encoding="utf-8") as f:
            json.dump({"version": 1, "openings": out}, f, ensure_ascii=False, indent=1)
        print("wrote", os.path.relpath(OUT))


if __name__ == "__main__":
    main()
