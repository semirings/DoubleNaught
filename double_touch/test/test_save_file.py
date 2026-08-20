"""Tests for the Save File node: URL handling via IOSupport, output-path
resolution, and Cancel cleanup.
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.io_support import IOSupport
from double_touch.models import AssocArray
from double_touch.save_file import (
    delete_output,
    execute_save,
    resolve_output_path,
)

client = TestClient(app)


# --- IOSupport ----------------------------------------------------------


def test_io_support_accepts_the_three_allowed_schemes():
    for url in ("file:///tmp/x", "http://example.com/x", "https://example.com/x"):
        IOSupport.parse_url(url)  # does not raise


def test_io_support_treats_a_schemeless_string_as_local():
    parsed = IOSupport.parse_url("/tmp/x.csv")
    assert parsed.scheme == ""
    assert IOSupport.local_path("/tmp/x.csv") == "/tmp/x.csv"


def test_io_support_rejects_an_invented_scheme():
    with pytest.raises(ValueError, match="Unsupported URL scheme"):
        IOSupport.parse_url("storage://out/export")
    with pytest.raises(ValueError, match="Unsupported URL scheme"):
        IOSupport.parse_url("ftp://example.com/x")


def test_io_support_local_path_unquotes_a_file_url():
    assert IOSupport.local_path("file:///tmp/a%20b.csv") == "/tmp/a b.csv"


def test_io_support_local_path_refuses_a_remote_scheme():
    with pytest.raises(ValueError, match="requires a local path"):
        IOSupport.local_path("http://example.com/x")


# --- execute_save: url handling -------------------------------------------


def test_execute_save_writes_to_an_absolute_file_url(tmp_path, monkeypatch):
    monkeypatch.setattr(
        "double_touch.save_file.storage_out_dir", lambda: tmp_path / "unused"
    )
    aa = AssocArray(rows=["a"], cols=["x"], vals=["1"])
    target = tmp_path / "export"

    out_path, _ = execute_save(aa=aa, url=f"file://{target}", format="parquet")

    assert out_path == target.with_suffix(".parquet")
    assert out_path.is_file()


def test_execute_save_strips_a_mismatched_extension_from_the_url(tmp_path, monkeypatch):
    """A save dialog (or a typed URL) may carry any extension; the selected
    Format is what actually decides the one written — a stray `.png` on a
    Parquet save must not double up as `.png.parquet`.
    """
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(rows=["a"], cols=["x"], vals=["1"])

    out_path, _ = execute_save(
        aa=aa, url=f"file://{tmp_path}/photo.png", format="parquet"
    )

    assert out_path.name == "photo.parquet"


def test_execute_save_rejects_a_remote_url():
    aa = AssocArray(rows=["a"], cols=["x"], vals=["1"])
    with pytest.raises(ValueError, match="not yet implemented"):
        execute_save(aa=aa, url="https://example.com/out.parquet")


def test_execute_save_url_takes_precedence_over_legacy_filename(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(rows=["a"], cols=["x"], vals=["1"])

    out_path, _ = execute_save(
        aa=aa, url=f"file://{tmp_path}/from_url", filename="from_filename", format="json"
    )

    assert out_path.name == "from_url.json"


def test_execute_save_still_supports_the_legacy_bare_filename(tmp_path, monkeypatch):
    """No `url` at all — the pre-existing contract for older callers/workflows."""
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(rows=["a"], cols=["x"], vals=["1"])

    out_path, _ = execute_save(aa=aa, filename="legacy", format="csv")

    assert out_path == tmp_path / "legacy.csv"


# --- resolve_output_path / delete_output ----------------------------------


def test_resolve_output_path_matches_what_execute_save_actually_writes(
    tmp_path, monkeypatch
):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(rows=["a"], cols=["x"], vals=["1"])
    url = f"file://{tmp_path}/thing"

    out_path, _ = execute_save(aa=aa, url=url, format="csv")
    predicted = resolve_output_path(url=url, format="csv", payload_kind="aa")

    assert predicted == out_path


def test_resolve_output_path_disambiguates_text_from_aa(tmp_path, monkeypatch):
    """`format` alone can't tell text from AA — text is always `.txt`
    regardless of `format`, which is why payload_kind exists."""
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    url = f"file://{tmp_path}/thing"

    out_path, _ = execute_save(text="hello", url=url, format="parquet")
    predicted = resolve_output_path(url=url, format="parquet", payload_kind="text")

    assert predicted == out_path
    assert predicted.suffix == ".txt"


def test_delete_output_removes_a_file_that_exists(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(rows=["a"], cols=["x"], vals=["1"])
    url = f"file://{tmp_path}/gone"
    execute_save(aa=aa, url=url, format="parquet")

    removed = delete_output(url=url, format="parquet", payload_kind="aa")

    assert removed is True
    assert not resolve_output_path(url=url, format="parquet", payload_kind="aa").is_file()


def test_delete_output_is_not_an_error_when_nothing_was_written(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    removed = delete_output(url=f"file://{tmp_path}/never-written", format="parquet")
    assert removed is False


# --- /save route: url ------------------------------------------------------


def test_save_route_accepts_a_file_url(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    response = client.post(
        "/save",
        json={
            "dataToSave": {"rows": ["a"], "cols": ["x"], "vals": ["1"]},
            "url": f"file://{tmp_path}/via_route",
            "format": "json",
        },
    )
    assert response.status_code == 200, response.text
    assert (tmp_path / "via_route.json").is_file()


def test_save_route_reports_a_remote_url_as_a_client_error(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    response = client.post(
        "/save",
        json={
            "dataToSave": {"rows": ["a"], "cols": ["x"], "vals": ["1"]},
            "url": "https://example.com/out.parquet",
        },
    )
    assert response.status_code == 400
    assert "not yet implemented" in response.json()["detail"]


# --- /save/cancel route -----------------------------------------------------


def test_save_cancel_route_removes_a_completed_write(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    url = f"file://{tmp_path}/abandoned"
    client.post(
        "/save",
        json={
            "dataToSave": {"rows": ["a"], "cols": ["x"], "vals": ["1"]},
            "url": url,
            "format": "csv",
        },
    )
    assert (tmp_path / "abandoned.csv").is_file()

    response = client.post(
        "/save/cancel",
        json={"url": url, "format": "csv", "payloadKind": "aa"},
    )

    assert response.status_code == 200
    assert response.json()["removed"] is True
    assert not (tmp_path / "abandoned.csv").is_file()


def test_save_cancel_route_reports_false_rather_than_erroring_when_nothing_was_written(
    tmp_path, monkeypatch
):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    response = client.post(
        "/save/cancel",
        json={"url": f"file://{tmp_path}/nope", "format": "parquet"},
    )
    assert response.status_code == 200
    assert response.json()["removed"] is False
