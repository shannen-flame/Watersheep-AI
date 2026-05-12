"""Request and response schemas for the Watersheep API."""

from __future__ import annotations

import datetime as dt
from typing import Any

from pydantic import BaseModel, Field, model_validator


class HealthResponse(BaseModel):
    """Health payload returned by the service."""

    status: str
    app_name: str
    environment: str


class ProviderHealth(BaseModel):
    """Liveness signal for a single backing service."""

    available: bool
    detail: str
    latency_ms: int | None = None
    models: list[str] | None = None
    expected_model: str | None = None
    expected_model_available: bool | None = None


class ConversationTurnCreate(BaseModel):
    """Incoming conversation turn from the iOS app."""

    role: str = Field(..., min_length=1, examples=["user", "assistant", "system"])
    text: str = Field(..., min_length=1, max_length=8_000)
    source: str | None = Field(default="ios", examples=["voice", "typed", "system"])


class ConversationTurnResponse(BaseModel):
    """Persisted conversation turn returned to clients."""

    id: int
    role: str
    text: str
    source: str
    created_at: dt.datetime


class ConversationHistoryResponse(BaseModel):
    """Wrapper for paginated conversation history."""

    count: int
    turns: list[ConversationTurnResponse]


class DiagnosticsResponse(BaseModel):
    """Deeper diagnostics returned by /api/diagnostics."""

    status: str
    app_name: str
    environment: str
    ollama: ProviderHealth
    gemini: ProviderHealth
    openrouter: ProviderHealth
    database: ProviderHealth
    cors_origins: list[str] = Field(default_factory=list)
    debug_endpoints_enabled: bool = True


class MemoryBase(BaseModel):
    """Shared stored-memory fields."""

    summary: str = Field(..., min_length=1, examples=["Saw a lecturer writing project deadlines on a whiteboard."])
    location: str | None = Field(default=None, examples=["University lab"])
    transcript: str | None = Field(
        default=None,
        examples=["The lecturer said the backend demo is due next Friday at 2 PM."],
    )
    detected_objects: list[str] = Field(
        default_factory=list,
        examples=[["whiteboard", "laptop", "projector"]],
    )
    image_path: str | None = Field(
        default=None,
        examples=["captures/2026-03-15/session-01/frame-0001.jpg"],
    )
    embedding: list[float] | None = Field(
        default=None,
        examples=[[0.12, -0.08, 0.44]],
    )


class MemoryCreate(MemoryBase):
    """Payload for saving a new memory."""

    timestamp: dt.datetime = Field(..., examples=["2026-03-15T14:30:00Z"])


class MemoryUpdate(BaseModel):
    """Fields that can be updated after memory creation."""

    location: str | None = None
    summary: str | None = Field(default=None, min_length=1)
    transcript: str | None = None
    detected_objects: list[str] | None = None
    image_path: str | None = None
    embedding: list[float] | None = None


class MemoryResponse(MemoryBase):
    """Saved memory returned from the API."""

    id: int
    timestamp: dt.datetime
    created_at: dt.datetime
    updated_at: dt.datetime


class MemoryListResponse(BaseModel):
    """Paginated-style wrapper for listing memories."""

    count: int
    memories: list[MemoryResponse]


class MessageRequest(BaseModel):
    """Incoming voice or text command for the assistant."""

    message: str = Field(..., min_length=1, examples=["what's the weather"])


class MessageResponse(BaseModel):
    """Assistant response for the compatibility message endpoint."""

    intent: str
    reply: str
    action_result: dict[str, object] | None = None


class MemoryRecallRequest(BaseModel):
    """Payload for ranked memory recall."""

    query: str = Field(
        ...,
        min_length=1,
        examples=["when did I see my skateboard"],
    )
    limit: int = Field(default=5, ge=1, le=20, examples=[5])


class RecalledMemory(BaseModel):
    """A recalled memory plus a relevance score for ranking."""

    score: float = Field(..., examples=[10.5])
    memory: MemoryResponse


class AskQuestionRequest(BaseModel):
    """Payload for asking the assistant a question."""

    question: str = Field(..., min_length=1, examples=["What was that task deadline I saw earlier?"])
    scene_context: str | None = Field(default=None, examples=["Laptop screen with calendar and to-do list"])
    memory_limit: int = Field(default=3, ge=1, le=10)
    llm_provider: str | None = Field(default=None, examples=["ollama"])
    llm_model: str | None = Field(default=None, examples=["llama3.2:3b"])


class UsedMemoryItem(BaseModel):
    """Normalized memory metadata returned to clients."""

    memory: str
    timestamp: str
    type: str = "memory"


class AskQuestionResponse(BaseModel):
    """Assistant response normalized for mobile clients."""

    assistant_message: str
    used_memories: list[UsedMemoryItem] = Field(default_factory=list)
    question: str | None = None
    answer: str | None = None
    reply: str | None = None
    llm_provider: str | None = Field(default=None, examples=["ollama", "gemini", "openrouter"])
    llm_model: str | None = Field(default=None, examples=["llama3.2:3b"])

    @model_validator(mode="before")
    @classmethod
    def normalize_payload(cls, data: Any) -> Any:
        """Normalize legacy response shapes before model validation."""

        if not isinstance(data, dict):
            return data

        assistant_message = (
            data.get("assistant_message")
            or data.get("reply")
            or data.get("answer")
            or ""
        )
        normalized = dict(data)
        normalized["assistant_message"] = str(assistant_message)
        normalized["answer"] = str(normalized.get("answer") or assistant_message)
        normalized["reply"] = str(normalized.get("reply") or assistant_message)
        normalized["used_memories"] = _normalize_used_memories(
            normalized.get("used_memories")
        )
        return normalized


class AssistantRequest(BaseModel):
    """Unified typed or voice assistant request."""

    message: str = Field(..., min_length=1, examples=["Help me plan my next task"])
    scene_context: str | None = None
    source: str = Field(default="typed", examples=["typed", "voice", "quick_action"])
    llm_provider: str | None = None
    llm_model: str | None = None


class AssistantResponse(BaseModel):
    """Unified assistant response used by new frontend flows."""

    assistant_message: str
    intent: str = "general_chat"
    should_speak: bool = True
    used_memories: list[UsedMemoryItem] = Field(default_factory=list)
    action_result: dict[str, object] | None = None
    suggested_actions: list[str] = Field(default_factory=list)
    llm_provider: str | None = Field(default=None, examples=["ollama", "gemini", "openrouter"])
    llm_model: str | None = Field(default=None, examples=["llama3.2:3b"])


class InternetSearchRequest(BaseModel):
    """Text, product, or image-assisted internet search request."""

    query: str = Field(..., min_length=1, max_length=1_000, examples=["latest SwiftUI NavigationStack bug fix"])
    mode: str = Field(default="web", examples=["web", "product", "image"])
    scene_context: str | None = Field(default=None, max_length=8_000)
    image_base64: str | None = Field(default=None, max_length=12 * 1024 * 1024)
    provider: str | None = Field(default=None, max_length=80, examples=["auto", "brave", "tavily", "duckduckgo"])
    max_results: int = Field(default=5, ge=1, le=8)


class InternetSearchResultItem(BaseModel):
    """One filtered source returned to the iOS app."""

    title: str
    summary: str
    url: str
    source: str
    confidence: float = Field(default=0.5, ge=0, le=1)


class InternetSearchResponse(BaseModel):
    """Clean summarised internet research response."""

    query: str
    mode: str = "web"
    summary: str
    results: list[InternetSearchResultItem] = Field(default_factory=list)
    provider: str = "internet"
    confidence: float = Field(default=0, ge=0, le=1)
    exact_match: bool = False
    image_keywords: str | None = None


class QuickActionRequest(BaseModel):
    """Request to execute a first-class quick action."""

    action_id: str = Field(..., min_length=1, examples=["summarise_day"])
    scene_context: str | None = None
    source: str = Field(default="home")


class QuickActionResponse(BaseModel):
    """Result of a quick action execution."""

    action_id: str
    status: str
    assistant_message: str
    should_speak: bool = True
    action_result: dict[str, object] = Field(default_factory=dict)
    suggested_actions: list[str] = Field(default_factory=list)
    llm_provider: str | None = Field(default=None, examples=["ollama", "gemini", "openrouter"])
    llm_model: str | None = Field(default=None, examples=["llama3.2:3b"])


class InteractionEventCreate(BaseModel):
    """Client or backend interaction event used for personalization."""

    event_type: str = Field(..., min_length=1, examples=["quick_action_used"])
    source: str = Field(default="ios", examples=["ios", "backend"])
    payload: dict[str, Any] = Field(default_factory=dict)


class InteractionEventResponse(BaseModel):
    """Persisted interaction event."""

    id: int
    event_type: str
    source: str
    payload: dict[str, Any]
    created_at: dt.datetime


class PersonalizationSignal(BaseModel):
    """A learned, explainable personalization signal."""

    signal_key: str
    signal_value: str
    score: float
    metadata: dict[str, Any] = Field(default_factory=dict)


class PersonalizationProfileResponse(BaseModel):
    """Personalization profile derived from usage events."""

    suggested_actions: list[str] = Field(default_factory=list)
    preferred_response_style: str = "concise"
    signals: list[PersonalizationSignal] = Field(default_factory=list)
    event_count: int = 0


def _normalize_used_memories(value: Any) -> list[dict[str, str]]:
    """Always return used memories as a list of normalized objects."""

    if value is None:
        return []

    if isinstance(value, list):
        items = value
    else:
        items = [value]

    normalized_items: list[dict[str, str]] = []
    for item in items:
        normalized = _normalize_used_memory_item(item)
        if normalized is not None:
            normalized_items.append(normalized)
    return normalized_items


def _normalize_used_memory_item(item: Any) -> dict[str, str] | None:
    """Convert supported memory shapes into the iOS-safe response format."""

    if item is None:
        return None

    if isinstance(item, str):
        return {
            "memory": item,
            "timestamp": "",
            "type": "memory",
        }

    if isinstance(item, MemoryResponse):
        return {
            "memory": item.summary,
            "timestamp": item.timestamp.isoformat(),
            "type": "memory",
        }

    if isinstance(item, dict):
        memory_text = (
            item.get("memory")
            or item.get("summary")
            or item.get("text")
            or item.get("content")
            or ""
        )
        timestamp = item.get("timestamp") or item.get("created_at") or ""
        memory_type = item.get("type") or "memory"
        return {
            "memory": str(memory_text),
            "timestamp": str(timestamp),
            "type": str(memory_type),
        }

    memory_text = getattr(item, "memory", None) or getattr(item, "summary", None) or str(item)
    timestamp = getattr(item, "timestamp", "") or getattr(item, "created_at", "")
    memory_type = getattr(item, "type", "memory") or "memory"
    return {
        "memory": str(memory_text),
        "timestamp": str(timestamp),
        "type": str(memory_type),
    }


class MemoryRecallResponse(BaseModel):
    """Memory recall results."""

    query: str
    count: int
    memories: list[RecalledMemory]


class DaySummaryRequest(BaseModel):
    """Payload for requesting a day summary."""

    date: dt.date | None = Field(default=None, examples=["2026-03-15"])


class DaySummaryResponse(BaseModel):
    """Summarized view of a given day."""

    date: dt.date
    short_summary: str
    bullet_highlights: list[str]
    total_memories: int
    key_places: list[str]
    key_objects: list[str]


class VisionAnalysisResponse(BaseModel):
    """Structured response for uploaded image analysis."""

    image_path: str = Field(..., examples=["uploads/vision/2026/03/16/abc123-frame.jpg"])
    summary: str = Field(..., examples=["Placeholder analysis for an uploaded image from the iPhone app."])
    detected_objects: list[str] = Field(default_factory=list, examples=[["person", "laptop", "desk"]])
    extracted_text: str = Field(default="", examples=["CS project deadline: Friday 2 PM"])
    scene_description: str = Field(
        ...,
        examples=["Indoor study scene with a desk setup and items that could be useful for task recall."],
    )


class VisionProxyRequest(BaseModel):
    """JSON payload for Ollama-backed image understanding."""

    # Cap base64 payload at ~12 MB of base64 text (~9 MB raw bytes) to keep
    # multipart fallbacks consistent with WATERSHEEP_MAX_IMAGE_BYTES.
    image_base64: str | None = Field(
        default=None,
        max_length=12 * 1024 * 1024,
        examples=["iVBORw0KGgoAAAANSUhEUgAA..."],
    )
    prompt: str | None = Field(default=None, max_length=4_000, examples=["What am I looking at?"])
    scene_summary: str | None = Field(
        default=None,
        max_length=8_000,
        examples=["Objects: burger, fries, drink. Text: Morley's Chicken Burger Meal."],
    )
    model: str | None = Field(default=None, max_length=120, examples=["gemma3"])


class VisionProxyResponse(BaseModel):
    """Clean response returned by the Gemini-first image analysis pipeline."""

    assistant_message: str
    vision_summary: str
    vision_provider: str = "gemini"
    fallback_reason: str | None = None
    local_summary: str | None = None


class FrameAnalysisRequest(BaseModel):
    """Base64-encoded image frame sent from the glasses or phone app."""

    image: str | None = Field(
        default=None,
        max_length=12 * 1024 * 1024,
        examples=["iVBORw0KGgoAAAANSUhEUgAA..."],
    )
    frame: str | None = Field(
        default=None,
        max_length=12 * 1024 * 1024,
        examples=["iVBORw0KGgoAAAANSUhEUgAA..."],
    )


class GraphNode(BaseModel):
    """A concept node in the knowledge graph."""

    id: str
    label: str
    type: str = Field(..., examples=["object", "location"])
    count: int = Field(..., ge=0, examples=[3])


class GraphEdge(BaseModel):
    """A weighted relationship edge between two graph nodes."""

    source: str
    target: str
    weight: int = Field(..., ge=1, examples=[2])


class GraphResponse(BaseModel):
    """Knowledge graph returned by the /api/graph endpoint."""

    nodes: list[GraphNode]
    edges: list[GraphEdge]


class FrameAnalysisResponse(BaseModel):
    """Short scene description returned for a captured frame."""

    success: bool = Field(default=True, examples=[True])
    scene: str = Field(
        ...,
        examples=["A laptop on a desk with a keyboard and a phone next to it."],
    )
    suggestion: str = Field(default="", examples=[""])
    error: str = Field(default="", examples=[""])
    message: str = Field(default="", examples=["Gemini vision quota exceeded. Please wait and try again later."])
    retry_after_seconds: int = Field(default=0, examples=[15])
    vision_provider: str | None = Field(default=None, examples=["gemini"])
    fallback_reason: str | None = Field(default=None, examples=["gemini_quota_exceeded"])
    local_summary: str | None = None
