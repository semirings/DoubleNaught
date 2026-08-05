"""Train / validation split logic for associative arrays.

Kept separate from app.py so it can be tested and reused without importing
the full FastAPI application.
"""
import random

from .models import AssocArray


class InvalidRatioError(ValueError):
    pass


class EmptyAaError(ValueError):
    pass


def split_aa(
    aa: AssocArray,
    ratio: float = 0.8,
    strategy: str = "random",
    seed: int = 42,
) -> tuple[AssocArray, AssocArray, int, int, int]:
    """Split an AA into train and validation subsets by unique row key.

    The row key (e.g. chunk_id) is the unit of split — all triples that share
    a row key land in the same subset, preventing data leakage.

    With strategy="random" the row keys are shuffled using *seed* before the
    cut so results are reproducible across runs. With strategy="sequential"
    the first *ratio* fraction of rows (in order of first appearance) become
    the training set.

    Returns:
        (train_aa, val_aa, train_count, val_count, total_count)

    Raises:
        InvalidRatioError: when ratio is not strictly between 0 and 1.
        EmptyAaError:      when the AA contains no rows.
    """
    if not (0.0 < ratio < 1.0):
        raise InvalidRatioError("ratio must be between 0 and 1 (exclusive)")

    seen: dict[str, int] = {}
    for row in aa.rows:
        if row not in seen:
            seen[row] = len(seen)
    unique_rows: list[str] = list(seen.keys())

    if not unique_rows:
        raise EmptyAaError("AA has no rows to split")

    if strategy == "random":
        rng = random.Random(seed)
        rng.shuffle(unique_rows)

    n_train = max(1, int(len(unique_rows) * ratio))
    train_set: set[str] = set(unique_rows[:n_train])

    train_rows: list[str] = []
    train_cols: list[str] = []
    train_vals: list = []
    val_rows: list[str] = []
    val_cols: list[str] = []
    val_vals: list = []

    for r, c, v in zip(aa.rows, aa.cols, aa.vals):
        if r in train_set:
            train_rows.append(r)
            train_cols.append(c)
            train_vals.append(v)
        else:
            val_rows.append(r)
            val_cols.append(c)
            val_vals.append(v)

    return (
        AssocArray(rows=train_rows, cols=train_cols, vals=train_vals),
        AssocArray(rows=val_rows, cols=val_cols, vals=val_vals),
        n_train,
        len(unique_rows) - n_train,
        len(unique_rows),
    )
