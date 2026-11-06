#!/usr/bin/env python3
"""Compile a DN-style LinkML YAML into an Associative Array of (rowKey, colKey, val)
triples, saved as parquet (the form OntologyAnvil / ontology_ops.py reads) and
optionally a TSV mirror.

Usage:
    python scripts/compile_linkml_to_aa.py IN.yaml OUT.parquet [--tsv OUT.tsv] [--extras]

Triple vocabulary (matches storage/ontologies/prompt_governance_ontology.*):
    (Class, is_a, Parent)
    (Class, requires|<slot>, <slot>)        required or identifier slot
    (Class, hasAttribute|<slot>, <slot>)    optional slot with a primitive range
    (Class, <slot>, <Range>)                slot whose range is a class or enum
    (Class, <slot>|<Range>, <Range>)        slot with any_of ranges, one row each
    (Class, disjointWith|<Other>, <Other>)  from children_are_mutually_disjoint
    (Enum,  hasValue|<value>, <value>)      each permissible value
Slots are INDUCED: a subclass also gets every slot of its ancestors, as in the
governance sheet. Descriptions are not carried.

--extras adds rows the engine ignores today (OntologyAnvil reads only
disjointWith| and requires|):
    (Class, rule, <prose>)                  annotations.rule
    (Class, guard|<key>, <value>)           every other annotation
    (Class, in_subset, <Subset>)
    (Class, multivalued|<slot>, true)
    (Class, identifier|<slot>, <slot>)
    (Class, minimum_value|<slot>, <n>)  /  maximum_value|<slot>

Local imports (`imports: [other_file]`, resolved to other_file.yaml beside the
input) are merged, so a layered ontology compiles to one self-contained parquet.

Anything this compiler does not understand (attributes, mixins, rules, other
slot keys) is an ERROR, so the parquet can never silently drop part of the YAML.
"""
from __future__ import annotations

import argparse
import re
import sys

import yaml

CLASS_KEYS = {"description", "abstract", "is_a", "in_subset", "annotations",
              "slots", "slot_usage", "children_are_mutually_disjoint"}
SLOT_KEYS = {"name", "range", "required", "identifier", "multivalued",
             "description", "slot_uri", "any_of", "minimum_value", "maximum_value"}
USAGE_KEYS = SLOT_KEYS - {"name"}
PRIMITIVES = {"string", "integer", "float", "boolean", "double", "decimal",
              "date", "datetime", "uri", "uriorcurie"}


def _one_line(v) -> str:
    return re.sub(r"\s+", " ", str(v)).strip()


def compile_triples(schema: dict, extras: bool = False) -> list[tuple[str, str, str]]:
    classes = schema.get("classes") or {}
    slots = {k: (v or {}) for k, v in (schema.get("slots") or {}).items()}
    enums = schema.get("enums") or {}
    errors: list[str] = []

    for cn, cd in classes.items():
        for k in (cd or {}):
            if k not in CLASS_KEYS:
                errors.append(f"class {cn}: unsupported key '{k}'")
    for sn, sd in slots.items():
        for k in sd:
            if k not in SLOT_KEYS:
                errors.append(f"slot {sn}: unsupported key '{k}'")
    if errors:
        raise SystemExit("compile refused:\n  " + "\n  ".join(errors))

    classes = {k: (v or {}) for k, v in classes.items()}

    def chain(c: str) -> list[str]:  # root first
        out, seen = [], set()
        while c:
            if c in seen:
                raise SystemExit(f"is_a cycle at {c}")
            seen.add(c)
            out.append(c)
            c = classes[c].get("is_a")
            if c is not None and c not in classes:
                raise SystemExit(f"is_a parent {c} is not a class")
        return out[::-1]

    triples: list[tuple[str, str, str]] = []

    for cn, cd in classes.items():
        if cd.get("is_a"):
            triples.append((cn, "is_a", cd["is_a"]))

        names: list[str] = []
        usage: dict[str, dict] = {}
        for anc in chain(cn):
            for s in classes[anc].get("slots", []) or []:
                if s not in slots:
                    raise SystemExit(f"class {anc}: slot {s} is not defined")
                if s not in names:
                    names.append(s)
            for s, u in (classes[anc].get("slot_usage") or {}).items():
                for k in (u or {}):
                    if k not in USAGE_KEYS:
                        raise SystemExit(f"class {anc}: slot_usage {s}: unsupported key '{k}'")
                usage.setdefault(s, {}).update(u or {})

        for s in names:
            eff = {**slots[s], **usage.get(s, {})}
            required = bool(eff.get("required") or eff.get("identifier"))
            rng = eff.get("range", "string")
            any_of = [a["range"] for a in (eff.get("any_of") or [])]
            ranged = any_of or [rng]
            for r in ranged:
                if r not in classes and r not in enums and r not in PRIMITIVES:
                    raise SystemExit(f"class {cn}: slot {s} has unknown range {r}")
            if any_of:
                for r in any_of:
                    triples.append((cn, f"{s}|{r}", r))
            elif rng in classes or rng in enums:
                triples.append((cn, s, rng))
            elif not required:
                triples.append((cn, f"hasAttribute|{s}", s))
            if required:
                triples.append((cn, f"requires|{s}", s))
            if extras:
                if eff.get("multivalued"):
                    triples.append((cn, f"multivalued|{s}", "true"))
                if eff.get("identifier"):
                    triples.append((cn, f"identifier|{s}", s))
                for k in ("minimum_value", "maximum_value"):
                    if eff.get(k) is not None:
                        triples.append((cn, f"{k}|{s}", str(eff[k])))

        if cd.get("children_are_mutually_disjoint"):
            kids = [k for k, v in classes.items() if v.get("is_a") == cn]
            for a in kids:
                for b in kids:
                    if a != b:
                        triples.append((a, f"disjointWith|{b}", b))

        if extras:
            for sub in cd.get("in_subset", []) or []:
                triples.append((cn, "in_subset", sub))
            for k, v in (cd.get("annotations") or {}).items():
                triples.append((cn, "rule" if k == "rule" else f"guard|{k}", _one_line(v)))

    for en, ed in enums.items():
        for v in ((ed or {}).get("permissible_values") or {}):
            triples.append((en, f"hasValue|{v}", str(v)))
        if extras:
            for k, v in ((ed or {}).get("annotations") or {}).items():
                triples.append((en, "rule" if k == "rule" else f"guard|{k}", _one_line(v)))

    seen: dict[tuple[str, str], str] = {}
    for r, c, v in triples:
        if (r, c) in seen and seen[(r, c)] != v:
            raise SystemExit(f"conflicting values for ({r}, {c}): {seen[(r, c)]!r} vs {v!r}")
        seen[(r, c)] = v
    return [(r, c, v) for (r, c), v in seen.items()]


def load_schema(path: str, _seen: tuple[str, ...] = ()) -> dict:
    """Load a LinkML YAML and merge any LOCAL imports (a bare name resolves to
    <name>.yaml beside this file; `linkml:` imports are ignored). The result is
    the full closure, so a layered ontology compiles to one self-contained
    parquet. A class, slot or enum defined in two files is an error."""
    import os
    path = os.path.abspath(path)
    if path in _seen:
        raise SystemExit(f"import cycle at {path}")
    with open(path, encoding="utf-8") as fh:
        schema = yaml.safe_load(fh)
    for imp in schema.get("imports") or []:
        if imp.startswith("linkml:"):
            continue
        base = load_schema(os.path.join(os.path.dirname(path), imp + ".yaml"), _seen + (path,))
        for section in ("classes", "slots", "enums", "subsets"):
            mine = schema.setdefault(section, {}) or {}
            schema[section] = mine
            for name, body in (base.get(section) or {}).items():
                if name in mine:
                    raise SystemExit(f"{section[:-1]} {name} is defined in {path} and in its import {imp}")
                mine[name] = body
    return schema


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("yaml_in")
    ap.add_argument("parquet_out")
    ap.add_argument("--tsv")
    ap.add_argument("--extras", action="store_true")
    a = ap.parse_args()

    schema = load_schema(a.yaml_in)
    triples = compile_triples(schema, extras=a.extras)

    import pyarrow as pa
    import pyarrow.parquet as pq
    table = pa.table({
        "rowKey": pa.array([t[0] for t in triples], pa.string()),
        "colKey": pa.array([t[1] for t in triples], pa.string()),
        "val": pa.array([t[2] for t in triples], pa.string()),
    })
    pq.write_table(table, a.parquet_out)
    if a.tsv:
        with open(a.tsv, "w", encoding="utf-8") as fh:
            for r, c, v in triples:
                fh.write(f"{r}\t{c}\t{v}\n")
    print(f"{len(triples)} triples -> {a.parquet_out}", file=sys.stderr)


if __name__ == "__main__":
    main()
