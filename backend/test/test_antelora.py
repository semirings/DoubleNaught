"""Save Antelora: pages land in storage/antelora/<set>/<page>/ with metadata.jsonl."""

from __future__ import annotations

import base64
import json

import pytest

from double_touch.antelora import AnteloraError, collect_antelora, list_pages, safe_name, save_antelora
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
    result = save_antelora(_aa(_rec(1), _rec(2), _rec(3, page="nemo_2")), "mccay", tmp_path)
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
    save_antelora(_aa(_rec(1), _rec(2)), "mccay", tmp_path)
    save_antelora(_aa(_rec(1)), "mccay", tmp_path)
    page = tmp_path / "mccay" / "nemo_1"
    assert not (page / "s_2.png").exists()
    assert len((page / "metadata.jsonl").read_text().splitlines()) == 1
    assert [p.name for p in (tmp_path / "mccay").iterdir()] == ["nemo_1"]  # no temp dirs left


def test_falls_back_to_user_caption_and_skips_unusable_rows(tmp_path):
    ok = {"file_name": "images/s_9.png", "caption": "mine", "page_name": "p", "image_b64": PNG}
    result = save_antelora(_aa(ok, {"file_name": "x.png", "caption": "c"}, {"caption": "no file"}), "x", tmp_path)
    assert result["images"] == 1 and result["skipped"] == 2


def test_nothing_writable_is_an_error(tmp_path):
    with pytest.raises(AnteloraError) as err:
        save_antelora(_aa({"caption": "only"}), "x", tmp_path)
    assert "file_name" in str(err.value) and "caption" in str(err.value)


def test_names_cannot_escape_the_root(tmp_path):
    assert safe_name("../../etc", "d") == "etc"
    assert safe_name("..", "d") == "d"
    save_antelora(_aa(_rec(1, page="../evil")), "../up", tmp_path)
    assert not (tmp_path.parent / "evil").exists()
    assert (tmp_path / "up" / "evil" / "s_1.png").exists()


def test_route(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient

    from double_touch.app import app

    monkeypatch.setenv("DOUBLE_TOUCH_LORASET_DIR", str(tmp_path))
    body = {"captions": _aa(_rec(1)).model_dump(), "antelora": "mccay"}
    r = TestClient(app).post("/antelora/save", json=body)
    assert r.status_code == 200, r.text
    assert r.json()["images"] == 1
    r = TestClient(app).post("/antelora/save", json={"captions": {"rows": [], "cols": [], "vals": []}})
    assert r.status_code == 422


def _seg(session: str, n: int, page: str) -> dict:
    return _rec(n, page=page, file_name=f"images/{session}_0_u{n}.png")


def test_generic_page_names_do_not_collide(tmp_path):
    save_antelora(_aa(_seg("aaaaaaaa1111", 1, "image")), "m", tmp_path)
    save_antelora(_aa(_seg("bbbbbbbb2222", 2, "image")), "m", tmp_path)
    assert sorted(p.name for p in (tmp_path / "m").iterdir()) == [
        "page-aaaaaaaa",
        "page-bbbbbbbb",
    ]


def test_same_name_different_session_keeps_both(tmp_path):
    save_antelora(_aa(_seg("aaaaaaaa1111", 1, "nemo_1")), "m", tmp_path)
    save_antelora(_aa(_seg("bbbbbbbb2222", 2, "nemo_1")), "m", tmp_path)
    assert sorted(p.name for p in (tmp_path / "m").iterdir()) == [
        "nemo_1",
        "nemo_1-bbbbbbbb",
    ]


def test_same_session_resave_still_replaces(tmp_path):
    save_antelora(_aa(_seg("aaaaaaaa1111", 1, "nemo_1"), _seg("aaaaaaaa1111", 2, "nemo_1")), "m", tmp_path)
    save_antelora(_aa(_seg("aaaaaaaa1111", 1, "nemo_1")), "m", tmp_path)
    assert [p.name for p in (tmp_path / "m").iterdir()] == ["nemo_1"]
    assert len((tmp_path / "m" / "nemo_1" / "metadata.jsonl").read_text().splitlines()) == 1


# ── Collect ───────────────────────────────────────────────────────────────────


def _two_pages(tmp_path):
    save_antelora(_aa(_seg("aaaaaaaa1111", 1, "Page_000"), _seg("aaaaaaaa1111", 2, "Page_000")), "m", tmp_path)
    save_antelora(_aa(_seg("bbbbbbbb2222", 3, "Page_001")), "m", tmp_path)


def test_list_pages(tmp_path):
    _two_pages(tmp_path)
    (tmp_path / "m" / "_collected").mkdir()
    assert [(p["page"], p["images"]) for p in list_pages("m", tmp_path)] == [
        ("Page_000", 2),
        ("Page_001", 1),
    ]
    assert list_pages("nope", tmp_path) == []


def test_collect_makes_one_flat_trainer_ready_folder(tmp_path):
    _two_pages(tmp_path)
    result = collect_antelora("m", output="train", root=tmp_path)
    out = tmp_path / "m" / "_collected" / "train"
    assert result["images"] == 3 and result["pages"] == ["Page_000", "Page_001"]
    lines = [json.loads(x) for x in (out / "metadata.jsonl").read_text().splitlines()]
    assert {x["file_name"] for x in lines} == {
        "images/aaaaaaaa1111_0_u1.png",
        "images/aaaaaaaa1111_0_u2.png",
        "images/bbbbbbbb2222_0_u3.png",
    }
    assert all((out / x["file_name"]).read_bytes() == b"\x89PNG-fake" for x in lines)
    manifest = json.loads((out / "collection.json").read_text())
    assert manifest["pages"] == ["Page_000", "Page_001"] and manifest["held_out"] == []


def test_collect_also_writes_chat_pairs_for_vision_language_training(tmp_path):
    _two_pages(tmp_path)
    collect_antelora("m", root=tmp_path, prompt="Caption this panel.")
    out = tmp_path / "m" / "_collected" / "train"
    meta = [json.loads(x) for x in (out / "metadata.jsonl").read_text().splitlines()]
    chat = [json.loads(x) for x in (out / "train.jsonl").read_text().splitlines()]
    assert len(chat) == len(meta) == 3
    for m, c in zip(meta, chat):
        assert c["images"] == [m["file_name"]]
        assert c["messages"][0] == {"role": "user", "content": "Caption this panel."}
        assert c["messages"][1] == {"role": "assistant", "content": m["text"]}


def test_collect_holds_pages_out_and_rebuilds_clean(tmp_path):
    _two_pages(tmp_path)
    collect_antelora("m", root=tmp_path)
    result = collect_antelora("m", exclude=["Page_001"], root=tmp_path)
    out = tmp_path / "m" / "_collected" / "train"
    assert result["images"] == 2 and result["excluded"] == ["Page_001"]
    assert not (out / "images" / "bbbbbbbb2222_0_u3.png").exists()  # no leftovers
    assert json.loads((out / "collection.json").read_text())["held_out"] == ["Page_001"]
    # the collection never counts itself as a page, and leaves no temp folders
    assert [p["page"] for p in list_pages("m", tmp_path)] == ["Page_000", "Page_001"]
    assert [p.name for p in (tmp_path / "m" / "_collected").iterdir()] == ["train"]


def test_collect_skips_and_reports_broken_lines(tmp_path):
    _two_pages(tmp_path)
    page = tmp_path / "m" / "Page_000"
    (page / "aaaaaaaa1111_0_u2.png").unlink()  # image gone
    with (page / "metadata.jsonl").open("a") as f:
        f.write("not json\n")
        f.write(json.dumps({"file_name": "x.png", "text": "  "}) + "\n")
    result = collect_antelora("m", root=tmp_path)
    assert result["images"] == 2 and result["skipped"] == 3
    assert any("image missing" in p for p in result["problems"])
    assert any("not a valid" in p for p in result["problems"])


def test_collect_with_nothing_left_is_an_error(tmp_path):
    _two_pages(tmp_path)
    with pytest.raises(AnteloraError):
        collect_antelora("m", exclude=["Page_000", "Page_001"], root=tmp_path)
    assert not (tmp_path / "m" / "_collected" / "train").exists()
    assert list((tmp_path / "m" / "_collected").iterdir()) == []  # temp cleaned up


def test_collect_routes(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient

    from double_touch.app import app

    monkeypatch.setenv("DOUBLE_TOUCH_LORASET_DIR", str(tmp_path))
    _two_pages(tmp_path)
    c = TestClient(app)
    r = c.get("/antelora/pages", params={"antelora": "m"})
    assert r.status_code == 200 and [p["page"] for p in r.json()["pages"]] == ["Page_000", "Page_001"]
    r = c.post("/antelora/collect", json={"antelora": "m", "exclude": ["Page_001"]})
    assert r.status_code == 200 and r.json()["images"] == 2
    r = c.post("/antelora/collect", json={"antelora": "m", "exclude": ["Page_000", "Page_001"]})
    assert r.status_code == 422
