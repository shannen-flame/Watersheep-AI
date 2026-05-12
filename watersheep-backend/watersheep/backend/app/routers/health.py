"""Health and runtime information endpoints."""

from __future__ import annotations

import logging
import os
import time

import httpx

from fastapi import APIRouter

from ..models.schemas import (
    DiagnosticsResponse,
    HealthResponse,
    ProviderHealth,
)
from ..services.storage import get_connection
from ..utils.config import get_settings

logger = logging.getLogger(__name__)

router = APIRouter(tags=["health"])


@router.get("/")
def root() -> dict[str, str]:
    """Return a simple root response for browser and phone checks."""

    return {
        "status": "ok",
        "message": "Watersheep backend is running",
    }


@router.get("/health", response_model=HealthResponse)
@router.get("/api/health", response_model=HealthResponse)
def health_check() -> HealthResponse:
    """Return a lightweight health response for app startup checks."""

    settings = get_settings()
    return HealthResponse(
        status="ok",
        app_name=settings.app_name,
        environment=settings.environment,
    )


@router.get("/api/diagnostics", response_model=DiagnosticsResponse)
def diagnostics() -> DiagnosticsResponse:
    """Return deeper diagnostics for the iOS Settings screen and demo day."""

    settings = get_settings()
    return DiagnosticsResponse(
        status="ok",
        app_name=settings.app_name,
        environment=settings.environment,
        ollama=_check_ollama(
            settings.ollama_base_url,
            settings.ollama_text_model,
            settings.enable_ollama_vision_fallback,
        ),
        gemini=_check_gemini(),
        openrouter=_check_openrouter(),
        database=_check_database(),
        cors_origins=settings.cors_origins,
        debug_endpoints_enabled=settings.debug_endpoints_enabled,
    )


def _check_ollama(
    base_url: str,
    expected_model: str,
    vision_fallback_enabled: bool,
) -> ProviderHealth:
    started = time.perf_counter()
    vision_mode = (
        "Ollama vision fallback is enabled."
        if vision_fallback_enabled
        else "Ollama vision fallback is disabled for image analysis."
    )
    try:
        response = httpx.get(f"{base_url}/api/tags", timeout=2.5)
        response.raise_for_status()
        data = response.json()
    except Exception as exc:
        return ProviderHealth(
            available=False,
            detail=f"Ollama unreachable at {base_url}: {exc}. {vision_mode}",
            latency_ms=int((time.perf_counter() - started) * 1000),
        )

    models = []
    raw_models = data.get("models")
    if isinstance(raw_models, list):
        for entry in raw_models:
            if isinstance(entry, dict) and entry.get("name"):
                models.append(str(entry["name"]))

    has_expected = any(model.split(":")[0] == expected_model.split(":")[0] for model in models)
    detail = (
        f"Ollama is up. Models: {', '.join(models) or 'none'}."
        + ("" if has_expected else f" Missing expected model '{expected_model}'.")
        + f" {vision_mode}"
    )
    return ProviderHealth(
        available=True,
        detail=detail,
        latency_ms=int((time.perf_counter() - started) * 1000),
        models=models,
        expected_model=expected_model,
        expected_model_available=has_expected,
    )


def _check_gemini() -> ProviderHealth:
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        return ProviderHealth(
            available=False,
            detail="GEMINI_API_KEY is not set.",
        )

    masked = api_key[:4] + "..." + api_key[-4:] if len(api_key) > 8 else "set"
    return ProviderHealth(
        available=True,
        detail=f"GEMINI_API_KEY configured ({masked}).",
    )


def _check_openrouter() -> ProviderHealth:
    api_key = os.getenv("OPENROUTER_API_KEY")
    if not api_key:
        return ProviderHealth(
            available=False,
            detail="OPENROUTER_API_KEY is not set. (Optional 3rd-tier fallback.)",
        )

    model = os.getenv("OPENROUTER_MODEL", "openai/gpt-4o-mini")
    vision_model = os.getenv("OPENROUTER_VISION_MODEL", model)
    masked = api_key[:6] + "..." + api_key[-4:] if len(api_key) > 10 else "set"
    return ProviderHealth(
        available=True,
        detail=f"OPENROUTER_API_KEY configured ({masked}). Text model: {model}. Vision fallback model: {vision_model}.",
    )


def _check_database() -> ProviderHealth:
    started = time.perf_counter()
    try:
        with get_connection() as connection:
            row = connection.execute("SELECT COUNT(*) AS count FROM memories").fetchone()
            count = int(row["count"]) if row else 0
        return ProviderHealth(
            available=True,
            detail=f"SQLite OK. Saved memories: {count}.",
            latency_ms=int((time.perf_counter() - started) * 1000),
        )
    except Exception as exc:
        return ProviderHealth(
            available=False,
            detail=f"SQLite check failed: {exc}",
            latency_ms=int((time.perf_counter() - started) * 1000),
        )
