"""Compatibility service for the legacy /message endpoint - all intents hit the LLM."""

from __future__ import annotations

import logging
import re

from ..models.schemas import MessageRequest, MessageResponse
from .internet_service import answer_live_data_question

logger = logging.getLogger(__name__)


INTENT_KEYWORDS = {
    "weather_query": (
        "what's the weather",
        "what is the weather",
        "weather today",
        "weather like",
    ),
    "start_lock_in": (
        "start lock in mode",
        "start lock-in mode",
        "lock in",
        "focus mode",
        "deep work",
        "start focusing",
    ),
    "stop_lock_in": (
        "stop lock in mode",
        "stop lock-in mode",
        "stop focusing",
        "end focus mode",
        "stop lock in",
    ),
    "schedule_question": (
        "what should i do next",
        "what next",
        "what should i work on",
        "what should i do now",
        "help me plan",
        "what's my schedule today",
        "whats my schedule today",
        "schedule today",
    ),
    "motivate_user": (
        "motivate me",
        "give me motivation",
        "encourage me",
        "pep talk",
        "i need motivation",
        "hype me up",
    ),
    "reminder": ("remind me", "set a reminder", "remember to"),
    "alarm": ("set an alarm", "wake me at", "set a timer"),
}

# Fallback replies used only when the LLM call fails. Kept short and professional.
_FALLBACK_REPLIES = {
    "weather_query": "Weather isn't wired up yet — try something else.",
    "start_lock_in": "Focus mode on. I'll keep it quiet.",
    "stop_lock_in": "Done. Take a breather.",
    "motivate_user": "You've got this. Pick one thing and start.",
    "schedule_question": "Top of your list — start there.",
    "reminder": "Got it.",
    "alarm": "Alarm set.",
    "general_chat": "I'm here — what's up?",
}


def process_message(payload: MessageRequest) -> MessageResponse:
    """Handle voice commands; routes everything through the LLM for real answers."""

    message = payload.message.strip()
    intent = detect_intent(message)

    live_answer = answer_live_data_question(message)
    if live_answer is not None:
        return MessageResponse(
            intent=intent,
            reply=live_answer.text,
            action_result={
                "status": "success",
                "tool": live_answer.model,
                "provider": live_answer.provider,
            },
        )

    if intent == "start_lock_in":
        duration = extract_duration_minutes(message) or 45
        llm_reply = _llm_reply(
            f"The user just started a {duration}-minute focus session. "
            "Reply with one or two short, professional, encouraging sentences acknowledging the start of the session."
        )
        return MessageResponse(
            intent=intent,
            reply=llm_reply or f"Focus mode is on for {duration} minutes. Stay with the task.",
            action_result={
                "status": "success",
                "tool": "start_lock_in",
                "duration_minutes": duration,
            },
        )

    if intent == "stop_lock_in":
        llm_reply = _llm_reply(
            "The user just ended their focus session. "
            "Reply with one or two short, professional sentences that wrap up the session."
        )
        return MessageResponse(
            intent=intent,
            reply=llm_reply or _FALLBACK_REPLIES[intent],
        )

    if intent == "motivate_user":
        llm_reply = _llm_reply(
            f"The user said: '{message}'. They want a short motivational reply. "
            "Respond with two to three professional, sincere sentences. No slang."
        )
        return MessageResponse(
            intent=intent,
            reply=llm_reply or _FALLBACK_REPLIES[intent],
        )

    llm_reply = _llm_reply(message)
    return MessageResponse(
        intent=intent,
        reply=llm_reply or _FALLBACK_REPLIES.get(intent, _FALLBACK_REPLIES["general_chat"]),
    )


def _llm_reply(message: str, scene_context: str | None = None) -> str | None:
    """Call the LLM with the Watersheep persona and return the reply."""
    try:
        from .assistant_service import answer_general_question
        return answer_general_question(message, scene_context=scene_context)
    except Exception as exc:
        logger.warning("LLM call failed in process_message: %s", exc)
        return None


def detect_intent(message: str) -> str:
    """Map a message to one of the supported local intents."""

    normalized = message.strip().lower()
    for intent, keywords in INTENT_KEYWORDS.items():
        if any(keyword in normalized for keyword in keywords):
            return intent
    return "general_chat"


def extract_duration_minutes(message: str) -> int | None:
    """Extract a focus duration from a focus command."""

    match = re.search(r"(\d{1,3})\s*(minute|minutes|min)", message.lower())
    return int(match.group(1)) if match else None
