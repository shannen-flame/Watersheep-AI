"""Optional local embeddings for memory relevance and future ranking models."""

from __future__ import annotations

import logging
import math

import httpx

from ..utils.config import get_settings

logger = logging.getLogger(__name__)


def generate_embedding(text: str) -> list[float] | None:
    """Return an Ollama embedding when the local model is available."""

    cleaned = " ".join(text.split())
    if not cleaned:
        return None

    settings = get_settings()
    body = {
        "model": settings.ollama_text_model,
        "prompt": cleaned,
    }

    try:
        response = httpx.post(
            f"{settings.ollama_base_url}/api/embeddings",
            json=body,
            timeout=min(settings.ollama_timeout_seconds, 3),
        )
        response.raise_for_status()
        payload = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        logger.debug("Ollama embedding unavailable: %s", exc)
        return None

    embedding = payload.get("embedding")
    if not isinstance(embedding, list):
        return None

    try:
        return [float(value) for value in embedding]
    except (TypeError, ValueError):
        return None


def cosine_similarity(left: list[float] | None, right: list[float] | None) -> float:
    """Compute cosine similarity for same-length vectors."""

    if not left or not right or len(left) != len(right):
        return 0.0

    dot = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(value * value for value in left))
    right_norm = math.sqrt(sum(value * value for value in right))
    if left_norm == 0 or right_norm == 0:
        return 0.0
    return dot / (left_norm * right_norm)
