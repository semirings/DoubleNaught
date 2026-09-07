"""Persistence for SegForge segmentation sessions as Parquet files.

SegForge sessions (masks, boxes, scores, prompts) are serialized to Arrow/Parquet
format for later inspection and re-display without re-running the segmentation model.

Each saved session is a Parquet file under `storage/segforge_sessions/{session_id}.parquet`,
with schema:
  - session_id: string (PK)
  - created_at: string (ISO 8601)
  - name: string (session name from DN)
  - description: string (session description from DN)
  - image_url: string (URL to fetch image from SF backend)
  - width: int (original image width)
  - height: int (original image height)
  - prompts: string (JSON list of all prompts used)
  - segment_index: int (0-based, per-segment row key)
  - box: list<double> ([x0, y0, x1, y1] in pixel coordinates)
  - score: double (confidence 0..1)
  - mask_rle: string (RLE encoded mask as JSON {counts, size})
"""

from __future__ import annotations

import json
import base64
from pathlib import Path
from typing import Dict, Any, Optional, List
import pyarrow as pa
import pyarrow.parquet as pq


class SegForgeSessionStore:
    """Persist and restore SegForge sessions to/from Parquet files."""

    def __init__(self, storage_dir: Path):
        """Initialize store with a root storage directory.

        Args:
            storage_dir: Path where SegForge session Parquet files will be stored.
                        E.g., ~/.dn_cache/storage/segforge_sessions/
        """
        self.storage_dir = Path(storage_dir)
        self.storage_dir.mkdir(parents=True, exist_ok=True)

    def save_session(
        self,
        session_id: str,
        session_data: Dict[str, Any],
    ) -> Path:
        """Save a SegForge session response to Parquet.

        Args:
            session_id: Unique session identifier.
            session_data: Response from SF backend /loadSession/{id} endpoint, containing:
                - session_id, created_at, name, description, image_url
                - width, height
                - image_b64 (optional, for later reconstruction)
                - prompts (list)
                - results (dict with masks, boxes, scores)

        Returns:
            Path to the saved Parquet file.
        """
        # Extract metadata
        metadata = {
            "session_id": session_data.get("session_id"),
            "created_at": session_data.get("created_at"),
            "name": session_data.get("name"),
            "description": session_data.get("description"),
            "image_url": session_data.get("image_url"),
            "width": session_data.get("width"),
            "height": session_data.get("height"),
        }

        # Extract segmentation results
        results = session_data.get("results", {})
        prompts = session_data.get("prompts", [])
        masks_rle = results.get("masks", [])
        boxes = results.get("boxes", [])
        scores = results.get("scores", [])

        # Build row data: one row per segment (box/score/mask triple)
        rows = []
        num_segments = max(len(boxes), len(masks_rle), len(scores))

        for i in range(num_segments):
            row = {
                "session_id": metadata["session_id"],
                "created_at": metadata["created_at"],
                "name": metadata["name"],
                "description": metadata["description"],
                "image_url": metadata["image_url"],
                "width": metadata["width"],
                "height": metadata["height"],
                "prompts": json.dumps(prompts),
                "segment_index": i,
                "box": boxes[i] if i < len(boxes) else None,
                "score": scores[i] if i < len(scores) else None,
                "mask_rle": json.dumps(masks_rle[i]) if i < len(masks_rle) else None,
            }
            rows.append(row)

        # Convert to PyArrow table
        table = pa.table({
            "session_id": [r["session_id"] for r in rows],
            "created_at": [r["created_at"] for r in rows],
            "name": [r["name"] for r in rows],
            "description": [r["description"] for r in rows],
            "image_url": [r["image_url"] for r in rows],
            "width": [r["width"] for r in rows],
            "height": [r["height"] for r in rows],
            "prompts": [r["prompts"] for r in rows],
            "segment_index": [r["segment_index"] for r in rows],
            "box": [r["box"] for r in rows],
            "score": [r["score"] for r in rows],
            "mask_rle": [r["mask_rle"] for r in rows],
        })

        # Write to Parquet
        output_path = self.storage_dir / f"{session_id}.parquet"
        pq.write_table(table, output_path)
        return output_path

    def load_session(self, session_id: str) -> Optional[Dict[str, Any]]:
        """Load a saved SegForge session from Parquet.

        Args:
            session_id: Unique session identifier.

        Returns:
            Session data dict matching /loadSession/{id} response, or None if not found.
        """
        parquet_path = self.storage_dir / f"{session_id}.parquet"
        if not parquet_path.exists():
            return None

        table = pq.read_table(parquet_path)
        rows = table.to_pylist()

        if not rows:
            return None

        # Reconstruct session from first row (metadata is same across all rows)
        first = rows[0]
        session = {
            "session_id": first["session_id"],
            "created_at": first["created_at"],
            "name": first["name"],
            "description": first["description"],
            "image_url": first["image_url"],
            "width": first["width"],
            "height": first["height"],
            "prompts": json.loads(first["prompts"]),
            "results": {
                "boxes": [r["box"] for r in rows if r["box"] is not None],
                "scores": [r["score"] for r in rows if r["score"] is not None],
                "masks": [
                    json.loads(r["mask_rle"]) for r in rows
                    if r["mask_rle"] is not None
                ],
            },
        }
        return session

    def list_sessions(self) -> List[Dict[str, str]]:
        """List all saved sessions with metadata.

        Returns:
            List of dicts with session_id, name, description, created_at, image_url.
        """
        sessions = []
        for parquet_path in sorted(self.storage_dir.glob("*.parquet")):
            try:
                table = pq.read_table(parquet_path)
                rows = table.to_pylist()
                if rows:
                    first = rows[0]
                    sessions.append({
                        "session_id": first["session_id"],
                        "name": first["name"],
                        "description": first["description"],
                        "created_at": first["created_at"],
                        "image_url": first["image_url"],
                    })
            except Exception as e:
                print(f"Warning: Failed to read {parquet_path}: {e}")

        return sessions

    def delete_session(self, session_id: str) -> bool:
        """Delete a saved session's Parquet file.

        Args:
            session_id: Session to delete.

        Returns:
            True if deleted, False if not found.
        """
        parquet_path = self.storage_dir / f"{session_id}.parquet"
        if parquet_path.exists():
            parquet_path.unlink()
            return True
        return False
