"""Explainable personalization derived from recorded interaction events."""

from __future__ import annotations

from collections import Counter
from typing import Any

from ..models.schemas import PersonalizationProfileResponse, PersonalizationSignal
from .event_service import count_events, list_events


ACTION_LABELS = {
    "what_am_i_looking_at": "What am I looking at?",
    "remember_this": "Remember this",
    "recall_memory": "Recall memory",
    "summarise_day": "Summarise my day",
}


def build_personalization_profile() -> PersonalizationProfileResponse:
    """Build a lightweight ML-style profile from usage frequencies and recency."""

    events = list_events(limit=500)
    action_counter: Counter[str] = Counter()
    source_counter: Counter[str] = Counter()
    message_counter: Counter[str] = Counter()

    for recency_index, event in enumerate(events):
        weight = max(1.0, 6.0 / (recency_index + 1))
        source_counter[event.source] += weight
        if event.event_type == "quick_action_used":
            action_id = _payload_string(event.payload, "action_id")
            if action_id:
                action_counter[action_id] += weight
        if event.event_type in {"assistant_message", "voice_command"}:
            bucket = _message_bucket(_payload_string(event.payload, "message"))
            if bucket:
                message_counter[bucket] += weight

    signals: list[PersonalizationSignal] = []
    signals.extend(_counter_signals("preferred_action", action_counter))
    signals.extend(_counter_signals("preferred_input_source", source_counter))
    signals.extend(_counter_signals("message_pattern", message_counter))

    suggested_actions = [
        ACTION_LABELS[action_id]
        for action_id, _score in action_counter.most_common(3)
        if action_id in ACTION_LABELS
    ]
    for fallback in ACTION_LABELS.values():
        if fallback not in suggested_actions:
            suggested_actions.append(fallback)
        if len(suggested_actions) >= 4:
            break

    preferred_response_style = "concise"
    if message_counter["planning"] > message_counter["visual_help"]:
        preferred_response_style = "structured"

    return PersonalizationProfileResponse(
        suggested_actions=suggested_actions,
        preferred_response_style=preferred_response_style,
        signals=signals[:12],
        event_count=count_events(),
    )


def _counter_signals(key: str, counter: Counter[str]) -> list[PersonalizationSignal]:
    return [
        PersonalizationSignal(
            signal_key=key,
            signal_value=value,
            score=round(float(score), 3),
            metadata={"method": "recency_weighted_frequency"},
        )
        for value, score in counter.most_common(5)
    ]


def _payload_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    return value.strip() if isinstance(value, str) else ""


def _message_bucket(message: str) -> str:
    normalized = message.lower()
    if any(term in normalized for term in ("see", "looking", "front of me", "read this")):
        return "visual_help"
    if any(term in normalized for term in ("plan", "next", "schedule", "focus", "lock in")):
        return "planning"
    if any(term in normalized for term in ("remember", "recall", "memory")):
        return "memory"
    if any(term in normalized for term in ("remind", "alarm", "wake me")):
        return "reminders"
    return "general_chat" if message else ""
