"""Provider fallback behavior for image analysis."""

from PIL import Image

from app.models.schemas import VisionProxyResponse
from app.services import vision_service
from app.utils.config import get_settings


def test_gemini_fallback_uses_openrouter_before_ollama(monkeypatch):
    """OpenRouter should be the first fallback after Gemini."""

    monkeypatch.setenv("WATERSHEEP_ENABLE_OLLAMA_VISION_FALLBACK", "false")
    get_settings.cache_clear()

    def fake_openrouter(**_kwargs):
        return VisionProxyResponse(
            assistant_message="A small object is visible on a desk.",
            vision_summary="Objects: small object, desk.",
            vision_provider="openrouter",
            fallback_reason="gemini_quota_exceeded",
            local_summary="Objects: none detected. OCR: none.",
        )

    def fail_if_ollama_called(**_kwargs):
        raise AssertionError("Ollama should not run before OpenRouter.")

    monkeypatch.setattr(vision_service, "analyze_with_openrouter_vision", fake_openrouter)
    monkeypatch.setattr(vision_service, "analyze_with_ollama_vision_only", fail_if_ollama_called)

    response = vision_service.analyze_image_fallbacks_after_gemini_failure(
        image=Image.new("RGB", (8, 8), color="white"),
        prompt="What am I looking at?",
        scene_summary=None,
        model=None,
        fallback_reason="gemini_quota_exceeded",
        local_summary="Objects: none detected. OCR: none.",
    )

    assert response.vision_provider == "openrouter"


def test_disabled_ollama_fallback_returns_local_summary(monkeypatch):
    """When cloud fallbacks fail, disabled Ollama should not invent a scene."""

    monkeypatch.setenv("WATERSHEEP_ENABLE_OLLAMA_VISION_FALLBACK", "false")
    get_settings.cache_clear()

    def fake_openrouter_failure(**_kwargs):
        raise RuntimeError("openrouter unavailable")

    def fail_if_ollama_called(**_kwargs):
        raise AssertionError("Ollama vision fallback is disabled.")

    monkeypatch.setattr(vision_service, "analyze_with_openrouter_vision", fake_openrouter_failure)
    monkeypatch.setattr(vision_service, "analyze_with_ollama_vision_only", fail_if_ollama_called)

    response = vision_service.analyze_image_fallbacks_after_gemini_failure(
        image=Image.new("RGB", (8, 8), color="white"),
        prompt="What am I looking at?",
        scene_summary=None,
        model=None,
        fallback_reason="gemini_quota_exceeded",
        local_summary="Objects: none detected. OCR: none.",
    )

    assert response.vision_provider == "local_summary"
    assert response.fallback_reason == "gemini_quota_exceeded_openrouter_failed_ollama_disabled"
    assert "can't confidently tell" in response.assistant_message
