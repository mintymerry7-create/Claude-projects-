#!/usr/bin/env python3
"""Generates tactical puzzles with verified, unique solutions.

Method (similar in spirit to how lichess builds its puzzle database):
  1. Engine games are played from positions of the opening database, with
     occasional deliberately weaker moves so tactical mistakes appear.
  2. A position becomes a candidate when the side to move gains a decisive
     advantage (>= +MIN_GAIN cp, or a forced mate) right after the opponent's
     move, and the position before that move was not already decisive.
  3. The solution is extended move by move. Every move of the solver must be
     the only good move: the second-best alternative must be at least
     UNIQUE_MARGIN cp worse (or not a mate when the best is a mate).
  4. Themes are tagged from the board (mate, fork, pin, hanging piece,
     promotion, back-rank mate, discovered attack, skewer, sacrifice).

Output: ../../Packages/KnightAcademyKit/Sources/Learning/Resources/puzzles.json
Every puzzle is re-verified (legal FEN, legal solution) by the Swift tests.

Usage: generate_puzzles.py --engine /usr/games/stockfish --target 220 --workers 3
"""
import argparse
import json
import multiprocessing as mp
import os
import random

import chess
import chess.engine

HERE = os.path.dirname(os.path.abspath(__file__))
OPENINGS = os.path.join(HERE, "..", "..", "Packages", "KnightAcademyKit", "Sources",
                        "OpeningDatabase", "Resources", "openings.json")
OUT = os.path.join(HERE, "..", "..", "Packages", "KnightAcademyKit", "Sources",
                   "Learning", "Resources", "puzzles.json")

MIN_GAIN = 250
UNIQUE_MARGIN = 180
MATE = 100000
VALUES = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3, chess.ROOK: 5, chess.QUEEN: 9, chess.KING: 100}


def cp(score, turn):
    return score.pov(turn).score(mate_score=MATE)


def analyse(engine, board, depth, multipv=2):
    infos = engine.analyse(board, chess.engine.Limit(depth=depth), multipv=multipv)
    return [(i["pv"], cp(i["score"], board.turn), i["score"].pov(board.turn)) for i in infos if "pv" in i]


def material(board, color):
    return sum(VALUES[p.piece_type] for p in board.piece_map().values() if p.color == color and p.piece_type != chess.KING)


def themes_for(board, solution):
    """Heuristic tags based on the first move and the final position."""
    tags = set()
    b = board.copy()
    solver = b.turn
    first = solution[0]
    moved_from_piece = b.piece_at(first.from_square)
    captured = b.piece_at(first.to_square)
    if captured and not b.attackers(not solver, first.to_square):
        tags.add("hangingPiece")
    if captured and moved_from_piece and VALUES[captured.piece_type] < VALUES[moved_from_piece.piece_type] \
            and b.attackers(not solver, first.to_square):
        tags.add("sacrifice")
    if not captured and b.attackers(not solver, first.to_square) and moved_from_piece.piece_type != chess.PAWN \
            and not b.gives_check(first):
        tags.add("sacrifice")
    # discovered attack: a slider behind the moved piece now attacks something valuable
    before_attacks = {sq: set(b.attacks(sq)) for sq in b.pieces(chess.BISHOP, solver) | b.pieces(chess.ROOK, solver) | b.pieces(chess.QUEEN, solver)}
    b.push(first)
    if first.promotion:
        tags.add("promotion")
    for sq, before in before_attacks.items():
        if sq == first.from_square or b.piece_at(sq) is None:
            continue
        new = set(b.attacks(sq)) - before
        for t in new:
            p = b.piece_at(t)
            if p and p.color != solver and VALUES[p.piece_type] >= 3:
                tags.add("discoveredAttack")
    # fork: moved piece attacks two valuable targets
    targets = [t for t in b.attacks(first.to_square)
               if b.piece_at(t) and b.piece_at(t).color != solver
               and (VALUES[b.piece_at(t).piece_type] > VALUES[b.piece_at(first.to_square).piece_type]
                    or not b.attackers(not solver, t))]
    if len(targets) >= 2:
        tags.add("fork")
    # pin created against king/queen
    for sq in chess.SQUARES:
        p = b.piece_at(sq)
        if p and p.color != solver and p.piece_type != chess.KING and b.is_pinned(not solver, sq):
            pinner = b.pin(not solver, sq)
            if first.to_square in pinner:
                tags.add("pin")
    # skewer: slider check/attack on king or queen with a valuable piece behind
    mover = b.piece_at(first.to_square)
    if mover and mover.piece_type in (chess.BISHOP, chess.ROOK, chess.QUEEN):
        for t in b.attacks(first.to_square):
            tp = b.piece_at(t)
            if tp and tp.color != solver and tp.piece_type in (chess.KING, chess.QUEEN):
                ray = chess.ray(first.to_square, t)
                beyond = [s for s in chess.SquareSet(ray) if chess.square_distance(first.to_square, s) > chess.square_distance(first.to_square, t)
                          and chess.SquareSet.between(first.to_square, s).issuperset(chess.SquareSet([t]))]
                for s in sorted(beyond, key=lambda s: chess.square_distance(t, s)):
                    bp = b.piece_at(s)
                    if bp:
                        if bp.color != solver and VALUES[bp.piece_type] >= 3 and VALUES[bp.piece_type] < VALUES[tp.piece_type]:
                            tags.add("skewer")
                        break
    # final position
    end = board.copy()
    for m in solution:
        end.push(m)
    if end.is_checkmate():
        n = (len(solution) + 1) // 2
        tags.add(f"mateIn{n}")
        tags.add("mate")
        loser = end.turn
        king = end.king(loser)
        back = 0 if loser == chess.WHITE else 7
        if chess.square_rank(king) == back and end.piece_at(solution[-1].to_square).piece_type in (chess.ROOK, chess.QUEEN) \
                and chess.square_rank(solution[-1].to_square) == back:
            tags.add("backRankMate")
        if end.piece_at(solution[-1].to_square).piece_type == chess.KNIGHT and all(
                end.piece_at(s) and end.piece_at(s).color == loser for s in end.attacks(king) if s != solution[-1].to_square):
            tags.add("smotheredMate")
    else:
        tags.add("advantage")
    return sorted(tags)


def build_solution(engine, board, depth):
    """Returns the forced solution (solver moves and replies) or None."""
    b = board.copy()
    solver = b.turn
    sol = []
    start_balance = material(board, solver) - material(board, not solver)
    for step in range(4):
        lines = analyse(engine, b, depth, multipv=2)
        if not lines:
            break
        best_pv, best, best_score = lines[0]
        winning = (best_score.is_mate() and best_score.mate() > 0) or best >= MIN_GAIN
        unique = True
        if len(lines) > 1:
            second, second_score = lines[1][1], lines[1][2]
            if best_score.is_mate():
                unique = not (second_score.is_mate() and second_score.mate() > 0)
            else:
                unique = best - second >= UNIQUE_MARGIN and second < 400
        if not winning or not unique:
            if step == 0:
                return None
            sol = sol[:-1]  # end on a solver move
            break
        move = best_pv[0]
        sol.append(move)
        b.push(move)
        if b.is_game_over():
            break
        reply = analyse(engine, b, depth, multipv=1)[0][0][0]
        balance = material(b, solver) - material(b, not solver)
        if balance - start_balance >= 2 and not b.is_capture(reply) and not best_score.is_mate():
            break  # material is won and cannot be taken back
        sol.append(reply)
        b.push(reply)
    if len(sol) % 2 == 0:
        sol = sol[:-1]
    return sol or None


def difficulty(board, solution, tags):
    lvl = 1 + (len(solution) - 1) // 2
    first = solution[0]
    if not board.is_capture(first) and not board.gives_check(first):
        lvl += 1
    if "sacrifice" in tags:
        lvl += 1
    return max(1, min(5, lvl))


def worker(args):
    seed, engine_path, games, depth, start_positions = args
    rnd = random.Random(seed)
    engine = chess.engine.SimpleEngine.popen_uci(engine_path)
    engine.configure({"Threads": 1, "Hash": 32})
    found = []
    for g in range(games):
        sans = rnd.choice(start_positions)
        board = chess.Board()
        for s in sans:
            board.push_san(s)
        prev_eval = None
        for ply in range(90):
            if board.is_game_over():
                break
            lines = analyse(engine, board, 10, multipv=4)
            if not lines:
                break
            # Mostly good moves, sometimes a weaker one to create tactics.
            r = rnd.random()
            idx = 0 if r < 0.72 else min(len(lines) - 1, 1 if r < 0.86 else (2 if r < 0.95 else 3))
            move = lines[idx][0][0]
            board.push(move)
            if board.is_game_over():
                break
            # Candidate: opponent (who just moved) erred; side to move now wins.
            evals = analyse(engine, board, depth, multipv=2)
            if not evals:
                break
            now = evals[0][1]
            before = -lines[0][1]  # eval for the side now to move, before the move
            if now >= MIN_GAIN and before < 150 and len(board.piece_map()) > 6:
                sol = build_solution(engine, board, depth)
                if sol and len(sol) >= 1:
                    tags = themes_for(board, sol)
                    if "advantage" in tags and len(tags) == 1 and len(sol) == 1 and not board.is_capture(sol[0]):
                        pass
                    found.append({
                        "fen": board.fen(),
                        "solution": [m.uci() for m in sol],
                        "themes": tags,
                        "level": difficulty(board, sol, tags),
                        "lastMove": move.uci(),
                    })
            prev_eval = now
    engine.quit()
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="/usr/games/stockfish")
    ap.add_argument("--target", type=int, default=220)
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--games", type=int, default=40)
    ap.add_argument("--depth", type=int, default=16)
    ap.add_argument("--seed", type=int, default=2026)
    args = ap.parse_args()

    with open(OPENINGS, encoding="utf-8") as f:
        db = json.load(f)
    starts = []
    for o in db["openings"]:
        for l in o["lines"]:
            if l["kind"] in ("main", "key"):
                starts.append(l["moves"][:min(len(l["moves"]), 12)])

    puzzles = []
    seen = set()
    round_no = 0
    while len(puzzles) < args.target and round_no < 12:
        jobs = [(args.seed + round_no * 100 + w, args.engine, args.games, args.depth, starts) for w in range(args.workers)]
        with mp.Pool(args.workers) as pool:
            for batch in pool.map(worker, jobs):
                for p in batch:
                    key = " ".join(p["fen"].split()[:4])
                    if key in seen:
                        continue
                    seen.add(key)
                    puzzles.append(p)
        round_no += 1
        print(f"round {round_no}: {len(puzzles)} puzzles", flush=True)

    # Final verification pass with deeper search on the first move.
    engine = chess.engine.SimpleEngine.popen_uci(args.engine)
    verified = []
    for p in puzzles:
        b = chess.Board(p["fen"])
        ok = b.is_valid()
        for u in p["solution"]:
            m = chess.Move.from_uci(u)
            if m not in b.legal_moves:
                ok = False
                break
            b.push(m)
        if not ok:
            continue
        b = chess.Board(p["fen"])
        lines = analyse(engine, b, args.depth + 4, multipv=2)
        if lines[0][0][0].uci() != p["solution"][0]:
            continue
        if len(lines) > 1 and not lines[0][2].is_mate() and lines[0][1] - lines[1][1] < UNIQUE_MARGIN:
            continue
        verified.append(p)
    engine.quit()

    for i, p in enumerate(verified):
        p["id"] = f"kp{i + 1:04d}"
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(verified, f, indent=1)
    from collections import Counter
    print(len(verified), "verified puzzles")
    print(Counter(t for p in verified for t in p["themes"]))
    print(Counter(p["level"] for p in verified))


if __name__ == "__main__":
    main()
