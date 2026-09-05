"""Tokenization logic — thin wrapper around tiktoken.

Kept separate from app.py so it can be tested and reused without importing
the full FastAPI application.
"""
import tiktoken

from .models import AssocArray


class UnknownEncodingError(ValueError):
    pass


def tokenize_aa(
    aa: AssocArray,
    encoding: str = "gpt2",
    text_col: str = "text",
) -> tuple[AssocArray, int, int, int]:
    """Tokenize text values in an AA using tiktoken.

    Reads every triple whose column equals *text_col*, encodes the string value
    with tiktoken, and returns a token AA:
      row  = original chunk id
      col  = "tok:NNNNNN"  (zero-padded 6-digit position)
      val  = float(token_id)

    Returns:
        (token_aa, vocab_size, total_tokens, chunk_count)

    Raises:
        UnknownEncodingError: when *encoding* is not recognised by tiktoken.
    """
    try:
        enc = tiktoken.get_encoding(encoding)
    except Exception as exc:
        raise UnknownEncodingError(
            f"Unknown encoding '{encoding}': {exc}"
        ) from exc

    chunk_texts: dict[str, str] = {}
    for row, col, val in zip(aa.rows, aa.cols, aa.vals):
        if col == text_col:
            chunk_texts[row] = str(val)

    rows: list[str] = []
    cols: list[str] = []
    vals: list = []

    for chunk_id, text in chunk_texts.items():
        for pos, token_id in enumerate(enc.encode(text)):
            rows.append(chunk_id)
            cols.append(f"tok:{pos:06d}")
            vals.append(float(token_id))

    return (
        AssocArray(rows=rows, cols=cols, vals=vals),
        enc.n_vocab,
        len(vals),
        len(chunk_texts),
    )
