"""Memory persistence, CRUD helpers, and recall logic."""

from __future__ import annotations

import json
import re
from collections import Counter
from datetime import date, datetime, timezone
from sqlite3 import Row
from typing import Iterable

from ..models.schemas import (
    DaySummaryResponse,
    MemoryCreate,
    MemoryRecallRequest,
    MemoryRecallResponse,
    MemoryResponse,
    MemoryUpdate,
    RecalledMemory,
)
from .storage import get_connection
from .embedding_service import cosine_similarity, generate_embedding
from ..utils.datetime import utc_now_iso
from ..utils.errors import AppError


def create_memory(payload: MemoryCreate) -> MemoryResponse:
    """Store a memory record and return the saved item."""

    now = utc_now_iso()
    embedding = payload.embedding or generate_embedding(
        " ".join(
            value
            for value in [payload.summary, payload.transcript or "", payload.location or ""]
            if value
        )
    )
    try:
        with get_connection() as connection:
            cursor = connection.execute(
                """
                INSERT INTO memories (
                    timestamp,
                    location,
                    summary,
                    transcript,
                    detected_objects,
                    image_path,
                    embedding,
                    created_at,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    payload.timestamp.isoformat(),
                    payload.location,
                    payload.summary,
                    payload.transcript,
                    _dump_json(payload.detected_objects),
                    payload.image_path,
                    _dump_json(embedding),
                    now,
                    now,
                ),
            )
            memory_id = int(cursor.lastrowid)
    except Exception as exc:
        raise AppError("Could not save the memory.", status_code=500) from exc

    created = get_memory(memory_id)
    if created is None:
        raise AppError("Memory was saved but could not be reloaded.", status_code=500)
    return created


def get_memory(memory_id: int) -> MemoryResponse | None:
    """Fetch a memory by its identifier."""

    with get_connection() as connection:
        row = connection.execute(
            """
            SELECT id, timestamp, location, summary, transcript, detected_objects,
                   image_path, embedding, created_at, updated_at
            FROM memories
            WHERE id = ?
            """,
            (memory_id,),
        ).fetchone()

    return _row_to_memory(row) if row else None


def list_memories(limit: int = 50, offset: int = 0) -> list[MemoryResponse]:
    """List memories ordered from newest to oldest."""

    with get_connection() as connection:
        rows = connection.execute(
            """
            SELECT id, timestamp, location, summary, transcript, detected_objects,
                   image_path, embedding, created_at, updated_at
            FROM memories
            ORDER BY timestamp DESC, id DESC
            LIMIT ? OFFSET ?
            """,
            (limit, offset),
        ).fetchall()

    return [_row_to_memory(row) for row in rows]


def update_memory(memory_id: int, payload: MemoryUpdate) -> MemoryResponse | None:
    """Update mutable memory fields and return the updated record."""

    existing = get_memory(memory_id)
    if existing is None:
        return None

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        return existing

    normalized = {
        "location": updates.get("location", existing.location),
        "summary": updates.get("summary", existing.summary),
        "transcript": updates.get("transcript", existing.transcript),
        "detected_objects": updates.get("detected_objects", existing.detected_objects),
        "image_path": updates.get("image_path", existing.image_path),
        "embedding": updates.get("embedding", existing.embedding),
        "updated_at": utc_now_iso(),
    }

    with get_connection() as connection:
        connection.execute(
            """
            UPDATE memories
            SET location = ?,
                summary = ?,
                transcript = ?,
                detected_objects = ?,
                image_path = ?,
                embedding = ?,
                updated_at = ?
            WHERE id = ?
            """,
            (
                normalized["location"],
                normalized["summary"],
                normalized["transcript"],
                _dump_json(normalized["detected_objects"]),
                normalized["image_path"],
                _dump_json(normalized["embedding"]),
                normalized["updated_at"],
                memory_id,
            ),
        )

    return get_memory(memory_id)


def delete_memory(memory_id: int) -> bool:
    """Delete a memory by id."""

    with get_connection() as connection:
        cursor = connection.execute("DELETE FROM memories WHERE id = ?", (memory_id,))
    return cursor.rowcount > 0


STOP_WORDS = {
    "a",
    "about",
    "again",
    "an",
    "and",
    "are",
    "at",
    "before",
    "can",
    "could",
    "did",
    "do",
    "does",
    "earlier",
    "find",
    "for",
    "from",
    "have",
    "help",
    "i",
    "in",
    "is",
    "it",
    "just",
    "last",
    "like",
    "look",
    "looking",
    "me",
    "memory",
    "memories",
    "my",
    "of",
    "please",
    "recall",
    "recent",
    "remember",
    "see",
    "seen",
    "show",
    "that",
    "this",
    "the",
    "to",
    "was",
    "we",
    "what",
    "when",
    "where",
    "with",
    "you",
}

GENERIC_RECALL_PHRASES = (
    "what did i see",
    "what have i seen",
    "what do you remember",
    "what did you remember",
    "show my memories",
    "recent memories",
)


def search_memories(query: str, limit: int = 5) -> list[MemoryResponse]:
    """Backward-compatible helper that returns only the matched memory records."""

    ranked = recall_memories(MemoryRecallRequest(query=query, limit=limit))
    return [item.memory for item in ranked.memories]


def recall_memories(payload: MemoryRecallRequest) -> MemoryRecallResponse:
    """Recall the most relevant memories for a user query."""

    candidates = fetch_recall_candidates(payload.query, candidate_limit=max(payload.limit * 5, 25))
    ranked = rank_memories(payload.query, candidates, limit=payload.limit)
    if not ranked and candidates and is_generic_recall_query(payload.query):
        ranked = [
            RecalledMemory(score=0.1, memory=memory)
            for memory in candidates[: payload.limit]
        ]
    return MemoryRecallResponse(
        query=payload.query,
        count=len(ranked),
        memories=ranked,
    )


def fetch_recall_candidates(query: str, candidate_limit: int = 25) -> list[MemoryResponse]:
    """Fetch broad recall candidates from SQLite before in-Python ranking.

    This stage is intentionally simple. Later we can add a FAISS or other vector
    index here and merge semantic candidates with these keyword matches.
    """

    normalized_query = normalize_text(query)
    query_tokens = tokenize_query(query)
    search_terms = [normalized_query] if normalized_query else []
    for token in query_tokens:
        if token not in search_terms:
            search_terms.append(token)

    if not search_terms:
        return fetch_recent_memories(candidate_limit)

    where_clauses: list[str] = []
    parameters: list[object] = []
    for term in search_terms:
        pattern = f"%{term}%"
        where_clauses.append(
            """
            lower(summary) LIKE ?
            OR lower(COALESCE(transcript, '')) LIKE ?
            OR lower(COALESCE(location, '')) LIKE ?
            OR lower(COALESCE(detected_objects, '[]')) LIKE ?
            """
        )
        parameters.extend([pattern, pattern, pattern, pattern])

    where_sql = " OR ".join(f"({clause.strip()})" for clause in where_clauses)
    with get_connection() as connection:
        rows = connection.execute(
            f"""
            SELECT id, timestamp, location, summary, transcript, detected_objects,
                   image_path, embedding, created_at, updated_at
            FROM memories
            WHERE {where_sql}
            ORDER BY timestamp DESC, id DESC
            LIMIT ?
            """,
            [*parameters, candidate_limit],
        ).fetchall()

    candidates = [_row_to_memory(row) for row in rows]
    if candidates:
        return candidates

    if is_generic_recall_query(query):
        return fetch_recent_memories(candidate_limit)

    return []


def fetch_recent_memories(limit: int = 25) -> list[MemoryResponse]:
    """Return recent memories when a query has no useful keyword anchor."""

    with get_connection() as connection:
        rows = connection.execute(
            """
            SELECT id, timestamp, location, summary, transcript, detected_objects,
                   image_path, embedding, created_at, updated_at
            FROM memories
            ORDER BY timestamp DESC, id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()

    return [_row_to_memory(row) for row in rows]


def rank_memories(query: str, memories: Iterable[MemoryResponse], limit: int = 5) -> list[RecalledMemory]:
    """Score and sort memories by keyword + semantic relevance."""

    scored_memories: list[RecalledMemory] = []
    query_embedding = generate_embedding(query)

    # If we have a query embedding, do a semantic-first pass so memories with
    # no keyword match but high vector similarity still surface.
    semantic_threshold = 0.55

    for memory in memories:
        score = score_memory_relevance(query, memory, query_embedding=query_embedding)
        if score == 0 and query_embedding is not None and memory.embedding:
            similarity = cosine_similarity(query_embedding, memory.embedding)
            if similarity >= semantic_threshold:
                score = similarity * 6.0
        if score > 0:
            scored_memories.append(RecalledMemory(score=round(score, 3), memory=memory))

    scored_memories.sort(
        key=lambda item: (
            -item.score,
            -item.memory.timestamp.timestamp(),
            -item.memory.id,
        )
    )
    return scored_memories[:limit]


def score_memory_relevance(
    query: str,
    memory: MemoryResponse,
    query_embedding: list[float] | None = None,
) -> float:
    """Return a relevance score for a memory against a query."""

    normalized_query = normalize_text(query)
    tokens = tokenize_query(query)
    if not normalized_query:
        return 0.0

    summary_text = normalize_text(memory.summary)
    transcript_text = normalize_text(memory.transcript or "")
    location_text = normalize_text(memory.location or "")
    objects_text = normalize_text(" ".join(memory.detected_objects))

    score = 0.0

    if normalized_query in summary_text:
        score += 8.0
    if normalized_query in transcript_text:
        score += 6.0
    if normalized_query in objects_text:
        score += 7.0
    if normalized_query in location_text:
        score += 5.0

    for token in tokens:
        if token in summary_text:
            score += 3.0
        if token in transcript_text:
            score += 2.0
        if token in objects_text:
            score += 2.5
        if token in location_text:
            score += 1.5

    if len(tokens) > 1:
        overlap_bonus = count_query_token_matches(tokens, memory)
        score += overlap_bonus * 0.75

    semantic_similarity = cosine_similarity(query_embedding, memory.embedding)
    if semantic_similarity > 0:
        score += semantic_similarity * 6.0

    return round(score, 3)


def tokenize_query(query: str) -> list[str]:
    """Tokenize a recall query and drop low-signal words."""

    return [
        token
        for token in re.findall(r"[a-z0-9]+", query.lower())
        if token not in STOP_WORDS and len(token) > 1
    ]


def is_generic_recall_query(query: str) -> bool:
    """Return True for broad memory requests that should use recent context."""

    normalized_query = normalize_text(query)
    return any(phrase in normalized_query for phrase in GENERIC_RECALL_PHRASES)


def normalize_text(value: str) -> str:
    """Normalize text for matching."""

    return " ".join(re.findall(r"[a-z0-9]+", value.lower()))


def count_query_token_matches(tokens: list[str], memory: MemoryResponse) -> int:
    """Count unique query tokens present anywhere in the memory metadata."""

    searchable = " ".join(
        [
            normalize_text(memory.summary),
            normalize_text(memory.transcript or ""),
            normalize_text(memory.location or ""),
            normalize_text(" ".join(memory.detected_objects)),
        ]
    )
    return sum(1 for token in set(tokens) if token in searchable)


def list_memories_for_date(target_date: date) -> list[MemoryResponse]:
    """Return all memories recorded on a given date."""

    with get_connection() as connection:
        rows = connection.execute(
            """
            SELECT id, timestamp, location, summary, transcript, detected_objects,
                   image_path, embedding, created_at, updated_at
            FROM memories
            WHERE date(timestamp) = ?
            ORDER BY timestamp ASC, id ASC
            """,
            (target_date.isoformat(),),
        ).fetchall()

    return [_row_to_memory(row) for row in rows]


def summarise_day(target_date: date | None) -> DaySummaryResponse:
    """Create a deterministic day summary from stored memories.

    This is intentionally rule-based for now. Later we can hand the same
    aggregated context to an LLM and keep the API response shape unchanged.
    """

    resolved_date = target_date or datetime.now(timezone.utc).date()
    memories = list_memories_for_date(resolved_date)

    if not memories:
        return DaySummaryResponse(
            date=resolved_date,
            short_summary="No memories were recorded for this day yet.",
            bullet_highlights=[],
            total_memories=0,
            key_places=[],
            key_objects=[],
        )

    key_places = extract_key_places(memories, limit=5)
    key_objects = extract_key_objects(memories, limit=5)
    bullet_highlights = build_bullet_highlights(memories, limit=5)
    short_summary = build_short_day_summary(
        target_date=resolved_date,
        total_memories=len(memories),
        key_places=key_places,
        key_objects=key_objects,
    )

    return DaySummaryResponse(
        date=resolved_date,
        short_summary=short_summary,
        bullet_highlights=bullet_highlights,
        total_memories=len(memories),
        key_places=key_places,
        key_objects=key_objects,
    )


def extract_key_places(memories: list[MemoryResponse], limit: int = 5) -> list[str]:
    """Return the most frequent non-empty locations for the day."""

    place_counter = Counter(
        memory.location.strip()
        for memory in memories
        if memory.location and memory.location.strip()
    )
    return [place for place, _count in place_counter.most_common(limit)]


def extract_key_objects(memories: list[MemoryResponse], limit: int = 5) -> list[str]:
    """Return the most frequent detected objects for the day."""

    object_counter = Counter(
        detected_object.strip()
        for memory in memories
        for detected_object in memory.detected_objects
        if detected_object.strip()
    )
    return [detected_object for detected_object, _count in object_counter.most_common(limit)]


def build_bullet_highlights(memories: list[MemoryResponse], limit: int = 5) -> list[str]:
    """Build concise bullet-friendly highlights from each memory."""

    highlights: list[str] = []
    for memory in memories[:limit]:
        time_label = memory.timestamp.strftime("%H:%M")
        location_label = memory.location or "an unknown location"
        objects = ", ".join(memory.detected_objects[:3]) if memory.detected_objects else "no key objects detected"
        highlights.append(
            f"{time_label} at {location_label}: {memory.summary} Objects: {objects}."
        )
    return highlights


def build_short_day_summary(
    target_date: date,
    total_memories: int,
    key_places: list[str],
    key_objects: list[str],
) -> str:
    """Build a deterministic short summary for the selected day."""

    places_text = ", ".join(key_places[:3]) if key_places else "no major places recorded"
    objects_text = ", ".join(key_objects[:3]) if key_objects else "no repeated objects detected"
    return (
        f"On {target_date.isoformat()}, you saved {total_memories} memories. "
        f"Key places included {places_text}, and the most common objects were {objects_text}."
    )


def _row_to_memory(row: Row) -> MemoryResponse:
    """Convert a SQLite row into a typed memory model."""

    return MemoryResponse(
        id=row["id"],
        timestamp=datetime.fromisoformat(row["timestamp"]),
        location=row["location"],
        summary=row["summary"],
        transcript=row["transcript"],
        detected_objects=_load_json_list(row["detected_objects"]),
        image_path=row["image_path"],
        embedding=_load_json_floats(row["embedding"]),
        created_at=datetime.fromisoformat(row["created_at"]),
        updated_at=datetime.fromisoformat(row["updated_at"]),
    )


def _dump_json(value: object) -> str | None:
    """Serialize JSON-compatible values for SQLite."""

    if value is None:
        return None
    return json.dumps(value, ensure_ascii=True)


def _load_json_list(value: str | None) -> list[str]:
    """Deserialize a string list from SQLite."""

    if not value:
        return []
    try:
        loaded = json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return []
    if not isinstance(loaded, list):
        return []
    return [str(item) for item in loaded]


def _load_json_floats(value: str | None) -> list[float] | None:
    """Deserialize the embedding placeholder from SQLite."""

    if not value:
        return None
    try:
        loaded = json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return None
    if not isinstance(loaded, list):
        return None
    try:
        return [float(item) for item in loaded]
    except (TypeError, ValueError):
        return None
