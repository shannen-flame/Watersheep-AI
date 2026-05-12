"""Conversation history persistence so the assistant has memory across sessions."""

from __future__ import annotations

from datetime import datetime
from sqlite3 import Row

from ..models.schemas import (
    ConversationTurnCreate,
    ConversationTurnResponse,
    ConversationHistoryResponse,
)
from ..utils.datetime import utc_now_iso
from .storage import get_connection


VALID_ROLES = {"user", "assistant", "system"}


def append_turn(payload: ConversationTurnCreate) -> ConversationTurnResponse:
    role = payload.role.strip().lower()
    if role not in VALID_ROLES:
        role = "user"
    text = payload.text.strip()
    if not text:
        text = "(empty)"
    created_at = utc_now_iso()

    with get_connection() as connection:
        cursor = connection.execute(
            """
            INSERT INTO conversation_turns (role, text, source, created_at)
            VALUES (?, ?, ?, ?)
            """,
            (role, text, (payload.source or "ios").strip(), created_at),
        )
        turn_id = int(cursor.lastrowid)

    return ConversationTurnResponse(
        id=turn_id,
        role=role,
        text=text,
        source=(payload.source or "ios").strip(),
        created_at=datetime.fromisoformat(created_at),
    )


def list_turns(limit: int = 40) -> ConversationHistoryResponse:
    with get_connection() as connection:
        rows = connection.execute(
            """
            SELECT id, role, text, source, created_at
            FROM conversation_turns
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()

    turns = [_row_to_turn(row) for row in reversed(rows)]
    return ConversationHistoryResponse(count=len(turns), turns=turns)


def clear_turns() -> int:
    with get_connection() as connection:
        cursor = connection.execute("DELETE FROM conversation_turns")
        return cursor.rowcount


def _row_to_turn(row: Row) -> ConversationTurnResponse:
    return ConversationTurnResponse(
        id=int(row["id"]),
        role=str(row["role"]),
        text=str(row["text"]),
        source=str(row["source"] or ""),
        created_at=datetime.fromisoformat(row["created_at"]),
    )
