"""Question-answering logic for the Watersheep smart glasses assistant."""

from __future__ import annotations

from typing import Final

from collections.abc import AsyncIterator
from dataclasses import dataclass

from ..models.schemas import AskQuestionRequest, AskQuestionResponse, MemoryRecallRequest
from .event_service import record_event
from .llm_provider import (
    LLMProviderManager,
    LLMRequest,
    stream_reply,
    stream_reply_with_meta,
)
from .internet_service import answer_live_data_question
from .memory_service import recall_memories
from ..models.schemas import InteractionEventCreate


@dataclass(frozen=True)
class AssistantAnswer:
    """Bundle of LLM reply text plus the provider/model that produced it."""

    text: str
    provider: str | None
    model: str | None

MEMORY_QUERY_HINTS: Final[tuple[str, ...]] = (
    "did i see",
    "do you remember",
    "have you seen",
    "what did i see",
    "when did i see",
    "where did i see",
    "show my",
    "my notes",
    "my lecture notes",
    "remember when",
    "what was that",
    "what did we talk about",
)

WATERSHEEP_SYSTEM_PROMPT = """You are Watersheep, a friendly AI assistant living in the user's smart glasses and iPhone. Talk like a helpful friend, not a corporate bot.

How you talk:
- Keep it short. One or two sentences by default. Only go longer if the user actually asks for more.
- Use plain, everyday English. Contractions are fine ("I'll", "you're", "can't").
- Get to the answer immediately. No "Certainly", "Of course", "Great question", "As an AI...", and no repeating the question back.
- Don't narrate what you're doing ("Let me check...", "I'll look into that..."). Just answer.
- No bullet points or lists unless the user asks for a list.
- If you don't know, just say so in one line.

What you can do:
- Answer questions, give advice, explain things.
- Describe what the user is looking at when there's scene context.
- Save and recall personal memories.
- Help plan, schedule, focus, set reminders.

Rules:
- Only use facts from the prompt. Don't invent details about the user, the scene, or memories.
- Decline unsafe requests in one short sentence.
"""


def answer_question(payload: AskQuestionRequest) -> AskQuestionResponse:
    """Answer a question using memory when relevant, otherwise normal chat."""

    record_event(
        InteractionEventCreate(
            event_type="assistant_message",
            source="api",
            payload={"message": payload.question, "scene_context": payload.scene_context or ""},
        )
    )

    if payload.scene_context and is_present_scene_question(payload.question):
        answer = answer_current_scene_question(payload.question, payload.scene_context)
        return AskQuestionResponse(
            assistant_message=answer,
            question=payload.question,
            answer=answer,
            reply=answer,
            used_memories=[],
            llm_provider="scene_context",
            llm_model=None,
        )

    live_answer = answer_live_data_question(payload.question)
    if live_answer is not None:
        return AskQuestionResponse(
            assistant_message=live_answer.text,
            question=payload.question,
            answer=live_answer.text,
            reply=live_answer.text,
            used_memories=[],
            llm_provider=live_answer.provider,
            llm_model=live_answer.model,
        )

    memory_matches = []
    related_memories = []
    if should_attempt_memory_recall(payload.question):
        recall_result = recall_memories(
            MemoryRecallRequest(query=payload.question, limit=payload.memory_limit)
        )
        memory_matches = recall_result.memories
        related_memories = [item.memory for item in memory_matches]

    if should_use_memory_answer(payload.question, memory_matches):
        memory_lines = [
            _format_memory_line(memory.summary, memory.location)
            for memory in related_memories
        ]
        memory_text = " ".join(memory_lines)
        full = ask_llm_full(
            (
                f"The user asked: {payload.question}\n\n"
                f"You found these saved memories that may be relevant:\n{memory_text}\n\n"
                "Write a clear, professional answer that uses the memory context naturally. "
                "Keep it to two to four sentences."
            ),
            scene_context=None,
            llm_provider=payload.llm_provider,
            llm_model=payload.llm_model,
        )
        if full is not None:
            answer = full.text
            provider = full.provider
            model = full.model
        else:
            answer = f"From your saved memories: {memory_text}"
            provider = None
            model = None
    else:
        related_memories = []
        full = answer_general_question_full(
            payload.question,
            payload.scene_context,
            llm_provider=payload.llm_provider,
            llm_model=payload.llm_model,
        )
        answer = full.text
        provider = full.provider
        model = full.model

    return AskQuestionResponse(
        assistant_message=answer,
        question=payload.question,
        answer=answer,
        reply=answer,
        used_memories=related_memories,
        llm_provider=provider,
        llm_model=model,
    )


def should_use_memory_answer(question: str, memory_matches: list[object]) -> bool:
    """Return True when the question is clearly about a past memory."""

    if not memory_matches:
        return False

    lowered = question.strip().lower()
    if any(hint in lowered for hint in MEMORY_QUERY_HINTS):
        return True

    top_match = memory_matches[0]
    return getattr(top_match, "score", 0.0) >= 18.0


def should_attempt_memory_recall(question: str) -> bool:
    """Avoid querying memories for ordinary chat that does not reference the past."""

    lowered = question.strip().lower()
    if any(hint in lowered for hint in MEMORY_QUERY_HINTS):
        return True
    generic_memory_terms = (
        "remember",
        "memory",
        "memories",
        "recall",
        "earlier",
        "before",
        "yesterday",
        "last week",
        "last time",
    )
    return any(term in lowered for term in generic_memory_terms)


def is_present_scene_question(question: str) -> bool:
    """Return True when the user is asking about the current camera view."""

    lowered = question.strip().lower()
    phrases = (
        "what am i looking at",
        "wht am i looking at",
        "what am i seeing",
        "wht am i seeing",
        "what do you see",
        "what can you see",
        "what is this",
        "what's this",
        "whats this",
        "explain scene",
        "explain the scene",
        "explain what i'm seeing",
        "explain what i am seeing",
        "tell me what you see",
        "describe this",
        "describe what i'm looking at",
        "describe what i am looking at",
        "describe what i'm seeing",
        "describe what i am seeing",
        "what's in front of me",
        "whats in front of me",
        "what is in front of me",
        "read this",
        "help me with this",
    )
    return any(phrase in lowered for phrase in phrases)


def answer_current_scene_question(question: str, scene_context: str) -> str:
    """Answer current-scene questions from the exact vision caption."""

    scene = extract_current_scene_context(scene_context)
    if not scene:
        return "I don't have a current scene description yet."

    lowered = question.strip().lower()
    if "read" in lowered:
        return f"Visible scene/text: {scene}"
    return f"You're seeing: {scene}"


def extract_current_scene_context(scene_context: str | None) -> str:
    """Pull only the current scene from mixed app context."""

    if not scene_context:
        return ""

    cleaned = " ".join(scene_context.strip().split())
    if not cleaned:
        return ""

    lowered = cleaned.lower()
    marker = "current scene:"
    if marker in lowered:
        start = lowered.find(marker) + len(marker)
        cleaned = cleaned[start:].strip()
        next_markers = (" recent conversation:", " user:", " assistant:", " system:")
        lowered_cleaned = cleaned.lower()
        cut_points = [
            lowered_cleaned.find(next_marker)
            for next_marker in next_markers
            if lowered_cleaned.find(next_marker) != -1
        ]
        if cut_points:
            cleaned = cleaned[: min(cut_points)].strip()

    return cleaned


def answer_general_question(
    question: str,
    scene_context: str | None,
    llm_provider: str | None = None,
    llm_model: str | None = None,
) -> str:
    """Return a conversational answer for non-memory questions.

    Backwards-compatible wrapper. Internal callers that want provider info
    should use `answer_general_question_full` instead.
    """

    return answer_general_question_full(
        question, scene_context, llm_provider=llm_provider, llm_model=llm_model
    ).text


def answer_general_question_full(
    question: str,
    scene_context: str | None,
    llm_provider: str | None = None,
    llm_model: str | None = None,
) -> AssistantAnswer:
    """Like `answer_general_question` but also returns provider + model used."""

    answer = ask_llm_full(question, scene_context, llm_provider=llm_provider, llm_model=llm_model)
    if answer is not None:
        return answer

    fallback = (
        "The assistant is temporarily unavailable. Based on your scene, here is what I can share: "
        f"{scene_context}. Please try again in a moment."
    ) if scene_context else "The assistant is temporarily unavailable. Please try again in a moment."
    return AssistantAnswer(text=fallback, provider=None, model=None)


def ask_llm(
    question: str,
    scene_context: str | None,
    llm_provider: str | None = None,
    llm_model: str | None = None,
) -> str | None:
    """Ask the configured text model provider for a conversational answer."""

    answer = ask_llm_full(question, scene_context, llm_provider=llm_provider, llm_model=llm_model)
    return answer.text if answer is not None else None


def ask_llm_full(
    question: str,
    scene_context: str | None,
    llm_provider: str | None = None,
    llm_model: str | None = None,
) -> AssistantAnswer | None:
    """Same as `ask_llm` but returns the provider and model that produced the reply."""

    prompt = build_general_chat_prompt(question, scene_context)
    response = LLMProviderManager().generate(
        LLMRequest(
            prompt=prompt,
            provider=llm_provider,
            model=llm_model,
        )
    )
    if response is None:
        return None
    return AssistantAnswer(text=response.text, provider=response.provider, model=response.model)


def build_general_chat_prompt(question: str, scene_context: str | None) -> str:
    """Build the full prompt with the Watersheep professional persona."""

    scene_block = (
        f"\n\n[What the user is currently looking at through their glasses]:\n{scene_context}"
        if scene_context
        else ""
    )
    # No "Watersheep:" trailer — small models leak it into the reply text.
    return (
        f"{WATERSHEEP_SYSTEM_PROMPT}"
        f"{scene_block}"
        f"\n\nUser said: {question}\n"
        f"Reply in one or two short sentences."
    )


async def stream_chat_reply(
    prompt: str,
    llm_provider: str | None,
    llm_model: str | None,
) -> AsyncIterator[str]:
    """Yield reply tokens from the preferred provider for SSE streaming."""

    async for chunk in stream_reply(prompt, provider=llm_provider, model=llm_model):
        yield chunk


async def stream_chat_reply_with_meta(
    prompt: str,
    llm_provider: str | None,
    llm_model: str | None,
) -> AsyncIterator[dict]:
    """Yield typed events (provider + tokens) from the preferred provider."""

    async for event in stream_reply_with_meta(prompt, provider=llm_provider, model=llm_model):
        yield event


def _format_memory_line(summary: str, location: str | None) -> str:
    """Build a compact line describing a recalled memory."""

    if location:
        return f"You saw '{summary}' at {location}."
    return f"You saw '{summary}'."
