#!/usr/bin/env python3
"""Quotes plain YAML scalars that contain ': ' (authoring convenience)."""
import re, sys

KEYS = {"id", "name", "after", "kind", "moves", "description", "trapper", "title", "text",
        "gambit", "mainName", "mainDescription", "summary", "canonical", "side", "difficulty",
        "main", "eco", "group", "family", "aliases", "prefixes", "notes", "ideas", "tactics",
        "whitePlans", "blackPlans", "mistakes", "keyPositions", "variations", "traps", "openings"}

def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

for path in sys.argv[1:]:
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        m = re.match(r'^(\s*)("[^"]+"|[A-Za-z]+): (.+)$', line)          # key: value
        m2 = re.match(r'^(\s*)- (.+)$', line)                                # - item
        if m and m.group(2).strip('"') not in ("",) and (m.group(2).startswith('"') or m.group(2) in KEYS):
            val = m.group(3)
            if ': ' in val and not val.startswith(('"', "'", '[', '{', '>', '|')):
                line = f"{m.group(1)}{m.group(2)}: {q(val)}"
        elif m2:
            val = m2.group(2)
            km = re.match(r'^([A-Za-z]+): ', val)
            if km and km.group(1) in KEYS:
                inner = val[len(km.group(0)):]
                if ': ' in inner and not inner.startswith(('"', "'", '[', '{', '>', '|')):
                    line = f"{m2.group(1)}- {km.group(1)}: {q(inner)}"
            elif (': ' in val or val.startswith(('*', '&', '!', '%', '@', '`'))) and not val.startswith(('"', "'", '[', '{')):
                line = f"{m2.group(1)}- {q(val)}"
        out.append(line)
    open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
