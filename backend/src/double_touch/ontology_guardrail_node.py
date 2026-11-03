"""The Ontology Guardrail node's AA-shaped request/response, on top of the
raw per-entity call in :mod:`ontology_ops`.

## The data contract

**Request** — one AA, one row per candidate entity (e.g. one row per segment
or panel a caption-extraction step produced). Column convention matches the
ontology's own faceting idiom (see ``storage/ontologies/*.parquet``'s own
``disjointWith|X`` / ``requires|X`` columns):

| column              | meaning                                                      |
|---------------------|---------------------------------------------------------------|
| ``class\\|<Name>``    | one per class the extraction step asserted for this entity (val = ``<Name>``, redundant with the column name but keeps a plain row→col→val reader usable without parsing it) |
| ``slot\\|<name>``     | one per slot the extraction step filled in (val = the slot's own filled value; only *presence* is checked here, so an empty string still counts as filled) |

A well-formed entity has exactly one ``class|X`` column; more or fewer is
itself a violation (see :func:`ontology_ops.validate_entity`'s composition
rule), not something this module tries to disambiguate.

**Response** — one AA, same row keys, two columns: ``valid`` (``"true"`` /
``"false"``) and ``violations`` (the violation messages joined by ``" | "``;
empty string when valid).
"""

from __future__ import annotations

from .aa_utils import aa_rows
from .models import AssocArray
from .ontology_ops import validate_entity

_CLASS_PREFIX = "class|"
_SLOT_PREFIX = "slot|"


def _entity_facts(row_cols: dict[str, object]) -> tuple[list[str], list[str]]:
    """Split one entity's ``{col: val}`` record into (asserted_classes,
    asserted_slots), by column prefix."""
    classes = []
    slots = []
    for col in row_cols:
        if col.startswith(_CLASS_PREFIX):
            classes.append(col[len(_CLASS_PREFIX):])
        elif col.startswith(_SLOT_PREFIX):
            slots.append(col[len(_SLOT_PREFIX):])
    return classes, slots


def validate_aa(aa: AssocArray) -> AssocArray:
    """Validate every entity row in *aa* and return the result AA.

    One call to :func:`ontology_ops.validate_entity` per row — not batched
    into a single Julia call — because each row's class/slot sets differ in
    size, and OntologyAnvil's checks are already O(nnz) sparse operations per
    entity; there is no vectorized "many entities at once" form of
    ``validate_entity`` to batch into.
    """
    rows: list[str] = []
    cols: list[str] = []
    vals: list[str] = []

    for entity_key, row_cols in aa_rows(aa):
        asserted_classes, asserted_slots = _entity_facts(row_cols)
        is_valid, violations = validate_entity(asserted_classes, asserted_slots)

        rows.append(entity_key)
        cols.append("valid")
        vals.append("true" if is_valid else "false")

        rows.append(entity_key)
        cols.append("violations")
        vals.append(" | ".join(violations))

    return AssocArray(rows=rows, cols=cols, vals=vals)
