#!/usr/bin/env python3
"""Validates curriculum.yaml and writes curriculum.json for the app.

Checks: legal FENs and squares, legal solution sequences, and per task
  verify: legal | mate | good
'good' asks Stockfish (depth 20) whether the learner's moves are within
MARGIN centipawns of the best move. 'mate' requires the solution (and every
alternative first move, followed by best play) to end in checkmate.
"""
import argparse
import json
import os
import sys

import chess
import chess.engine
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "Packages", "KnightAcademyKit", "Sources", "Learning", "Resources", "curriculum.json")
MARGIN = 60
MATE = 100000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="/usr/games/stockfish")
    args = ap.parse_args()
    doc = yaml.safe_load(open(os.path.join(HERE, "curriculum.yaml"), encoding="utf-8"))
    engine = chess.engine.SimpleEngine.popen_uci(args.engine)
    errors = []

    def score(board):
        info = engine.analyse(board, chess.engine.Limit(depth=20))
        return info["score"].pov(board.turn).score(mate_score=MATE), info

    out_modules = []
    lesson_ids = set()
    for m in doc["modules"]:
        lessons = []
        for l in m["lessons"]:
            if l["id"] in lesson_ids:
                errors.append(f"duplicate lesson {l['id']}")
            lesson_ids.add(l["id"])
            steps = []
            for i, s in enumerate(l["steps"]):
                where = f"{l['id']} step {i + 1}"
                try:
                    board = chess.Board(s["fen"])
                except ValueError as e:
                    errors.append(f"{where}: bad FEN {e}")
                    continue
                if not board.is_valid():
                    errors.append(f"{where}: invalid position {board.status()}")
                arrows = []
                for a in s.get("arrows", []) or []:
                    try:
                        mv = chess.Move.from_uci(a)
                        arrows.append({"from": chess.square_name(mv.from_square), "to": chess.square_name(mv.to_square), "kind": "suggestion"})
                    except ValueError:
                        errors.append(f"{where}: bad arrow {a}")
                for h in s.get("highlights", []) or []:
                    if h not in chess.SQUARE_NAMES:
                        errors.append(f"{where}: bad square {h}")
                solution = s.get("solution")
                sol = solution.split() if isinstance(solution, str) else (solution or [])
                alts = s.get("alternatives", []) or []
                if sol:
                    b = board.copy()
                    for u in sol:
                        mv = chess.Move.from_uci(u)
                        if mv not in b.legal_moves:
                            errors.append(f"{where}: illegal solution move {u}")
                            break
                        b.push(mv)
                    for a in alts:
                        if chess.Move.from_uci(a) not in board.legal_moves:
                            errors.append(f"{where}: illegal alternative {a}")
                    mode = s.get("verify", "legal")
                    if mode == "mate":
                        if not b.is_checkmate():
                            errors.append(f"{where}: solution does not end in mate")
                        for a in alts:
                            ab = board.copy()
                            ab.push(chess.Move.from_uci(a))
                            if not ab.is_checkmate():
                                sc, _ = score(ab)
                                if sc > -MATE + 200:
                                    errors.append(f"{where}: alternative {a} does not force mate ({-sc})")
                    elif mode == "good":
                        best, info = score(board)
                        for k, u in enumerate([sol[0]] + alts):
                            ab = board.copy()
                            ab.push(chess.Move.from_uci(u))
                            if ab.is_checkmate():
                                continue
                            sc, _ = score(ab)
                            sc = -sc
                            if best - sc > MARGIN and not (best > 5000 and sc > 5000):
                                errors.append(f"{where}: {u} is {best - sc}cp worse than best "
                                              f"{board.san(info['pv'][0])} ({best})")
                    elif mode != "legal":
                        errors.append(f"{where}: unknown verify mode {mode}")
                steps.append({
                    "text": str(s["text"]).strip(),
                    "fen": board.fen(),
                    "arrows": arrows,
                    "highlights": s.get("highlights", []) or [],
                    "solution": sol or None,
                    "alternatives": alts or None,
                    "hint": s.get("hint"),
                    "success": s.get("success"),
                })
            lessons.append({
                "id": l["id"], "title": l["title"], "summary": l["summary"],
                "difficulty": l["difficulty"], "themes": l.get("themes", []) or [], "steps": steps,
            })
        out_modules.append({"id": m["id"], "title": m["title"], "summary": m["summary"],
                            "symbol": m["symbol"], "lessons": lessons})
    engine.quit()
    for e in errors:
        print("ERROR", e)
    n_lessons = sum(len(m["lessons"]) for m in out_modules)
    n_tasks = sum(1 for m in out_modules for l in m["lessons"] for s in l["steps"] if s["solution"])
    print(f"{len(out_modules)} modules, {n_lessons} lessons, {n_tasks} tasks, {len(errors)} errors")
    if errors:
        sys.exit(1)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"modules": out_modules}, f, ensure_ascii=False, indent=1)
    print("wrote", os.path.relpath(OUT))


if __name__ == "__main__":
    main()
