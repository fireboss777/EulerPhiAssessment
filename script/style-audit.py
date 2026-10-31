#!/usr/bin/env python3
"""Audit the Solidity style-guide rules that `forge fmt` cannot express.

Division of labour: `forge fmt` owns whitespace, indentation and line wrapping
(gate: `forge fmt --check`); this script owns the ORDERING rules:

  * Order of Functions   constructor -> receive -> fallback -> external ->
                         public -> internal -> private, with view/pure last
                         inside each visibility group.
  * Order of Layout      type declarations -> state variables -> events ->
                         errors -> modifiers -> functions (inside every
                         contract, library or interface).
  * Modifier order       visibility, mutability, `virtual`, `override`,
                         then custom modifiers.
  * Maximum line length  120 characters (see exception 3 below).

Usage:  python3 script/style-audit.py
Exit 0 = conform, exit 1 = violations printed one per line.

Reference: https://docs.soliditylang.org/en/v0.8.38/style-guide.html
Three deliberate exceptions, all leaning on the guide's own preamble
("project specific style guides take precedence" / "know when to be
inconsistent") and documented in README, section "Code style":

  1. `forge fmt` collapses runs of blank lines to ONE, so the guide's
     "surround top level declarations with two blank lines" cannot be kept
     without failing the hard `forge fmt --check` gate.
  2. The vendored CCIP files (Client, IRouterClient, IAny2EVMMessageReceiver)
     are never reordered: they must stay diffable against upstream
     `smartcontractkit/ccip @ 171f9f0`, which is what the README's
     "re-verify against upstream before a real lane" promise rests on.
  3. A line of 121 characters that ENDS IN `;` is exactly 120 characters of
     code: fmt's own limit excludes the terminator. Shortening
     `IArticleAnchor.verifyAgainstBatch` would mean renaming an ABI parameter
     to gain one character.
"""

from __future__ import annotations

import glob
import re
import sys

REFERENCE = "https://docs.soliditylang.org/en/v0.8.38/style-guide.html"
MAX_LINE = 121  # 120 of code + a terminating `;` (fmt excludes the `;`)

VIS_ORDER = ["constructor", "receive", "fallback", "external", "public", "internal", "private"]
MOD_RANK = {
    "external": 0, "public": 0, "internal": 0, "private": 0,
    "pure": 1, "view": 1, "payable": 1,
    "virtual": 2, "override": 3,
}

# exception 2: kept byte-comparable with upstream
VENDORED = {
    "src/interfaces/Client.sol",
    "src/interfaces/IRouterClient.sol",
    "src/interfaces/IAny2EVMMessageReceiver.sol",
}

TOP = re.compile(r"^(?:abstract\s+)?(?:contract|interface|library)\s+\w+")
FUNC_HEAD = re.compile(
    r"(?m)^[ \t]*(?:function\s+([A-Za-z_]\w*)|(constructor)|(receive)|(fallback))\s*\(([^)]*)\)([^;{]*)")
LAYOUT = [
    (re.compile(r"^(struct|enum|type)\s"), "type"),
    (re.compile(r"^event\s"), "event"),
    (re.compile(r"^error\s"), "error"),
    (re.compile(r"^modifier\s"), "modifier"),
    (re.compile(r"^(?:function|constructor|receive|fallback)\b"), "function"),
    (re.compile(r"^(?:uint|int|address|bool|bytes|string|mapping|u?int\d+|bytes\d+|"
                r"[A-Za-z_]\w*(?:\[\])?)\b.*(?:public|private|internal|constant|immutable)\b"), "state"),
]
RANK = {"type": 1, "state": 2, "event": 3, "error": 4, "modifier": 5, "function": 6}


def top_level_blocks(lines: list[str]):
    """(label, block_lines, line_offset) for each contract/interface/library."""
    i, n = 0, len(lines)
    while i < n:
        if TOP.match(lines[i]):
            j = i + 1
            while j < n and lines[j] != "}":
                j += 1
            yield lines[i].split("{")[0].strip(), lines[i:j + 1], i
            i = j + 1
        else:
            i += 1


def functions(text: str) -> list[dict]:
    code = re.sub(r"//[^\n]*", "", text)
    out = []
    for m in FUNC_HEAD.finditer(code):
        rest = m.group(6)
        name = (m.group(2) or m.group(3) or m.group(4)) if (m.group(2) or m.group(3) or m.group(4)) else m.group(1)
        kind = (m.group(2) or m.group(3) or m.group(4)) if (m.group(2) or m.group(3) or m.group(4)) else "function"
        if kind in ("constructor", "receive", "fallback"):
            vis = kind
        else:
            vis = next((v for v in ("external", "public", "internal", "private")
                        if re.search(r"\b" + v + r"\b", rest)), None)
        mut = "pure" if re.search(r"\bpure\b", rest) else ("view" if re.search(r"\bview\b\b", rest) else "pay")
        out.append(dict(line=code[:m.start()].count("\n") + 1, vis=vis, mut=mut, name=name, header=m.group(0).strip()))
    return out


def audit_file(path: str) -> list[str]:
    text = open(path).read()
    lines = text.split("\n")
    issues: list[str] = []
    vendored = path in VENDORED

    for label, block, offset in top_level_blocks(lines):
        # --- Order of Functions + modifier order -------------------------------
        fns = functions("\n".join(block))
        groups: list[dict] = []
        for f in fns:
            if groups and groups[-1]["vis"] == f["vis"]:
                groups[-1]["fns"].append(f)
            else:
                groups.append(dict(vis=f["vis"], fns=[f]))
        if not vendored:
            ranks = [VIS_ORDER.index(g["vis"]) for g in groups if g["vis"]]
            if ranks != sorted(ranks):
                seq = [g["vis"] for g in groups]
                issues.append(f"{path}: ORDER visibilites non triees dans `{label}` -> {seq}")
            for g in groups:
                seen = set()
                for f in g["fns"]:
                    seen.add(f["mut"])
                    if f["mut"] == "pay" and seen & {"view", "pure"}:
                        issues.append(f"{path}:{offset + f['line']}: ORDER {f['name']} "
                                      f"(payable/nonpayable) apres un view/pure du meme groupe `{g['vis']}`")
        for f in fns:
            toks = re.findall(r"\b(?:external|public|internal|private|pure|view|payable|virtual|override)\b",
                              f["header"])
            rk = [MOD_RANK[t] for t in toks]
            if rk != sorted(rk):
                issues.append(f"{path}:{offset + f['line']}: MODORDER `{f['header'][:80]}`")

        # --- Order of Layout ---------------------------------------------------
        if not vendored:
            seq = []
            for rel, line in enumerate(block):
                stripped = line[4:] if line.startswith("    ") else ""
                if not stripped or stripped.startswith(("//", "*/", "*")) or line[:4] != "    ":
                    continue
                for rx, kind in LAYOUT:
                    if rx.match(stripped):
                        seq.append((RANK[kind], rel, kind, stripped[:50]))
                        break
            prev = 0
            for rank, rel, kind, head in seq:
                if rank < prev:
                    issues.append(f"{path}:{offset + rel + 1}: LAYOUT `{kind}` (`{head}`) avant une "
                                  f"categorie plus prioritaire (ordre: type, state, events, errors, modifiers, functions)")
                prev = max(prev, rank)

    # --- Maximum line length (exception 3) -----------------------------------
    for i, line in enumerate(lines, 1):
        if len(line) > MAX_LINE:
            issues.append(f"{path}:{i}: LINE {len(line)} caracteres (> {MAX_LINE})")

    return issues


def main() -> int:
    files = sorted(glob.glob("src/**/*.sol", recursive=True)
                   + glob.glob("test/**/*.sol", recursive=True)
                   + glob.glob("script/*.sol")
                   + glob.glob("lib/**/*.sol", recursive=True))
    issues: list[str] = []
    for path in files:
        issues += audit_file(path)
    if issues:
        print(f"{len(issues)} ecart(s) vs la style guide ({REFERENCE}):")
        for issue in issues:
            print("  " + issue)
        return 1
    print(f"style guide OK: {len(files)} fichiers, 0 ecart "
          f"(ordre des fonctions, layout, ordre des modificateurs, <= {MAX_LINE} car.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
