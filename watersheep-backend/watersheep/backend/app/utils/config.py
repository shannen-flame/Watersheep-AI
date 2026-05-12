"""Environment-backed settings for the Watersheep backend."""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv
from pydantic import BaseModel


BACKEND_ROOT = Path(__file__).resolve().parents[2]
load_dotenv(BACKEND_ROOT / ".env")


class Settings(BaseModel):
    """Runtime settings loaded from environment variables."""

    app_name: str = "Watersheep Backend"
    environment: str = "development"
    host: str = "0.0.0.0"
    port: int = 8000
    database_path: Path = BACKEND_ROOT / "watersheep.db"
    uploads_path: Path = BACKEND_ROOT / "uploads"
    cors_origins: list[str] = ["*"]
    llm_provider: str = "gemini"
    llm_model: str = "gemini-2.0-flash"
    default_city: str = ""
    enable_web_search: bool = True
    search_provider: str = "auto"
    search_max_results: int = 5
    search_fetch_pages: bool = False
    search_use_llm_summary: bool = False
    ollama_text_model: str = "llama3.2:3b"
    ollama_base_url: str = "http://127.0.0.1:11434"
    ollama_vision_model: str = "gemma3"
    ollama_timeout_seconds: int = 60
    enable_ollama_vision_fallback: bool = False
    debug_endpoints_enabled: bool = True


@lru_cache
def get_settings() -> Settings:
    """Return cached settings loaded from environment variables."""

    environment = _env_str("WATERSHEEP_ENV", "development").lower()

    raw_origins = os.getenv("WATERSHEEP_CORS_ORIGINS")
    if raw_origins is None:
        # In development we keep CORS open so the iPhone or simulator can reach
        # the backend without extra configuration. In production we require the
        # operator to explicitly set the allowed origins.
        if environment == "development":
            origins = ["*"]
        else:
            origins = []
    else:
        origins = [origin.strip() for origin in raw_origins.split(",") if origin.strip()]
        if not origins:
            origins = ["*"] if environment == "development" else []

    debug_endpoints_enabled = _env_bool(
        "WATERSHEEP_DEBUG_ENDPOINTS",
        default=environment == "development",
    )

    return Settings(
        app_name=os.getenv("WATERSHEEP_APP_NAME", "Watersheep Backend"),
        environment=environment,
        host=os.getenv("WATERSHEEP_HOST", "0.0.0.0"),
        port=_env_int("WATERSHEEP_PORT", 8000, minimum=1, maximum=65535),
        database_path=Path(
            os.getenv("WATERSHEEP_DB_PATH", str(BACKEND_ROOT / "watersheep.db"))
        ),
        uploads_path=Path(
            os.getenv("WATERSHEEP_UPLOADS_PATH", str(BACKEND_ROOT / "uploads"))
        ),
        cors_origins=origins,
        llm_provider=_env_str("WATERSHEEP_LLM_PROVIDER", "gemini").lower(),
        llm_model=_env_str("WATERSHEEP_LLM_MODEL", "gemini-2.0-flash"),
        default_city=_env_str("WATERSHEEP_DEFAULT_CITY", ""),
        enable_web_search=_env_bool("WATERSHEEP_ENABLE_WEB_SEARCH", default=True),
        search_provider=_env_str("WATERSHEEP_SEARCH_PROVIDER", "auto").lower(),
        search_max_results=_env_int("WATERSHEEP_SEARCH_MAX_RESULTS", 5, minimum=1, maximum=8),
        search_fetch_pages=_env_bool("WATERSHEEP_SEARCH_FETCH_PAGES", default=False),
        search_use_llm_summary=_env_bool("WATERSHEEP_SEARCH_USE_LLM_SUMMARY", default=False),
        ollama_text_model=_env_str("OLLAMA_TEXT_MODEL", "llama3.2:3b"),
        ollama_base_url=_env_str("OLLAMA_BASE_URL", "http://127.0.0.1:11434").rstrip("/"),
        ollama_vision_model=_env_str("OLLAMA_VISION_MODEL", "gemma3"),
        ollama_timeout_seconds=_env_int("OLLAMA_TIMEOUT_SECONDS", 60, minimum=1),
        enable_ollama_vision_fallback=_env_bool(
            "WATERSHEEP_ENABLE_OLLAMA_VISION_FALLBACK",
            default=False,
        ),
        debug_endpoints_enabled=debug_endpoints_enabled,
    )


def _env_str(name: str, default: str) -> str:
    """Read a stripped string environment variable with a non-empty default."""

    value = os.getenv(name, default).strip()
    return value or default


def _env_int(
    name: str,
    default: int,
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    """Read an integer environment variable without letting bad config crash startup."""

    raw_value = os.getenv(name)
    if raw_value is None:
        value = default
    else:
        try:
            value = int(raw_value)
        except ValueError:
            value = default

    if minimum is not None:
        value = max(minimum, value)
    if maximum is not None:
        value = min(maximum, value)
    return value


def _env_bool(name: str, *, default: bool) -> bool:
    """Read a truthy/falsy environment variable."""

    raw_value = os.getenv(name)
    if raw_value is None:
        return default
    return raw_value.strip().lower() in {"1", "true", "yes", "on"}
