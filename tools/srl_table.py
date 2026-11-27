#!/usr/bin/env python3
"""Turn SR Linux `... | as json` output into a compact text table.

SR Linux show-tables are ~200 columns wide; a video terminal shows ~120.
This keeps the columns you name (in that order) from the first JSON list
whose rows carry them, and splits multi-line cells into extra rows.
Values are printed exactly as SR Linux returned them.
usage: sr_cli -d "show ... | as json" | srl_table.py "Col A,Col B" [--where Col=value]
"""
import json, sys


def find_rows(node, cols):
    if isinstance(node, list):
        if node and all(isinstance(r, dict) for r in node) and all(c in node[0] for c in cols):
            return node
        for x in node:
            r = find_rows(x, cols)
            if r is not None:
                return r
    elif isinstance(node, dict):
        for v in node.values():
            r = find_rows(v, cols)
            if r is not None:
                return r
    return None


def main():
    cols = [c.strip() for c in sys.argv[1].split(",")]
    where = [a.split("=", 1) for a in sys.argv[2:] if "=" in a]
    rows = find_rows(json.load(sys.stdin), cols) or []
    rows = [r for r in rows if all(str(r.get(k)) == v for k, v in where)]
    table = []
    for r in rows:
        cells = [str(r.get(c, "")).strip().split("\n") for c in cols]
        for i in range(max(len(c) for c in cells)):
            table.append([c[i].strip() if i < len(c) else "" for c in cells])
    w = [max([len(c)] + [len(t[i]) for t in table]) for i, c in enumerate(cols)]
    line = lambda vals: "  ".join(v.ljust(w[i]) for i, v in enumerate(vals)).rstrip()
    print(line(cols)); print(line(["-" * x for x in w]))
    for t in table:
        print(line(t))


if __name__ == "__main__":
    main()
