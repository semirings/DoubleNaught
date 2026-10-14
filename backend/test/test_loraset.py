"""Save Loraset: pages land in storage/loraset/<set>/<page>/ with metadata.jsonl."""

from __future__ import annotations

import base64
import json

import pytest

from double_touch.loraset import LorasetError, safe_name, save_loraset
from double_touch.models import AssocArray

PNG = base64.b64encode(b"\x89PNG-fake").decode()


def _aa(*recs: dict) -> AssocArray:
    rows, cols, vals = [], [], []
    for i, rec in enumerate(recs):
        for k, v in rec.items():
            rows.append(f"seg:{i}")
            cols.append(k)
            vals.append(v)
    return AssocArray(rows=rows, cols=cols, vals=vals)


def _rec(n: int, page: str = "nemo_1", **extra) -> dict:
    return {
        "file_name": f"images/s_{n}.png",
        "caption": f"mine {n}",
        "improved_caption": f"better {n}",
        "page_name": page,
        "image_b64": PNG,
        **extra,
    }


def test_writes_one_folder_per_page(tmp_path):
    result = save_loraset(_aa(_rec(1), _rec(2), _rec(3, page="nemo_2")), "mccay", tmp_path)
    assert result["images"] == 3 and result["skipped"] == 0
    page1 = tmp_path / "mccay" / "nemo_1"
    lines = [json.loads(x) for x in (page1 / "metadata.jsonl").read_text().splitlines()]
    assert lines == [
        {"file_name": "s_1.png", "text": "better 1"},
        {"file_name": "s_2.png", "text": "better 2"},
    ]
    assert (page1 / "s_1.png").read_bytes() == b"\x89PNG-fake"
    assert (tmp_path / "mccay" / "nemo_2" / "s_3.png").exists()


def test_resave_replaces_the_page(tmp_path):
    save_loraset(_aa(_rec(1), _rec(2)), "mccay", tmp_path)
    save_loraset(_aa(_rec(1)), "mccay", tmp_path)
    page = tmp_path / "mccay" / "nemo_1"
    assert not (page / "s_2.png").exists()
    assert len((page / "metadata.jsonl").read_text().splitlines()) == 1
    assert [p.name for p in (tmp_path / "mccay").iterdir()] == ["nemo_1"]  # no temp dirs left


def test_falls_back_to_user_caption_and_skips_unusable_rows(tmp_path):
    ok = {"file_name": "images/s_9.png", "caption": "mine", "page_name": "p", "image_b64": PNG}
    result = save_loraset(_aa(ok, {"file_name": "x.png", "caption": "c"}, {"caption": "no file"}), "x", tmp_path)
    assert result["images"] == 1 and result["skipped"] == 2


def test_nothing_writable_is_an_error(tmp_path):
    with pytest.raises(LorasetError) as err:
        save_loraset(_aa({"caption": "only"}), "x", tmp_path)
    assert "file_name" in str(err.value) and "caption" in str(err.value)


def test_names_cannot_escape_the_root(tmp_path):
    assert safe_name("../../etc", "d") == "etc"
    assert safe_name("..", "d") == "d"
    save_loraset(_aa(_rec(1, page="../evil")), "../up", tmp_path)
    assert not (tmp_path.parent / "evil").exists()
    assert (tmp_path / "up" / "evil" / "s_1.png").exists()


def test_route(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient

    from double_touch.app import app

    monkeypatch.setenv("DOUBLE_TOUCH_LORASET_DIR", str(tmp_path))
    body = {"captions": _aa(_rec(1)).model_dump(), "loraset": "mccay"}
    r = TestClient(app).post("/loraset/save", json=body)
    assert r.status_code == 200, r.text
    assert r.json()["images"] == 1
    r = TestClient(app).post("/loraset/save", json={"captions": {"rows": [], "cols": [], "vals": []}})
    assert r.status_code == 422


def _seg(session: str, n: int, page: str) -> dict:
    return _rec(n, page=page, file_name=f"images/{session}_0_u{n}.png")


def test_generic_page_names_do_not_collide(tmp_path):
    save_loraset(_aa(_seg("aaaaaaaa1111", 1, "image")), "m", tmp_path)
    save_loraset(_aa(_seg("bbbbbbbb2222", 2, "image")), "m", tmp_path)
    assert sorted(p.name for p in (tmp_path / "m").iterdir()) == [
        "page-aaaaaaaa",
        "page-bbbbbbbb",
    ]


def test_same_name_different_session_keeps_both(tmp_path):
    save_loraset(_aa(_seg("aaaaaaaa1111", 1, "nemo_1")), "m", tmp_path)
    save_loraset(_aa(_seg("bbbbbbbb2222", 2, "nemo_1")), "m", tmp_path)
    assert sorted(p.name for p in (tmp_path / "m").iterdir()) == [
        "nemo_1",
        "nemo_1-bbbbbbbb",
    ]


def test_same_session_resave_still_replaces(tmp_path):
    save_loraset(_aa(_seg("aaaaaaaa1111", 1, "nemo_1"), _seg("aaaaaaaa1111", 2, "nemo_1")), "m", tmp_path)
    save_loraset(_aa(_seg("aaaaaaaa1111", 1, "nemo_1")), "m", tmp_path)
    assert [p.name for p in (tmp_path / "m").iterdir()] == ["nemo_1"]
    assert len((tmp_path / "m" / "nemo_1" / "metadata.jsonl").read_text().splitlines()) == 1
