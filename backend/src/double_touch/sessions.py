"""In-memory session store.

A session pairs an uploaded image's dimensions with the running list of prompts
placed against it. The reference backend persists sessions to disk and holds the
SAM3 model state; this clean implementation keeps just what the route layer and
a (future) inference engine need. Swap for a persistent store when required.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class PromptRecord:
    kind: str  # "text" | "box" | "point"
    include: bool = True
    prompt: Optional[str] = None
    coordinates: Optional[list[float]] = None  # box [cx,cy,w,h] or point [x,y]


@dataclass
class Session:
    session_id: str
    original_width: int
    original_height: int
    prompts: list[PromptRecord] = field(default_factory=list)


class SessionStore:
    def __init__(self) -> None:
        self._sessions: dict[str, Session] = {}

    def create(self, width: int, height: int) -> Session:
        session = Session(
            session_id=uuid.uuid4().hex,
            original_width=width,
            original_height=height,
        )
        self._sessions[session.session_id] = session
        return session

    def get(self, session_id: str) -> Optional[Session]:
        return self._sessions.get(session_id)

    def __len__(self) -> int:
        return len(self._sessions)
