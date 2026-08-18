"""Workflow CRUD — currently just delete.

Saved workflows are JSON files under ``storage/workflows/<id>.json``, written today
by the Flutter ``WorkflowStore`` (whose ``slug`` is this module's ``workflow_id``).
Both sides resolve the same directory on the same machine, so a backend delete and
a client-side listing stay in agreement.

Two things are worth reading before changing anything here.

**``workflow_id`` becomes a filename.** It arrives from the URL, so it is validated
against :data:`WORKFLOW_ID` before it is ever joined to a path, and the resolved
path is checked to still be inside the workflows directory. Without both checks a
``DELETE /workflows/..%2F..%2Fsomething`` would remove arbitrary files.

**The 409 is real but currently unreachable.** Execution is driven from the canvas
today, so nothing marks a workflow as running. :class:`ExecutionRegistry` is the
seam a server-side runner would call (``begin`` / ``end``), and the delete route
already refuses while it reports work in flight — so the guard exists before the
engine does, rather than being retrofitted after the first bad delete.
"""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException

from .models import WorkflowDeleteResponse

#: A workflow id is a bare filename stem: letters, digits, dot, dash, underscore.
#: Anything with a path separator, or any form of ``..``, is not an id.
#:
#: The first character may be an underscore but **not** a dot: a slug like
#: ``_draft`` is a legitimate name, while a leading dot would name a hidden file
#: and is the first half of ``..``.
WORKFLOW_ID = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")

router = APIRouter(prefix="/workflows", tags=["workflows"])


def storage_root() -> Path:
    """The repo's ``storage/`` directory.

    ``$DN_STORAGE_DIR`` overrides it, matching the compile-time constant of the
    same name on the Dart side so both ends can be pointed at a scratch tree.
    """
    override = os.environ.get("DN_STORAGE_DIR")
    if override:
        return Path(override).expanduser()
    # src/double_touch/workflows_router.py → <repo>/storage
    return Path(__file__).resolve().parents[3] / "storage"


class ExecutionRegistry:
    """In-process record of workflows with work in flight, and their cached state.

    Deliberately minimal: a counter per workflow so nested or concurrent runs do
    not clear the flag early, plus a slot for whatever a runner wants to cache.
    """

    def __init__(self) -> None:
        self._active: dict[str, int] = {}
        self._cache: dict[str, object] = {}

    def begin(self, workflow_id: str) -> None:
        """Mark one task started for [workflow_id]."""
        self._active[workflow_id] = self._active.get(workflow_id, 0) + 1

    def end(self, workflow_id: str) -> None:
        """Mark one task finished. Never goes negative."""
        remaining = self._active.get(workflow_id, 0) - 1
        if remaining > 0:
            self._active[workflow_id] = remaining
        else:
            self._active.pop(workflow_id, None)

    def active_tasks(self, workflow_id: str) -> int:
        return self._active.get(workflow_id, 0)

    def is_active(self, workflow_id: str) -> bool:
        return self.active_tasks(workflow_id) > 0

    def cache(self, workflow_id: str, state: object) -> None:
        self._cache[workflow_id] = state

    def cached(self, workflow_id: str) -> Optional[object]:
        return self._cache.get(workflow_id)

    def purge(self, workflow_id: str) -> bool:
        """Drop any cached execution state. True if something was dropped."""
        return self._cache.pop(workflow_id, None) is not None


#: Process-wide registry. A future server-side runner should call `begin`/`end`.
executions = ExecutionRegistry()


class WorkflowStorage:
    """The on-disk workflow definitions."""

    def __init__(self, directory: Optional[Path] = None) -> None:
        self.directory = Path(directory) if directory else storage_root() / "workflows"

    def path_for(self, workflow_id: str) -> Path:
        """Absolute path of [workflow_id]'s definition file.

        Raises:
            ValueError: the id is not a bare filename stem, or resolves outside the
                workflows directory. Both are checked: the pattern rejects the
                obvious traversal, and the containment check catches anything a
                symlink or an unusual encoding sneaks past it.
        """
        if not WORKFLOW_ID.match(workflow_id) or workflow_id in (".", ".."):
            raise ValueError(f"not a valid workflow id: {workflow_id!r}")

        candidate = (self.directory / f"{workflow_id}.json").resolve()
        root = self.directory.resolve()
        if root not in candidate.parents:
            raise ValueError(f"workflow id escapes the workflow directory: {workflow_id!r}")
        return candidate

    def exists(self, workflow_id: str) -> bool:
        try:
            return self.path_for(workflow_id).is_file()
        except ValueError:
            return False

    def delete(self, workflow_id: str) -> bool:
        """Remove the definition file. True if a file was actually removed."""
        path = self.path_for(workflow_id)
        if not path.is_file():
            return False
        path.unlink()

        # A workflow may also have a sidecar directory of run artefacts; remove it
        # with the definition so a delete does not leave orphans behind.
        sidecar = self.directory / workflow_id
        if sidecar.is_dir():
            shutil.rmtree(sidecar, ignore_errors=True)
        return True


def get_workflow_storage() -> WorkflowStorage:
    """Storage provider — overridden in tests via `app.dependency_overrides`."""
    return WorkflowStorage()


def get_executions() -> ExecutionRegistry:
    """Registry provider — overridden in tests."""
    return executions


@router.delete("/{workflow_id}", response_model=WorkflowDeleteResponse)
async def delete_workflow(
    workflow_id: str,
    storage: WorkflowStorage = Depends(get_workflow_storage),
    running: ExecutionRegistry = Depends(get_executions),
) -> WorkflowDeleteResponse:
    """Delete a saved workflow definition and purge its cached execution state.

    * **404** — no such workflow, or an id that could never name one. A malformed
      id is not reported differently from a missing one: both mean "there is
      nothing here to delete", and distinguishing them would only describe the
      filesystem to a caller that has no business knowing.
    * **409** — the execution registry reports tasks in flight for this workflow.
      Deleting the definition under a running graph would strand it.
    * **200** — `{"status": "SUCCESS", "workflowId": …}`.

    Note the response key is camelCase, per the binding wire convention in
    `DESIGN.md`; the Dart client accepts either spelling.
    """
    if not storage.exists(workflow_id):
        raise HTTPException(
            status_code=404, detail=f"no such workflow: {workflow_id!r}"
        )

    if running.is_active(workflow_id):
        raise HTTPException(
            status_code=409,
            detail=(
                f"workflow {workflow_id!r} has "
                f"{running.active_tasks(workflow_id)} task(s) in flight; "
                "stop the run before deleting it"
            ),
        )

    try:
        deleted = storage.delete(workflow_id)
    except OSError as exc:
        raise HTTPException(
            status_code=500, detail=f"could not delete {workflow_id!r}: {exc}"
        ) from exc

    if not deleted:
        # Vanished between the check and the unlink — the caller's intent is
        # satisfied either way, but say so rather than reporting a delete.
        raise HTTPException(
            status_code=404, detail=f"no such workflow: {workflow_id!r}"
        )

    running.purge(workflow_id)
    return WorkflowDeleteResponse(status="SUCCESS", workflow_id=workflow_id)
