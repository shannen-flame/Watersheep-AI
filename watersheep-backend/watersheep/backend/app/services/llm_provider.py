"""Provider abstraction for local and future cloud LLM integrations."""

from __future__ import annotations

import asyncio
import json
import logging
import os
from collections.abc import AsyncIterator
from dataclasses import dataclass

import httpx
from google import genai

from ..utils.config import get_settings

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class LLMRequest:
    """Normalized LLM request."""

    prompt: str
    provider: str | None = None
    model: str | None = None
    timeout_seconds: int | None = None


@dataclass(frozen=True)
class LLMResponse:
    """Normalized LLM response."""

    text: str
    provider: str
    model: str


class LLMProvider:
    """Base provider protocol implemented with regular Python methods."""

    name: str

    def generate(self, payload: LLMRequest) -> LLMResponse | None:
        raise NotImplementedError


class OllamaProvider(LLMProvider):
    """Local Ollama text generation provider."""

    name = "ollama"

    def generate(self, payload: LLMRequest) -> LLMResponse | None:
        settings = get_settings()
        model = (payload.model or settings.ollama_text_model).strip()
        timeout_seconds = payload.timeout_seconds or settings.ollama_timeout_seconds
        body = {
            "model": model,
            "prompt": payload.prompt,
            "stream": False,
        }

        try:
            response = httpx.post(
                f"{settings.ollama_base_url}/api/generate",
                json=body,
                timeout=timeout_seconds,
            )
            response.raise_for_status()
            data = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            logger.warning("Ollama generation failed: %s", exc)
            return None

        text = _normalize_model_text(_extract_ollama_text(data))
        if not text:
            return None
        return LLMResponse(text=text, provider=self.name, model=model)


class GeminiProvider(LLMProvider):
    """Gemini provider kept modular for cloud fallback."""

    name = "gemini"

    def generate(self, payload: LLMRequest) -> LLMResponse | None:
        api_key = os.getenv("GEMINI_API_KEY")
        if not api_key:
            return None

        model = _resolve_gemini_model(payload.model)
        try:
            client = genai.Client(api_key=api_key)
            response = client.models.generate_content(
                model=model,
                contents=payload.prompt,
            )
        except Exception as exc:
            logger.warning("Gemini generation failed: %s", exc)
            return None

        text = _normalize_model_text(_extract_gemini_text(response))
        if not text:
            return None
        return LLMResponse(text=text, provider=self.name, model=model)


class OpenRouterProvider(LLMProvider):
    """OpenRouter cloud fallback. Speaks the OpenAI chat-completions wire format
    so it works with any model the user picks via OPENROUTER_MODEL.
    """

    name = "openrouter"

    def generate(self, payload: LLMRequest) -> LLMResponse | None:
        api_key = os.getenv("OPENROUTER_API_KEY")
        if not api_key:
            return None

        model = (payload.model or os.getenv("OPENROUTER_MODEL", "openai/gpt-4o-mini")).strip()
        timeout_seconds = payload.timeout_seconds or 30
        body = {
            "model": model,
            "messages": [{"role": "user", "content": payload.prompt}],
            "stream": False,
        }
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            # OpenRouter requires these for free-tier rate limits + analytics.
            "HTTP-Referer": os.getenv("OPENROUTER_REFERER", "https://watersheep.local"),
            "X-Title": "Watersheep",
        }

        try:
            response = httpx.post(
                "https://openrouter.ai/api/v1/chat/completions",
                json=body,
                headers=headers,
                timeout=timeout_seconds,
            )
            response.raise_for_status()
            data = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            logger.warning("OpenRouter generation failed: %s", exc)
            return None

        text = _normalize_model_text(_extract_ollama_text(data))
        if not text:
            return None
        return LLMResponse(text=text, provider=self.name, model=model)


class LLMProviderManager:
    """Provider router with a deterministic fallback order."""

    def __init__(self) -> None:
        self.providers: dict[str, LLMProvider] = {
            "ollama": OllamaProvider(),
            "gemini": GeminiProvider(),
            "openrouter": OpenRouterProvider(),
        }

    def generate(self, payload: LLMRequest) -> LLMResponse | None:
        settings = get_settings()
        preferred = (payload.provider or settings.llm_provider).strip().lower()
        fallback_order = [preferred]
        # Cascade through every other provider after the preferred one. With an
        # OPENROUTER_API_KEY set, you'll never see a quota wall again.
        for provider_name in ("ollama", "gemini", "openrouter"):
            if provider_name not in fallback_order:
                fallback_order.append(provider_name)

        for provider_name in fallback_order:
            provider = self.providers.get(provider_name)
            if provider is None:
                continue
            response = provider.generate(payload)
            if response is not None:
                return response
        return None


async def stream_ollama(
    prompt: str,
    model: str | None = None,
    timeout_seconds: int | None = None,
) -> AsyncIterator[str]:
    """Yield response chunks from Ollama's /api/generate stream."""

    settings = get_settings()
    resolved_model = (model or settings.ollama_text_model).strip()
    timeout = timeout_seconds or settings.ollama_timeout_seconds
    body = {
        "model": resolved_model,
        "prompt": prompt,
        "stream": True,
    }

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            async with client.stream(
                "POST",
                f"{settings.ollama_base_url}/api/generate",
                json=body,
            ) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if not line:
                        continue
                    try:
                        chunk = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    text = chunk.get("response")
                    if isinstance(text, str) and text:
                        yield text
                    if chunk.get("done"):
                        break
    except httpx.HTTPError as exc:
        logger.warning("Ollama streaming failed: %s", exc)
        return


async def stream_gemini(prompt: str, model: str | None = None) -> AsyncIterator[str]:
    """Yield response chunks from Gemini using its async streaming API."""

    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        return

    resolved_model = _resolve_gemini_model(model)
    try:
        client = genai.Client(api_key=api_key)
        stream = await asyncio.to_thread(
            client.models.generate_content_stream,
            model=resolved_model,
            contents=prompt,
        )
    except Exception as exc:
        logger.warning("Gemini streaming setup failed: %s", exc)
        return

    try:
        for chunk in stream:
            text = getattr(chunk, "text", "")
            if isinstance(text, str) and text:
                yield text
                # Yield control so the SSE writer can flush.
                await asyncio.sleep(0)
    except Exception as exc:
        logger.warning("Gemini streaming iteration failed: %s", exc)


async def stream_openrouter(prompt: str, model: str | None = None) -> AsyncIterator[str]:
    """Yield response chunks from the OpenRouter SSE stream."""

    api_key = os.getenv("OPENROUTER_API_KEY")
    if not api_key:
        return

    resolved_model = (model or os.getenv("OPENROUTER_MODEL", "openai/gpt-4o-mini")).strip()
    body = {
        "model": resolved_model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "HTTP-Referer": os.getenv("OPENROUTER_REFERER", "https://watersheep.local"),
        "X-Title": "Watersheep",
    }

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            async with client.stream(
                "POST",
                "https://openrouter.ai/api/v1/chat/completions",
                json=body,
                headers=headers,
            ) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if not line or not line.startswith("data:"):
                        continue
                    payload_str = line[len("data:"):].strip()
                    if payload_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(payload_str)
                    except json.JSONDecodeError:
                        continue
                    choices = chunk.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    content = delta.get("content")
                    if isinstance(content, str) and content:
                        yield content
    except httpx.HTTPError as exc:
        logger.warning("OpenRouter streaming failed: %s", exc)


async def stream_reply(
    prompt: str,
    provider: str | None = None,
    model: str | None = None,
) -> AsyncIterator[str]:
    """Stream from the preferred provider, falling back to a one-shot reply."""

    async for event in stream_reply_with_meta(prompt, provider=provider, model=model):
        if event.get("type") == "token":
            yield event["text"]


async def stream_reply_with_meta(
    prompt: str,
    provider: str | None = None,
    model: str | None = None,
) -> AsyncIterator[dict]:
    """Stream tokens with structured metadata events.

    Yields events of one of three shapes:
      {"type": "provider", "name": "ollama", "model": "llama3.2:3b"}
      {"type": "token", "text": "...one chunk..."}
      {"type": "fallback", "name": "..."}        # emitted on switch to non-stream
    """

    settings = get_settings()
    preferred = (provider or settings.llm_provider).strip().lower()
    order = [preferred] + [
        name for name in ("ollama", "gemini", "openrouter") if name != preferred
    ]

    for name in order:
        produced_any = False
        emitted_provider = False
        resolved_model = _resolved_model_name(name, model)

        producer: AsyncIterator[str] | None = None
        if name == "ollama":
            producer = stream_ollama(prompt, model=model)
        elif name == "gemini":
            producer = stream_gemini(prompt, model=model)
        elif name == "openrouter":
            producer = stream_openrouter(prompt, model=model)

        if producer is None:
            continue

        async for chunk in producer:
            if not produced_any:
                produced_any = True
            if not emitted_provider:
                emitted_provider = True
                yield {"type": "provider", "name": name, "model": resolved_model}
            yield {"type": "token", "text": chunk}

        if produced_any:
            return

    # All streamers came up empty — fall back to a one-shot non-streaming call.
    fallback = LLMProviderManager().generate(
        LLMRequest(prompt=prompt, provider=provider, model=model)
    )
    if fallback is not None and fallback.text:
        yield {"type": "provider", "name": fallback.provider, "model": fallback.model}
        yield {"type": "fallback", "name": fallback.provider}
        yield {"type": "token", "text": fallback.text}


def _resolved_model_name(provider_name: str, model: str | None) -> str:
    """Best-effort name resolution for diagnostics. Mirrors each provider's defaults."""

    if provider_name == "ollama":
        return (model or get_settings().ollama_text_model).strip()
    if provider_name == "gemini":
        return _resolve_gemini_model(model)
    if provider_name == "openrouter":
        return (model or os.getenv("OPENROUTER_MODEL", "openai/gpt-4o-mini")).strip()
    return model or "unknown"


def _resolve_gemini_model(preferred_model: str | None = None) -> str:
    candidate = (preferred_model or "").strip()
    if candidate.lower().startswith("gemini"):
        return candidate
    return os.getenv("GEMINI_TEXT_MODEL", "gemini-2.0-flash").strip()


def _extract_ollama_text(data: object) -> str:
    """Pull a text reply out of either the /api/generate or /api/chat response shape."""

    if not isinstance(data, dict):
        return ""

    direct_response = data.get("response")
    if isinstance(direct_response, str) and direct_response.strip():
        return direct_response

    message = data.get("message")
    if isinstance(message, dict):
        content = message.get("content")
        if isinstance(content, str) and content.strip():
            return content

    choices = data.get("choices")
    if isinstance(choices, list) and choices:
        first = choices[0]
        if isinstance(first, dict):
            choice_message = first.get("message")
            if isinstance(choice_message, dict):
                content = choice_message.get("content")
                if isinstance(content, str) and content.strip():
                    return content
            text = first.get("text")
            if isinstance(text, str) and text.strip():
                return text

    return ""


def _extract_gemini_text(response: object) -> str:
    """Pull text from the Gemini SDK response, falling back to candidate parts."""

    direct = getattr(response, "text", "") or ""
    if isinstance(direct, str) and direct.strip():
        return direct

    candidates = getattr(response, "candidates", None) or []
    for candidate in candidates:
        content = getattr(candidate, "content", None)
        parts = getattr(content, "parts", None) or []
        for part in parts:
            text = getattr(part, "text", "") or ""
            if isinstance(text, str) and text.strip():
                return text
    return ""


def _normalize_model_text(value: object) -> str:
    text = str(value).strip()
    if not text:
        return ""

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = None

    if isinstance(parsed, str):
        return parsed.strip()
    if isinstance(parsed, dict):
        for key in ("assistant_message", "reply", "answer", "message", "text", "content"):
            candidate = parsed.get(key)
            if isinstance(candidate, str) and candidate.strip():
                return candidate.strip()

    if len(text) >= 2 and text[0] == text[-1] and text[0] in {"'", '"'}:
        return text[1:-1].strip()
    return text
