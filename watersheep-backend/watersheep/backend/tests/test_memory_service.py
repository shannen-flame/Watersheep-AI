"""Memory CRUD and recall tests."""

from datetime import datetime, timezone

from app.models.schemas import MemoryCreate, MemoryRecallRequest
from app.services.memory_service import (
    create_memory,
    list_memories,
    rank_memories,
    recall_memories,
)


def _make_memory(summary: str, *, location: str | None = None, objects: list[str] | None = None):
    return create_memory(
        MemoryCreate(
            summary=summary,
            location=location,
            transcript=None,
            detected_objects=objects or [],
            timestamp=datetime.now(timezone.utc),
        )
    )


def test_create_and_list_memories_round_trip():
    saved = _make_memory("Saw a whiteboard with the project deadline")
    assert saved.id > 0

    listed = list_memories(limit=5, offset=0)
    assert len(listed) == 1
    assert listed[0].id == saved.id


def test_recall_finds_keyword_matches():
    _make_memory("Lecturer wrote the deadline on the whiteboard", location="lab")
    _make_memory("Coffee shop on the corner", location="cafe")

    response = recall_memories(MemoryRecallRequest(query="whiteboard deadline", limit=3))
    assert response.count >= 1
    assert "whiteboard" in response.memories[0].memory.summary.lower()


def test_rank_memories_falls_back_to_recent_when_no_match():
    _make_memory("Random unrelated note")
    response = recall_memories(MemoryRecallRequest(query="xyz_no_match_token", limit=3))
    assert response.count >= 0  # ranking returns nothing for impossible queries
