"""Real quick-action execution backed by assistant and memory services."""

from __future__ import annotations

import logging
from datetime import date, datetime, timezone

from ..models.schemas import (
    AskQuestionRequest,
    InteractionEventCreate,
    MemoryCreate,
    MemoryRecallRequest,
    QuickActionRequest,
    QuickActionResponse,
)
from .assistant_service import answer_question
from .event_service import record_event
from .memory_service import create_memory, recall_memories, summarise_day
from .personalization_service import build_personalization_profile

logger = logging.getLogger(__name__)


def execute_quick_action(payload: QuickActionRequest) -> QuickActionResponse:
    """Execute a quick action with real service logic."""

    action_id = normalize_action_id(payload.action_id)
    record_event(
        InteractionEventCreate(
            event_type="quick_action_used",
            source=payload.source,
            payload={"action_id": action_id, "scene_context": payload.scene_context or ""},
        )
    )

    if action_id == "what_am_i_looking_at":
        response = answer_question(
            AskQuestionRequest(
                question="What am I looking at?",
                scene_context=payload.scene_context,
                memory_limit=3,
            )
        )
        return _quick_action_response(
            action_id,
            response.assistant_message,
            {"type": "scene_help"},
            llm_provider=response.llm_provider,
            llm_model=response.llm_model,
        )

    if action_id == "remember_this":
        return _handle_remember_this(payload)

    if action_id == "recall_memory":
        recall = recall_memories(MemoryRecallRequest(query="what did I see recently", limit=3))
        if recall.memories:
            summaries = " ".join(item.memory.summary for item in recall.memories)
            message = f"Here is what I remember most recently: {summaries}"
        else:
            message = "I do not have any saved memories yet."
        return _quick_action_response(
            action_id,
            message,
            {"count": recall.count, "memories": [item.model_dump(mode="json") for item in recall.memories]},
        )

    if action_id == "summarise_day":
        summary = summarise_day(date.today())
        return _quick_action_response(
            action_id,
            summary.short_summary,
            summary.model_dump(mode="json"),
        )

    return QuickActionResponse(
        action_id=action_id,
        status="error",
        assistant_message=f"Unknown quick action: {payload.action_id}",
        should_speak=True,
        action_result={"error": "unknown_quick_action"},
        suggested_actions=build_personalization_profile().suggested_actions,
    )


def _handle_remember_this(payload: QuickActionRequest) -> QuickActionResponse:
    """Persist the current scene as a real memory entry."""

    scene_context = (payload.scene_context or "").strip()
    if not scene_context:
        return _quick_action_response(
            action_id="remember_this",
            message="I need an active scene before I can save what you are looking at.",
            result={"remembered": False, "reason": "missing_scene_context"},
        )

    summary = _summary_from_scene(scene_context)
    detected_objects = _extract_objects_from_scene(scene_context)
    transcript = scene_context

    try:
        memory = create_memory(
            MemoryCreate(
                summary=summary,
                transcript=transcript,
                detected_objects=detected_objects,
                timestamp=datetime.now(timezone.utc),
            )
        )
    except Exception as exc:
        logger.exception("Failed to persist remember_this memory: %s", exc)
        return _quick_action_response(
            action_id="remember_this",
            message="I could not save this memory just now. Please try again in a moment.",
            result={"remembered": False, "reason": "save_failed"},
        )

    return _quick_action_response(
        action_id="remember_this",
        message=f"Saved this memory: {summary}",
        result={
            "remembered": True,
            "memory_id": memory.id,
            "summary": memory.summary,
            "timestamp": memory.timestamp.isoformat(),
        },
    )


def _summary_from_scene(scene_context: str) -> str:
    """Build a short, summary-friendly version of the scene context."""

    cleaned = " ".join(scene_context.split())
    if len(cleaned) > 240:
        return cleaned[:237].rstrip() + "..."
    return cleaned


def _extract_objects_from_scene(scene_context: str) -> list[str]:
    """Pull object names out of an 'Objects: x, y, z. Text: ...' style scene string."""

    lower = scene_context.lower()
    objects_marker = "objects:"
    if objects_marker not in lower:
        return []

    start = lower.index(objects_marker) + len(objects_marker)
    remaining = scene_context[start:]
    end = remaining.find(".")
    object_block = remaining[: end if end != -1 else len(remaining)]
    return [
        item.strip().split(" ")[0]
        for item in object_block.split(",")
        if item.strip()
    ]


def normalize_action_id(value: str) -> str:
    """Map user-facing labels and old enum strings into stable action ids."""

    normalized = value.strip().lower().replace(" ", "_").replace("-", "_").replace("?", "")
    aliases = {
        "what_am_i_looking_at": "what_am_i_looking_at",
        "remember_this": "remember_this",
        "recall_memory": "recall_memory",
        "summarise_my_day": "summarise_day",
        "summarize_my_day": "summarise_day",
        "summarise_day": "summarise_day",
        "summarize_day": "summarise_day",
    }
    return aliases.get(normalized, normalized)


def _quick_action_response(
    action_id: str,
    message: str,
    result: dict[str, object],
    llm_provider: str | None = None,
    llm_model: str | None = None,
) -> QuickActionResponse:
    return QuickActionResponse(
        action_id=action_id,
        status="success",
        assistant_message=message,
        should_speak=True,
        action_result=result,
        suggested_actions=build_personalization_profile().suggested_actions,
        llm_provider=llm_provider,
        llm_model=llm_model,
    )
