#!/usr/bin/env python3
"""Check a markdown prompt against a prompt ontology.

Usage:
    python scripts/check_prompt.py PROMPT.md [--ontology X.parquet] [--engine auto|anvil|python]

A prompt is one entity (see ontologies/prompt_structure_ontology.yaml):
  - its class is the front matter key `intent:` (e.g. Implement, DNImplement);
  - its filled slots are its markdown headings, lower-cased with spaces and
    hyphens turned to underscores (`## Current state` -> current_state), plus any
    other non-empty front matter key (`mode: Attended` fills `mode`);
  - a slot counts as filled only if its section has non-empty text.
Front matter `ontology:` (a parquet path relative to the repo) overrides the default.

Checks:
  engine   OntologyAnvil.validate_entity: a prompt has exactly one recognised
           intent, and every required slot is filled. `--engine anvil` runs the
           real Julia engine through double_touch.ontology_ops; `python` runs a
           port of the same two checks; `auto` tries anvil, then falls back.
  script   Enum membership for enum-valued slots (e.g. mode: Attended|Unattended).
           OntologyAnvil does not check this yet; this script does, from the
           hasValue| rows.
`rule` annotations are prose and are never evaluated.
Exit status: 0 clean, 1 violations, 2 usage or ontology error.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ONTOLOGY = "storage/ontologies/dn_prompt_ontology.parquet"


def parse_prompt(text: str) -> tuple[dict[str, str], dict[str, str]]:
    """Return (front_matter, sections); sections maps slot name -> body text."""
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)  # guidance comments do not fill slots
    fm: dict[str, str] = {}
    m = re.match(r"---\s*\n(.*?)\n---\s*\n", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            if ":" in line and not line.startswith((" ", "\t", "#")):
                k, v = line.split(":", 1)
                v = re.sub(r"\s+#.*$", "", v)  # trailing YAML comment
                fm[k.strip()] = v.strip().strip("'\"")
        text = text[m.end():]
    heads = [(mm.start(), mm.end(), len(mm.group(1)), mm.group(2))
             for mm in re.finditer(r"^(#{1,6})\s+(.+?)\s*#*\s*$", text, re.M)]
    sections: dict[str, str] = {}
    for i, (_s, e, level, title) in enumerate(heads):
        end = len(text)
        for s2, _e2, l2, _t2 in heads[i + 1:]:
            if l2 <= level:
                end = s2
                break
        body = re.sub(r"^#{1,6}\s+.*$", "", text[e:end], flags=re.M).strip()
        name = re.sub(r"[\s\-]+", "_", re.sub(r"[^\w\s\-]", "", title).strip().lower())
        if name:
            sections[name] = (sections.get(name, "") + "\n" + body).strip()
    return fm, sections


def load_triples(path: Path) -> list[tuple[str, str, str]]:
    import pyarrow.parquet as pq
    d = pq.read_table(path).to_pydict()
    return list(zip(d["rowKey"], d["colKey"], d["val"]))


def python_engine(triples, classes, slots):
    req: dict[str, set[str]] = {}
    dis: set[tuple[str, str]] = set()
    for r, c, _v in triples:
        if c.startswith("requires|"):
            req.setdefault(r, set()).add(c[9:])
        elif c.startswith("disjointWith|"):
            dis.add((r, c[13:]))
            dis.add((c[13:], r))
    known = {r for r in req} | {a for a, _ in dis}
    rec = list(dict.fromkeys(c for c in classes if c in known))
    v: list[str] = []
    bad = sorted({a for a in rec for b in rec if (a, b) in dis})
    if bad:
        v.append(f"Disjointness violation: entity asserts mutually exclusive classes among {bad}")
    if len(rec) != 1:
        v.append(f"Cannot check slot requirements: entity must resolve to exactly one recognized class, got {rec}")
        return v
    miss = sorted(req[rec[0]] - set(slots))
    if miss:
        v.append(f"Missing required slot(s) for {rec[0]}: {miss}")
    return v


def anvil_engine(parquet: Path, classes, slots):
    sys.path.insert(0, str(ROOT / "backend" / "src"))
    from double_touch import ontology_ops  # needs juliacall + D4M + OntologyAnvil
    ok, viol = ontology_ops.validate_entity(classes, slots, str(parquet))
    return list(viol)


def enum_checks(triples, cls, fm, sections):
    """Enum-valued slots whose text is not a permissible value."""
    values: dict[str, set[str]] = {}
    for r, c, v in triples:
        if c.startswith("hasValue|"):
            values.setdefault(r, set()).add(v)
    out = []
    for r, c, v in triples:
        if r == cls and "|" not in c and c not in ("is_a", "rule", "in_subset") and v in values:
            text = (fm.get(c) or sections.get(c) or "").strip()
            if text and text not in values[v]:
                out.append(f"Slot {c}: {text!r} is not one of {sorted(values[v])}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prompt")
    ap.add_argument("--ontology")
    ap.add_argument("--engine", choices=["auto", "anvil", "python"], default="auto")
    a = ap.parse_args()

    fm, sections = parse_prompt(Path(a.prompt).read_text(encoding="utf-8"))
    onto = ROOT / (a.ontology or fm.get("ontology") or DEFAULT_ONTOLOGY)
    if not onto.is_file():
        print(f"ontology not found: {onto}", file=sys.stderr)
        return 2
    intent = fm.get("intent")
    if not intent:
        print("VIOLATION: no `intent:` in front matter, so the prompt has no class to check.")
        return 1

    filled = {k for k, v in sections.items() if v.strip()}
    filled |= {k for k, v in fm.items() if k not in ("intent", "ontology") and v.strip()}
    triples = load_triples(onto)

    used = a.engine
    if a.engine in ("auto", "anvil"):
        try:
            viol = anvil_engine(onto, [intent], sorted(filled))
            used = "anvil"
        except Exception as e:  # noqa: BLE001
            if a.engine == "anvil":
                print(f"anvil engine unavailable: {e}", file=sys.stderr)
                return 2
            used = "python (anvil unavailable)"
            viol = python_engine(triples, [intent], sorted(filled))
    else:
        viol = python_engine(triples, [intent], sorted(filled))
    viol += enum_checks(triples, intent, fm, sections)

    print(f"ontology: {onto.relative_to(ROOT)}  intent: {intent}  engine: {used}")
    print(f"filled slots: {sorted(filled)}")
    if viol:
        for v in viol:
            print(f"VIOLATION: {v}")
        return 1
    print("OK: no violations (rule annotations are prose and were not checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
