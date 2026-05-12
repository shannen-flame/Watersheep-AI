"""Interaction event logging for analytics and personalization."""

from __future__ import annotations

import json
from datetime import datetime
from sqlite3 import Row
from typing import Any

from ..models.schemas import InteractionEventCreate, InteractionEventResponse
from ..utils.datetime import utc_now_iso
from .storage import get_connection


def record_event(payload: InteractionEventCreate) -> InteractionEventResponse:
    """Persist an interaction event and return it."""

    created_at = utc_now_iso()
    with get_connection() as connection:
        cursor = connection.execute(
            """
            INSERT INTO interaction_events (event_type, source, payload, created_at)
            VALUES (?, ?, ?, ?)
            """,
            (
                payload.event_type.strip(),
                payload.source.strip() or "unknown",
                json.dumps(payload.payload, ensure_ascii=True),
                created_at,
            ),
        )
        event_id = int(cursor.lastrowid)

    return InteractionEventResponse(
        id=event_id,
        event_type=payload.event_type.strip(),
        source=payload.source.strip() or "unknown",
        payload=payload.payload,
        created_at=datetime.fromisoformat(created_at),
    )


def list_events(limit: int = 200) -> list[InteractionEventResponse]:
    """Return recent interaction events."""

    with get_connection() as connection:
        rows = connection.execute(
            """
            SELECT id, event_type, source, payload, created_at
            FROM interaction_events
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()

    return [_row_to_event(row) for row in rows]


def count_events() -> int:
    """Return the total number of recorded events."""

    with get_connection() as connection:
        row = connection.execute("SELECT COUNT(*) AS count FROM interaction_events").fetchone()
    return int(row["count"]) if row else 0


def _row_to_event(row: Row) -> InteractionEventResponse:
    payload: dict[str, Any]
    try:
        loaded = json.loads(row["payload"] or "{}")
        payload = loaded if isinstance(loaded, dict) else {}
    except json.JSONDecodeError:
        payload = {}
    return InteractionEventResponse(
        id=int(row["id"]),
        event_type=str(row["event_type"]),
        source=str(row["source"]),
        payload=payload,
        created_at=datetime.fromisoformat(row["created_at"]),
    )
