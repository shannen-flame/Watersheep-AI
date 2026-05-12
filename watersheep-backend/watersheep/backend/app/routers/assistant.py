"""Assistant-facing endpoints for questions, memory, and summaries."""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Query

from ..utils.config import get_settings
from fastapi.responses import StreamingResponse

from ..models.schemas import (
    AssistantRequest,
    AssistantResponse,
    AskQuestionRequest,
    AskQuestionResponse,
    ConversationHistoryResponse,
    ConversationTurnCreate,
    ConversationTurnResponse,
    DaySummaryRequest,
    DaySummaryResponse,
    InteractionEventCreate,
    InteractionEventResponse,
    MemoryCreate,
    MemoryListResponse,
    MemoryRecallRequest,
    MemoryRecallResponse,
    MemoryResponse,
    MessageRequest,
    MessageResponse,
    PersonalizationProfileResponse,
    QuickActionRequest,
    QuickActionResponse,
)
from ..services.assistant_service import (
    answer_current_scene_question,
    answer_question,
    build_general_chat_prompt,
    is_present_scene_question,
    stream_chat_reply_with_meta,
)
from ..services.conversation_service import append_turn, clear_turns, list_turns
from ..services.event_service import list_events, record_event
from ..services.internet_service import answer_live_data_question
from ..services.message_service import process_message
from ..services.memory_service import (
    create_memory,
    list_memories,
    recall_memories,
    summarise_day,
)
from ..services.personalization_service import build_personalization_profile
from ..services.quick_action_service import execute_quick_action


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api", tags=["assistant"])
legacy_router = APIRouter(tags=["assistant"])


@router.post("/message", response_model=MessageResponse)
def message_endpoint(payload: MessageRequest) -> MessageResponse:
    """Compatibility message endpoint for simple voice commands."""

    return process_message(payload)


@legacy_router.post("/message", response_model=MessageResponse)
def legacy_message_endpoint(payload: MessageRequest) -> MessageResponse:
    """Top-level compatibility alias for older frontend message calls."""

    return process_message(payload)


@router.post("/ask", response_model=AskQuestionResponse)
def ask_question(payload: AskQuestionRequest) -> AskQuestionResponse:
    """Answer a question using recent or relevant visual memory context."""

    response = answer_question(payload)
    validated_response = AskQuestionResponse.model_validate(response.model_dump())
    logger.info(
        "Outgoing /api/ask payload: %s",
        validated_response.model_dump_json(),
    )
    return validated_response


@router.post("/assistant", response_model=AssistantResponse)
def assistant_endpoint(payload: AssistantRequest) -> AssistantResponse:
    """Unified assistant endpoint for typed, voice, and quick-action prompts."""

    answer = answer_question(
        AskQuestionRequest(
            question=payload.message,
            scene_context=payload.scene_context,
            llm_provider=payload.llm_provider,
            llm_model=payload.llm_model,
        )
    )
    return AssistantResponse(
        assistant_message=answer.assistant_message,
        intent="general_chat",
        should_speak=True,
        used_memories=answer.used_memories,
        suggested_actions=build_personalization_profile().suggested_actions,
        llm_provider=answer.llm_provider,
        llm_model=answer.llm_model,
    )


@router.post("/quick-actions", response_model=QuickActionResponse)
def quick_action_endpoint(payload: QuickActionRequest) -> QuickActionResponse:
    """Execute a real quick action and return a speakable assistant response."""

    return execute_quick_action(payload)


@router.post("/events", response_model=InteractionEventResponse, status_code=201)
def record_event_endpoint(payload: InteractionEventCreate) -> InteractionEventResponse:
    """Record a frontend interaction event for personalization."""

    return record_event(payload)


@router.get("/events", response_model=list[InteractionEventResponse])
def list_events_endpoint(limit: int = Query(100, ge=1, le=500)) -> list[InteractionEventResponse]:
    """List recent recorded events for debugging and learning inspection."""

    if not get_settings().debug_endpoints_enabled:
        raise HTTPException(status_code=404, detail="Not found")
    return list_events(limit=limit)


@router.get("/personalization", response_model=PersonalizationProfileResponse)
def personalization_profile_endpoint() -> PersonalizationProfileResponse:
    """Return explainable learned personalization signals."""

    return build_personalization_profile()


@router.post("/memories", response_model=MemoryResponse, status_code=201)
def save_memory(payload: MemoryCreate) -> MemoryResponse:
    """Persist a memory captured from the glasses or app."""

    return create_memory(payload)


@router.get("/memories", response_model=MemoryListResponse)
def list_memories_endpoint(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> MemoryListResponse:
    """Return stored memories for iOS list views."""

    memories = list_memories(limit=limit, offset=offset)
    return MemoryListResponse(count=len(memories), memories=memories)


@router.post("/memory/visual-experiences", response_model=MemoryResponse, status_code=201)
def remember_visual_experience(payload: MemoryCreate) -> MemoryResponse:
    """Backward-compatible alias for saving a memory from visual capture."""

    return create_memory(payload)


@router.post("/recall", response_model=MemoryRecallResponse)
def recall_memories_endpoint(payload: MemoryRecallRequest) -> MemoryRecallResponse:
    """Return the most relevant saved memories for a user query."""

    return recall_memories(payload)


@router.get("/memory/recall", response_model=MemoryRecallResponse)
def recall_memory(
    q: str = Query(..., min_length=1, description="Search phrase for memory recall."),
    limit: int = Query(5, ge=1, le=20),
) -> MemoryRecallResponse:
    """Backward-compatible GET alias for memory recall."""

    return recall_memories(MemoryRecallRequest(query=q, limit=limit))


@router.post("/summarise-day", response_model=DaySummaryResponse)
def summarise_day_endpoint(payload: DaySummaryRequest) -> DaySummaryResponse:
    """Summarise the user's day from stored memories."""

    return summarise_day(payload.date)


@router.post("/summaries/day", response_model=DaySummaryResponse)
def summarise_day_legacy_endpoint(payload: DaySummaryRequest) -> DaySummaryResponse:
    """Backward-compatible alias for the daily summary endpoint."""

    return summarise_day(payload.date)


@router.post("/conversation", response_model=ConversationTurnResponse, status_code=201)
def append_conversation_turn(payload: ConversationTurnCreate) -> ConversationTurnResponse:
    """Persist a single conversation turn so the assistant has cross-session memory."""

    return append_turn(payload)


@router.get("/conversation", response_model=ConversationHistoryResponse)
def get_conversation_history(limit: int = Query(40, ge=1, le=200)) -> ConversationHistoryResponse:
    """Return the most recent conversation turns in chronological order."""

    return list_turns(limit=limit)


@router.delete("/conversation", status_code=204)
def reset_conversation() -> None:
    """Wipe all stored conversation turns. Useful for the Privacy Mode toggle."""

    clear_turns()


@router.post("/assistant/stream")
async def stream_assistant(payload: AssistantRequest) -> StreamingResponse:
    """Stream the assistant reply as Server-Sent Events for word-by-word UI.

    Emits three event types:
      event: provider     # JSON {"name": "...", "model": "..."}
      data: <token chunk> # default 'message' event with one piece of text
      event: done         # terminator
    """

    import json as _json

    if payload.scene_context and is_present_scene_question(payload.message):
        answer = answer_current_scene_question(payload.message, payload.scene_context)

        async def static_scene_source():
            payload_json = _json.dumps({"name": "scene_context", "model": None})
            yield f"event: provider\ndata: {payload_json}\n\n"
            yield f"data: {answer.replace(chr(10), ' ').replace(chr(13), ' ')}\n\n"
            yield "event: done\ndata: end\n\n"

        return StreamingResponse(static_scene_source(), media_type="text/event-stream")

    live_answer = answer_live_data_question(payload.message)
    if live_answer is not None:

        async def static_live_data_source():
            payload_json = _json.dumps({"name": live_answer.provider, "model": live_answer.model})
            yield f"event: provider\ndata: {payload_json}\n\n"
            yield f"data: {live_answer.text.replace(chr(10), ' ').replace(chr(13), ' ')}\n\n"
            yield "event: done\ndata: end\n\n"

        return StreamingResponse(static_live_data_source(), media_type="text/event-stream")

    prompt = build_general_chat_prompt(payload.message, payload.scene_context)

    async def event_source():
        try:
            async for event in stream_chat_reply_with_meta(
                prompt, payload.llm_provider, payload.llm_model
            ):
                event_type = event.get("type")
                if event_type == "provider":
                    payload_json = _json.dumps({
                        "name": event.get("name"),
                        "model": event.get("model"),
                    })
                    yield f"event: provider\ndata: {payload_json}\n\n"
                elif event_type == "fallback":
                    yield f"event: fallback\ndata: {event.get('name', '')}\n\n"
                elif event_type == "token":
                    chunk = event.get("text", "")
                    if not chunk:
                        continue
                    # SSE uses \n as a line terminator inside the framing. Any
                    # \n that's part of the model's text would corrupt the
                    # stream, so collapse them to a literal space.
                    safe = chunk.replace("\r", " ").replace("\n", " ")
                    yield f"data: {safe}\n\n"
            yield "event: done\ndata: end\n\n"
        except Exception as exc:
            logger.exception("Assistant stream failed: %s", exc)
            safe_message = str(exc).replace("\n", " ").replace("\r", " ")
            yield f"event: error\ndata: {safe_message}\n\n"

    return StreamingResponse(event_source(), media_type="text/event-stream")
