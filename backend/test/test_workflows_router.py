"""Tests for DELETE /workflows/{workflow_id}."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.workflows_router import (
    ExecutionRegistry,
    WorkflowStorage,
    get_executions,
    get_workflow_storage,
    storage_root,
)

client = TestClient(app)


@pytest.fixture
def workflows(tmp_path, monkeypatch):
    """A scratch workflows directory wired into the route, plus a live registry.

    Both are injected through `dependency_overrides` rather than by monkeypatching
    module globals, so a failure here cannot delete anything in the real
    `storage/workflows`.
    """
    directory = tmp_path / "workflows"
    directory.mkdir()
    (directory / "alpha.json").write_text('{"rows":[],"cols":[],"vals":[]}')
    (directory / "beta.json").write_text('{"rows":[],"cols":[],"vals":[]}')

    storage = WorkflowStorage(directory=directory)
    registry = ExecutionRegistry()
    app.dependency_overrides[get_workflow_storage] = lambda: storage
    app.dependency_overrides[get_executions] = lambda: registry
    yield {"dir": directory, "storage": storage, "registry": registry}
    app.dependency_overrides.clear()


# --- Success ------------------------------------------------------------------


def test_deletes_the_definition_and_reports_success(workflows):
    response = client.delete("/workflows/alpha")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "SUCCESS"
    # camelCase on the wire, per the binding convention in DESIGN.md.
    assert body["workflowId"] == "alpha"

    assert not (workflows["dir"] / "alpha.json").exists()
    # Only the named workflow goes.
    assert (workflows["dir"] / "beta.json").exists()


def test_purges_cached_execution_state(workflows):
    registry = workflows["registry"]
    registry.cache("alpha", {"lastRun": "2026-08-13"})
    assert registry.cached("alpha") is not None

    assert client.delete("/workflows/alpha").status_code == 200

    assert registry.cached("alpha") is None


def test_removes_a_sidecar_artefact_directory(workflows):
    """Run artefacts must not outlive the definition."""
    sidecar = workflows["dir"] / "alpha"
    sidecar.mkdir()
    (sidecar / "run.log").write_text("output")

    assert client.delete("/workflows/alpha").status_code == 200
    assert not sidecar.exists()


def test_cached_state_for_other_workflows_survives(workflows):
    registry = workflows["registry"]
    registry.cache("alpha", {"a": 1})
    registry.cache("beta", {"b": 2})

    client.delete("/workflows/alpha")

    assert registry.cached("beta") == {"b": 2}


# --- 404 ----------------------------------------------------------------------


def test_missing_workflow_is_404(workflows):
    response = client.delete("/workflows/nonexistent")

    assert response.status_code == 404
    assert "no such workflow" in response.json()["detail"]


def test_deleting_twice_is_404_the_second_time(workflows):
    assert client.delete("/workflows/alpha").status_code == 200
    assert client.delete("/workflows/alpha").status_code == 404


@pytest.mark.parametrize(
    "bad_id",
    [
        "..",
        "../secrets",
        "..%2F..%2Fetc%2Fpasswd",
        "sub/dir",
        ".hidden",
        "",
    ],
)
def test_a_path_traversal_or_malformed_id_deletes_nothing(workflows, bad_id):
    """`workflow_id` becomes a filename, so this is the one that really matters."""
    before = sorted(p.name for p in workflows["dir"].iterdir())

    response = client.delete(f"/workflows/{bad_id}")

    # 404 (nothing to delete), 405 (empty id hits the collection path), or 307 —
    # never a 200, and never a deletion.
    assert response.status_code in (307, 404, 405), response.status_code
    assert sorted(p.name for p in workflows["dir"].iterdir()) == before


def test_an_id_escaping_the_directory_is_refused_by_storage(tmp_path):
    """Belt and braces: the storage layer refuses even when called directly."""
    storage = WorkflowStorage(directory=tmp_path / "workflows")
    (tmp_path / "workflows").mkdir()
    outsider = tmp_path / "outside.json"
    outsider.write_text("keep me")

    with pytest.raises(ValueError, match="not a valid workflow id"):
        storage.path_for("../outside")
    assert outsider.exists()


# --- 409 ----------------------------------------------------------------------


def test_an_actively_executing_workflow_is_409(workflows):
    workflows["registry"].begin("alpha")

    response = client.delete("/workflows/alpha")

    assert response.status_code == 409
    assert "task(s) in flight" in response.json()["detail"]
    # And the definition is untouched.
    assert (workflows["dir"] / "alpha.json").exists()


def test_the_conflict_clears_once_execution_finishes(workflows):
    registry = workflows["registry"]
    registry.begin("alpha")
    assert client.delete("/workflows/alpha").status_code == 409

    registry.end("alpha")
    assert client.delete("/workflows/alpha").status_code == 200


def test_a_run_on_another_workflow_does_not_block_this_one(workflows):
    workflows["registry"].begin("beta")
    assert client.delete("/workflows/alpha").status_code == 200


def test_404_takes_precedence_over_409(workflows):
    """A missing workflow reports missing, even if the registry thinks it runs."""
    workflows["registry"].begin("ghost")
    response = client.delete("/workflows/ghost")
    assert response.status_code == 404


# --- ExecutionRegistry --------------------------------------------------------


def test_registry_counts_concurrent_tasks():
    registry = ExecutionRegistry()
    registry.begin("w")
    registry.begin("w")
    assert registry.active_tasks("w") == 2

    registry.end("w")
    assert registry.is_active("w"), "one task still in flight"

    registry.end("w")
    assert not registry.is_active("w")


def test_registry_end_never_goes_negative():
    registry = ExecutionRegistry()
    registry.end("never-started")
    assert registry.active_tasks("never-started") == 0
    # And a later begin still registers.
    registry.begin("never-started")
    assert registry.is_active("never-started")


def test_purge_reports_whether_anything_was_cached():
    registry = ExecutionRegistry()
    assert registry.purge("w") is False
    registry.cache("w", {"x": 1})
    assert registry.purge("w") is True


# --- Storage location ---------------------------------------------------------


def test_storage_root_honours_the_env_override(monkeypatch, tmp_path):
    """The same `DN_STORAGE_DIR` the Dart store reads."""
    monkeypatch.setenv("DN_STORAGE_DIR", str(tmp_path))
    assert storage_root() == tmp_path
    assert WorkflowStorage().directory == tmp_path / "workflows"


def test_storage_root_defaults_to_the_repo_storage_dir(monkeypatch):
    monkeypatch.delenv("DN_STORAGE_DIR", raising=False)
    # The directory the Flutter WorkflowStore writes into.
    assert storage_root().name == "storage"
    assert WorkflowStorage().directory.name == "workflows"


@pytest.mark.parametrize("slug", ["_draft", "__scratch", "a", "9lives", "with.dots", "with-dash"])
def test_legitimate_slug_shapes_are_accepted(workflows, slug):
    """A leading underscore is a real name; only a leading dot is not."""
    (workflows["dir"] / f"{slug}.json").write_text("{}")

    response = client.delete(f"/workflows/{slug}")

    assert response.status_code == 200, response.json()
    assert not (workflows["dir"] / f"{slug}.json").exists()
