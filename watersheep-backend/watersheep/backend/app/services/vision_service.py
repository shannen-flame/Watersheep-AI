"""Vision upload storage and provider-aware image analysis."""

from __future__ import annotations

import base64
import binascii
import json
import logging
import os
import time
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path
from uuid import uuid4

import httpx
from fastapi import HTTPException, UploadFile
from google import genai
from google.genai import errors as genai_errors
from google.genai import types
from PIL import Image

from ..models.schemas import (
    FrameAnalysisRequest,
    FrameAnalysisResponse,
    VisionAnalysisResponse,
    VisionProxyRequest,
    VisionProxyResponse,
)
from ..utils.config import get_settings
from ..utils.errors import AppError

logger = logging.getLogger(__name__)

VISION_MODEL = os.getenv("GEMINI_VISION_MODEL", "gemini-2.0-flash")

ALLOWED_FRAME_CONTENT_TYPES = {"image/jpeg", "image/jpg", "image/png", "image/webp"}

MAX_IMAGE_BYTES = int(os.getenv("WATERSHEEP_MAX_IMAGE_BYTES", str(8 * 1024 * 1024)))
MAX_IMAGE_PIXELS = int(os.getenv("WATERSHEEP_MAX_IMAGE_PIXELS", str(24_000_000)))
MAX_IMAGE_DIMENSION = int(os.getenv("WATERSHEEP_MAX_IMAGE_DIMENSION", "8192"))

FRAME_ANALYSIS_PROMPT = (
    "Describe what is visible in this image so an AI assistant can help "
    "the user understand their surroundings. Reply in 1 to 2 short sentences."
)
DEFAULT_VISION_PROXY_PROMPT = (
    "You are a vision assistant for a wearable iOS app. "
    "Look at the image and produce JSON with exactly these keys: "
    "`assistant_message` and `vision_summary`. "
    "`assistant_message` should be one clear sentence telling the user what they are looking at. "
    "`vision_summary` should briefly summarize visible objects and useful text. "
    "Do not guess; if the image is unclear or the object cannot be identified, say you cannot tell."
)
DEFAULT_GEMINI_VISION_PROXY_PROMPT = (
    "You are a vision assistant for a wearable iOS app. "
    "Describe what the user is looking at in one clear sentence, then add a short summary of visible objects "
    "and useful text. Do not guess; if the image is unclear or the object cannot be identified, say you "
    "cannot tell. Return JSON with exactly these keys: `assistant_message` and `vision_summary`."
)
VISION_COOLDOWN_UNTIL = 0.0
DEFAULT_VISION_COOLDOWN_SECONDS = int(os.getenv("VISION_COOLDOWN_SECONDS", "60"))


def analyze_uploaded_image(file: UploadFile) -> VisionAnalysisResponse:
    """Save an uploaded image and return a placeholder structured analysis."""

    file_bytes = file.file.read()
    image = validate_image_upload(file.content_type, file_bytes)
    saved_path = save_image_bytes(file.filename, file_bytes)
    return build_placeholder_analysis(saved_path, image)


def analyze_base64_frame(payload: FrameAnalysisRequest) -> FrameAnalysisResponse:
    """Decode a base64 frame and return a short scene description."""

    model_used = VISION_MODEL
    encoded_image = payload.image or payload.frame
    if not encoded_image:
        return FrameAnalysisResponse(
            success=False,
            scene="Unable to decode image.",
            suggestion="",
            error="unable_to_decode_image",
            message="Unable to decode image.",
            retry_after_seconds=0,
        )

    try:
        image_bytes = decode_base64_image(encoded_image)
        validate_image_upload(content_type=None, file_bytes=image_bytes)
    except HTTPException as exc:
        return FrameAnalysisResponse(
            success=False,
            scene="Unable to decode image.",
            suggestion="",
            error="invalid_image",
            message=str(exc.detail),
            retry_after_seconds=0,
        )
    except Exception as exc:
        logger.exception("Image decoding failed: %s", exc)
        return FrameAnalysisResponse(
            success=False,
            scene="Unable to decode image.",
            suggestion="",
            error="unable_to_decode_image",
            message="Unable to decode image.",
            retry_after_seconds=0,
        )

    try:
        scene = describe_frame_with_gemini(image_bytes, model_used=model_used)
    except Exception as exc:
        logger.exception("Vision model failed: %s", exc)
        scene = "Unable to analyze the scene."

    error_message = "" if scene != "Unable to analyze the scene." else "Unable to analyze the scene."
    return FrameAnalysisResponse(
        success=not bool(error_message),
        scene=scene,
        suggestion="",
        error="vision_analysis_failed" if error_message else "",
        message=error_message,
        retry_after_seconds=0,
    )


async def analyze_uploaded_frame(file: UploadFile | None) -> FrameAnalysisResponse:
    """Analyze a multipart-uploaded image frame safely for the legacy endpoint."""

    if file is None:
        return FrameAnalysisResponse(
            success=False,
            scene="",
            suggestion="",
            error="missing_image_upload",
            message="missing image upload",
            retry_after_seconds=0,
        )

    if file.content_type not in ALLOWED_FRAME_CONTENT_TYPES:
        return FrameAnalysisResponse(
            success=False,
            scene="",
            suggestion="",
            error="unsupported_image_content_type",
            message="unsupported image content type",
            retry_after_seconds=0,
        )

    try:
        contents = await file.read()
    except Exception as exc:
        logger.exception("Failed reading uploaded file: %s", exc)
        return FrameAnalysisResponse(
            success=False,
            scene="",
            suggestion="",
            error="failed_to_read_uploaded_image",
            message="failed to read uploaded image",
            retry_after_seconds=0,
        )

    if not contents:
        return FrameAnalysisResponse(
            success=False,
            scene="",
            suggestion="",
            error="missing_image_upload",
            message="missing image upload",
            retry_after_seconds=0,
        )

    try:
        validate_image_upload(content_type=file.content_type, file_bytes=contents)
        cooldown_response = get_vision_cooldown_response()
        if cooldown_response is not None:
            response = analyze_image_fallbacks_after_gemini_failure(
                image=validate_image_upload(content_type=file.content_type, file_bytes=contents),
                prompt=FRAME_ANALYSIS_PROMPT,
                scene_summary=None,
                model=None,
                fallback_reason="gemini_cooldown",
                local_summary="Gemini vision is cooling down from a recent quota error.",
            )
            return FrameAnalysisResponse(
                success=True,
                scene=response.assistant_message,
                suggestion="",
                error="",
                message="",
                retry_after_seconds=0,
                vision_provider=response.vision_provider,
                fallback_reason=response.fallback_reason,
                local_summary=response.local_summary,
            )

        scene = describe_frame_with_gemini(contents, model_used=VISION_MODEL)
        clear_vision_cooldown()
        return FrameAnalysisResponse(
            success=True,
            scene=scene,
            suggestion="",
            error="",
            message="",
            retry_after_seconds=0,
            vision_provider="gemini",
            fallback_reason=None,
            local_summary=None,
        )
    except HTTPException as exc:
        return FrameAnalysisResponse(
            success=False,
            scene="",
            suggestion="",
            error="invalid_image",
            message=str(exc.detail),
            retry_after_seconds=0,
        )
    except genai_errors.ClientError as exc:
        if is_quota_error(exc):
            retry_after = apply_vision_cooldown(exc)
            log_quota_failure(retry_after)
            try:
                image = validate_image_upload(content_type=file.content_type, file_bytes=contents)
                local_summary = build_local_vision_summary(image=image, scene_summary=None)
                response = analyze_image_fallbacks_after_gemini_failure(
                    image=image,
                    prompt=FRAME_ANALYSIS_PROMPT,
                    scene_summary=None,
                    model=None,
                    fallback_reason="gemini_quota_exceeded",
                    local_summary=local_summary,
                )
                return FrameAnalysisResponse(
                    success=True,
                    scene=response.assistant_message,
                    suggestion="",
                    error="",
                    message="",
                    retry_after_seconds=0,
                    vision_provider=response.vision_provider,
                    fallback_reason=response.fallback_reason,
                    local_summary=response.local_summary,
                )
            except Exception as fallback_exc:
                logger.exception("analyze-frame fallback failed: %s", fallback_exc)
                return FrameAnalysisResponse(
                    success=False,
                    scene="Vision temporarily unavailable",
                    suggestion="Please try again in a moment",
                    error="vision_quota_exceeded",
                    message="Gemini vision quota exceeded. Please wait and try again later.",
                    retry_after_seconds=retry_after,
                    vision_provider="gemini",
                    fallback_reason="gemini_quota_exceeded",
                    local_summary=None,
                )
        logger.exception("analyze-frame processing failed: %s", exc)
        try:
            image = validate_image_upload(content_type=file.content_type, file_bytes=contents)
            local_summary = build_local_vision_summary(image=image, scene_summary=None)
            response = analyze_image_fallbacks_after_gemini_failure(
                image=image,
                prompt=FRAME_ANALYSIS_PROMPT,
                scene_summary=None,
                model=None,
                fallback_reason=classify_gemini_fallback_reason(exc),
                local_summary=local_summary,
            )
            return FrameAnalysisResponse(
                success=True,
                scene=response.assistant_message,
                suggestion="",
                error="",
                message="",
                retry_after_seconds=0,
                vision_provider=response.vision_provider,
                fallback_reason=response.fallback_reason,
                local_summary=response.local_summary,
            )
        except Exception as fallback_exc:
            logger.exception("analyze-frame fallback failed: %s", fallback_exc)
            return FrameAnalysisResponse(
                success=False,
                scene="",
                suggestion="",
                error="vision_model_error",
                message="Unable to analyze the scene.",
                retry_after_seconds=0,
                vision_provider="gemini",
                fallback_reason=classify_gemini_fallback_reason(exc),
                local_summary=None,
            )
    except Exception as exc:
        logger.exception("analyze-frame processing failed: %s", exc)
        return FrameAnalysisResponse(
            success=False,
            scene="",
            suggestion="",
            error="vision_analysis_failed",
            message="Unable to analyze the scene.",
            retry_after_seconds=0,
        )


def analyze_image_with_provider_fallback(
    image_bytes: bytes,
    prompt: str | None = None,
    scene_summary: str | None = None,
    model: str | None = None,
) -> VisionProxyResponse:
    """Analyze an image with Gemini first, then safer fallback providers."""

    settings = get_settings()
    image = validate_image_upload(content_type=None, file_bytes=image_bytes)
    local_summary = build_local_vision_summary(image=image, scene_summary=scene_summary)
    logger.info(
        "Starting image analysis request: primary=gemini fallback=openrouter optional_ollama=%s image_bytes=%d",
        settings.enable_ollama_vision_fallback,
        len(image_bytes),
    )

    try:
        gemini_response = analyze_with_gemini_vision(
            image_bytes=image_bytes,
            prompt=prompt,
            scene_summary=scene_summary,
            local_summary=local_summary,
        )
        logger.info("Vision provider used: gemini")
        return gemini_response
    except Exception as exc:
        fallback_reason = classify_gemini_fallback_reason(exc)
        if fallback_reason in {
            "gemini_not_configured",
            "gemini_quota_exceeded",
            "gemini_rate_limited",
            "gemini_resource_exhausted",
            "gemini_service_unavailable",
        }:
            logger.warning("Gemini vision request unavailable (%s): %s", fallback_reason, exc)
        else:
            logger.exception("Gemini vision request failed: %s", exc)
        return analyze_image_fallbacks_after_gemini_failure(
            image=image,
            prompt=prompt,
            scene_summary=scene_summary,
            model=model,
            fallback_reason=fallback_reason,
            local_summary=local_summary,
        )


def analyze_with_ollama_vision(
    image_bytes: bytes,
    prompt: str | None = None,
    scene_summary: str | None = None,
    model: str | None = None,
) -> VisionProxyResponse:
    """Backward-compatible wrapper for the Gemini-first image pipeline."""

    return analyze_image_with_provider_fallback(
        image_bytes=image_bytes,
        prompt=prompt,
        scene_summary=scene_summary,
        model=model,
    )


def analyze_image_fallbacks_after_gemini_failure(
    image: Image.Image,
    prompt: str | None,
    scene_summary: str | None,
    model: str | None,
    fallback_reason: str,
    local_summary: str,
) -> VisionProxyResponse:
    """Run secondary image providers after Gemini failed.

    OpenRouter is preferred over Ollama because local vision models have been
    observed to invent confident scene descriptions from weak frames. Ollama is
    available only as an explicit opt-in fallback.
    """

    settings = get_settings()
    openrouter_reason = fallback_reason
    logger.warning("Falling back from Gemini to OpenRouter vision: %s", openrouter_reason)
    try:
        openrouter_response = analyze_with_openrouter_vision(
            image=image,
            prompt=prompt,
            scene_summary=scene_summary,
            fallback_reason=openrouter_reason,
            local_summary=local_summary,
        )
        logger.info("Vision provider used: openrouter")
        return openrouter_response
    except Exception as openrouter_exc:
        logger.exception("OpenRouter vision fallback failed: %s", openrouter_exc)

    if not settings.enable_ollama_vision_fallback:
        logger.info("Ollama vision fallback disabled; returning local confidence-limited response.")
        return build_local_vision_response(
            fallback_reason=f"{openrouter_reason}_openrouter_failed_ollama_disabled",
            local_summary=local_summary,
        )

    ollama_reason = f"{openrouter_reason}_openrouter_failed"
    logger.warning("Falling back from OpenRouter to Ollama vision: %s", ollama_reason)
    try:
        ollama_response = analyze_with_ollama_vision_only(
            image=image,
            prompt=prompt,
            scene_summary=scene_summary,
            model=model,
            fallback_reason=ollama_reason,
            local_summary=local_summary,
        )
        logger.info("Vision provider used: ollama")
        return ollama_response
    except Exception as ollama_exc:
        logger.exception("Ollama vision fallback failed: %s", ollama_exc)
        return build_local_vision_response(
            fallback_reason=f"{ollama_reason}_ollama_failed",
            local_summary=local_summary,
        )


def analyze_with_ollama_vision_only(
    image: Image.Image,
    prompt: str | None = None,
    scene_summary: str | None = None,
    model: str | None = None,
    fallback_reason: str | None = None,
    local_summary: str | None = None,
) -> VisionProxyResponse:
    """Send an image understanding request to Ollama and normalize the reply."""

    settings = get_settings()
    selected_model = (model or settings.ollama_vision_model).strip() or settings.ollama_vision_model
    normalized_prompt = build_vision_proxy_prompt(prompt=prompt, scene_summary=scene_summary)
    base64_image = encode_image_for_ollama(image)

    outgoing_payload = {
        "model": selected_model,
        "prompt": normalized_prompt,
        "images": [base64_image],
        "stream": False,
        "format": {
            "type": "object",
            "properties": {
                "assistant_message": {"type": "string"},
                "vision_summary": {"type": "string"},
            },
            "required": ["assistant_message", "vision_summary"],
        },
    }
    logger.info(
        "Forwarding vision request to Ollama: model=%s scene_summary_len=%d",
        selected_model,
        len(scene_summary or ""),
    )

    try:
        response = httpx.post(
            f"{settings.ollama_base_url}/api/generate",
            json=outgoing_payload,
            timeout=settings.ollama_timeout_seconds,
        )
        logger.info("Ollama vision HTTP status: %s", response.status_code)
        response.raise_for_status()
        raw_body = response.text
    except httpx.TimeoutException as exc:
        raise AppError("Ollama vision request timed out.", status_code=504) from exc
    except httpx.HTTPStatusError as exc:
        logger.exception("Ollama vision HTTP error: %s", exc)
        raise AppError("Ollama vision request failed.", status_code=502) from exc
    except httpx.HTTPError as exc:
        raise AppError("Unable to reach Ollama vision service.", status_code=502) from exc

    payload = parse_ollama_vision_response(raw_body)
    payload["vision_provider"] = "ollama"
    payload["fallback_reason"] = fallback_reason
    payload["local_summary"] = local_summary
    response_model = VisionProxyResponse.model_validate(payload)
    return response_model


def analyze_with_openrouter_vision(
    image: Image.Image,
    prompt: str | None = None,
    scene_summary: str | None = None,
    fallback_reason: str | None = None,
    local_summary: str | None = None,
) -> VisionProxyResponse:
    """Send an image request to OpenRouter after Gemini and Ollama fail."""

    api_key = os.getenv("OPENROUTER_API_KEY")
    if not api_key:
        raise AppError("OPENROUTER_API_KEY is not set.", status_code=500)

    selected_model = (
        os.getenv("OPENROUTER_VISION_MODEL")
        or os.getenv("OPENROUTER_MODEL")
        or "openai/gpt-4o-mini"
    ).strip()
    normalized_prompt = build_openrouter_vision_prompt(prompt=prompt, scene_summary=scene_summary)
    base64_image = encode_image_for_ollama(image)
    body = {
        "model": selected_model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": normalized_prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{base64_image}"},
                    },
                ],
            }
        ],
        "response_format": {"type": "json_object"},
        "stream": False,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": os.getenv("OPENROUTER_REFERER", "https://watersheep.local"),
        "X-Title": "Watersheep",
    }

    try:
        response = httpx.post(
            "https://openrouter.ai/api/v1/chat/completions",
            json=body,
            headers=headers,
            timeout=45,
        )
        logger.info("OpenRouter vision HTTP status: %s", response.status_code)
        response.raise_for_status()
        data = response.json()
    except httpx.TimeoutException as exc:
        raise AppError("OpenRouter vision request timed out.", status_code=504) from exc
    except httpx.HTTPStatusError as exc:
        logger.exception("OpenRouter vision HTTP error: %s", exc)
        raise AppError("OpenRouter vision request failed.", status_code=502) from exc
    except (httpx.HTTPError, ValueError) as exc:
        raise AppError("Unable to reach OpenRouter vision service.", status_code=502) from exc

    raw_message = extract_openrouter_vision_text(data)
    payload = parse_ollama_vision_response(json.dumps({"response": raw_message}))
    payload["vision_provider"] = "openrouter"
    payload["fallback_reason"] = fallback_reason
    payload["local_summary"] = local_summary
    return VisionProxyResponse.model_validate(payload)


def analyze_with_gemini_vision(
    image_bytes: bytes,
    prompt: str | None = None,
    scene_summary: str | None = None,
    local_summary: str | None = None,
) -> VisionProxyResponse:
    """Analyze an image with Gemini Vision and return the stable proxy response."""

    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        raise AppError("GEMINI_API_KEY is not set.", status_code=500)

    normalized_prompt = build_gemini_vision_prompt(prompt=prompt, scene_summary=scene_summary)
    logger.info(
        "Forwarding vision request to Gemini: model=%s image_bytes=%d",
        VISION_MODEL,
        len(image_bytes),
    )

    image = validate_image_upload(content_type=None, file_bytes=image_bytes)
    mime_type = Image.MIME.get(image.format or "", "image/jpeg")

    client = genai.Client(api_key=api_key)
    response = client.models.generate_content(
        model=VISION_MODEL,
        contents=[
            normalized_prompt,
            types.Part.from_bytes(data=image_bytes, mime_type=mime_type),
        ],
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema=VisionProxyResponse,
        ),
    )

    if getattr(response, "parsed", None):
        parsed = response.parsed.model_dump()
    else:
        parsed = parse_ollama_vision_response(getattr(response, "text", "") or "")

    parsed["vision_provider"] = "gemini"
    parsed["fallback_reason"] = None
    parsed["local_summary"] = local_summary
    return VisionProxyResponse.model_validate(parsed)


def validate_image_upload(
    content_type: str | None,
    file_bytes: bytes,
) -> Image.Image:
    """Validate that the upload is a readable image within size and pixel limits."""

    if not file_bytes:
        raise HTTPException(status_code=400, detail="Uploaded image is empty.")

    if len(file_bytes) > MAX_IMAGE_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Image exceeds {MAX_IMAGE_BYTES // (1024 * 1024)} MB upload limit.",
        )

    if content_type and not content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Uploaded file must be an image.")

    previous_max_pixels = Image.MAX_IMAGE_PIXELS
    Image.MAX_IMAGE_PIXELS = MAX_IMAGE_PIXELS
    try:
        image = Image.open(BytesIO(file_bytes))
        image.load()
    except Image.DecompressionBombError as exc:
        raise HTTPException(status_code=413, detail="Image dimensions are too large.") from exc
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid image upload.") from exc
    finally:
        Image.MAX_IMAGE_PIXELS = previous_max_pixels

    width, height = image.size
    if width <= 0 or height <= 0:
        raise HTTPException(status_code=400, detail="Image has invalid dimensions.")
    if width > MAX_IMAGE_DIMENSION or height > MAX_IMAGE_DIMENSION:
        raise HTTPException(
            status_code=413,
            detail=f"Image dimensions must be <= {MAX_IMAGE_DIMENSION} px on each side.",
        )
    if width * height > MAX_IMAGE_PIXELS:
        raise HTTPException(status_code=413, detail="Image pixel count exceeds the allowed limit.")
    return image


def decode_base64_image(encoded_image: str) -> bytes:
    """Decode raw base64 or data-URL-style image payloads."""

    candidate = encoded_image.strip()
    if "," in candidate and candidate.lower().startswith("data:"):
        candidate = candidate.split(",", 1)[1]

    expected_bytes = (len(candidate) * 3) // 4
    if expected_bytes > MAX_IMAGE_BYTES:
        raise AppError(
            f"Base64 image exceeds the {MAX_IMAGE_BYTES // (1024 * 1024)} MB limit.",
            status_code=413,
        )

    try:
        return base64.b64decode(candidate, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise AppError("Invalid base64 image payload.", status_code=400) from exc


def encode_image_for_ollama(image: Image.Image) -> str:
    """Encode the image into JPEG base64 for Ollama image input.

    Quality 92 with subsampling=0 keeps small text legible for vision models.
    The size cost vs. 85 is small (~15%), the OCR accuracy gain is large.
    """

    buffer = BytesIO()
    if image.mode not in {"RGB", "L"}:
        image = image.convert("RGB")
    image.save(buffer, format="JPEG", quality=92, subsampling=0, optimize=True)
    return base64.b64encode(buffer.getvalue()).decode("utf-8")


def build_vision_proxy_prompt(prompt: str | None, scene_summary: str | None) -> str:
    """Compose the Ollama prompt with optional app context."""

    prompt_parts = [DEFAULT_VISION_PROXY_PROMPT]
    if should_use_scene_summary_hint(scene_summary):
        prompt_parts.append(f"Local OCR/object hint: {scene_summary.strip()}")
    if prompt:
        prompt_parts.append(f"User prompt: {prompt.strip()}")
    else:
        prompt_parts.append("User prompt: Describe what the user is looking at.")
    return "\n\n".join(prompt_parts)


def build_gemini_vision_prompt(prompt: str | None, scene_summary: str | None) -> str:
    """Compose the Gemini prompt with optional app context."""

    prompt_parts = [DEFAULT_GEMINI_VISION_PROXY_PROMPT]
    if should_use_scene_summary_hint(scene_summary):
        prompt_parts.append(f"Local OCR/object hint: {scene_summary.strip()}")
    if prompt:
        prompt_parts.append(f"User prompt: {prompt.strip()}")
    else:
        prompt_parts.append("User prompt: Describe what the user is looking at.")
    return "\n\n".join(prompt_parts)


def build_openrouter_vision_prompt(prompt: str | None, scene_summary: str | None) -> str:
    """Compose the OpenRouter multimodal prompt with the same response contract."""

    return build_gemini_vision_prompt(prompt=prompt, scene_summary=scene_summary)


def parse_ollama_vision_response(raw_body: str) -> dict[str, str]:
    """Parse Ollama output into the stable API response shape."""

    try:
        body = json.loads(raw_body)
    except json.JSONDecodeError as exc:
        raise AppError("Ollama returned invalid JSON.", status_code=502) from exc

    if not isinstance(body, dict):
        raise AppError("Vision provider returned an invalid JSON shape.", status_code=502)

    if "assistant_message" in body or "vision_summary" in body:
        assistant_message = str(
            body.get("assistant_message")
            or body.get("message")
            or body.get("vision_summary")
            or ""
        ).strip()
        vision_summary = str(
            body.get("vision_summary")
            or body.get("summary")
            or assistant_message
        ).strip()
        if assistant_message or vision_summary:
            return {
                "assistant_message": assistant_message or vision_summary,
                "vision_summary": vision_summary or assistant_message,
            }

    message_value = body.get("message")
    message_content = message_value.get("content", "") if isinstance(message_value, dict) else ""
    raw_response = str(body.get("response") or message_content).strip()
    if not raw_response:
        raise AppError("Ollama vision returned an empty response.", status_code=502)

    try:
        parsed = json.loads(raw_response)
    except json.JSONDecodeError:
        parsed = {
            "assistant_message": raw_response,
            "vision_summary": raw_response,
        }

    assistant_message = str(parsed.get("assistant_message") or parsed.get("message") or raw_response).strip()
    vision_summary = str(parsed.get("vision_summary") or parsed.get("summary") or assistant_message).strip()
    return {
        "assistant_message": assistant_message,
        "vision_summary": vision_summary,
    }


def extract_openrouter_vision_text(data: object) -> str:
    """Extract message content from an OpenRouter chat-completions response."""

    if not isinstance(data, dict):
        raise AppError("OpenRouter vision returned an invalid response.", status_code=502)

    choices = data.get("choices")
    if isinstance(choices, list) and choices:
        first = choices[0]
        if isinstance(first, dict):
            message = first.get("message")
            if isinstance(message, dict):
                content = message.get("content")
                if isinstance(content, str) and content.strip():
                    return content.strip()
            text = first.get("text")
            if isinstance(text, str) and text.strip():
                return text.strip()

    raise AppError("OpenRouter vision returned an empty response.", status_code=502)


def build_local_vision_summary(image: Image.Image, scene_summary: str | None) -> str:
    """Build a stable local fallback summary from on-device hints."""

    if should_use_scene_summary_hint(scene_summary):
        return scene_summary.strip()

    width, height = image.size
    return f"Objects: none detected. OCR: none. Image size: {width}x{height}."


def should_use_scene_summary_hint(scene_summary: str | None) -> bool:
    """Only trust local OCR/object hints, not prior AI scene captions."""

    if not scene_summary:
        return False

    normalized = scene_summary.strip().lower()
    if not normalized:
        return False

    accepted_prefixes = ("objects:", "text:", "ocr:", "local vision:", "apple vision:")
    return normalized.startswith(accepted_prefixes) or " objects:" in normalized or " ocr:" in normalized


def build_local_vision_response(
    fallback_reason: str,
    local_summary: str,
) -> VisionProxyResponse:
    """Return a consistent response when only local summary data is available."""

    return VisionProxyResponse(
        assistant_message="I can't confidently tell what you're looking at because cloud vision is unavailable.",
        vision_summary=local_summary,
        vision_provider="local_summary",
        fallback_reason=fallback_reason,
        local_summary=local_summary,
    )


def build_friendly_vision_failure(local_summary: str) -> VisionProxyResponse:
    """Return a final friendly failure response with any available local context."""

    return VisionProxyResponse(
        assistant_message="I couldn't analyze this image right now. Please try again in a moment.",
        vision_summary=local_summary,
        vision_provider="friendly_failure",
        fallback_reason="vision_unavailable",
        local_summary=local_summary,
    )


def classify_gemini_fallback_reason(exc: Exception) -> str | None:
    """Return a normalized fallback reason for Gemini failures."""

    status_code = getattr(exc, "code", None)
    if status_code == 429:
        return "gemini_quota_exceeded"
    if status_code == 503:
        return "gemini_service_unavailable"

    message = extract_error_message(exc).lower()
    if "gemini_api_key" in message or "api key" in message:
        return "gemini_not_configured"
    if "429" in message:
        return "gemini_quota_exceeded"
    if "quota" in message:
        return "gemini_quota_exceeded"
    if "resource exhausted" in message:
        return "gemini_resource_exhausted"
    if "rate limit" in message or "rate-limit" in message:
        return "gemini_rate_limited"
    if "service unavailable" in message or "unavailable" in message:
        return "gemini_service_unavailable"
    if not message:
        return "gemini_failed"
    return "gemini_failed"


def extract_error_message(exc: Exception) -> str:
    """Extract a readable message from SDK or HTTP exceptions."""

    response_json = getattr(exc, "response_json", None)
    if isinstance(response_json, dict):
        return str(response_json.get("error", {}).get("message", "")) or str(exc)
    return str(exc)


def describe_frame_with_gemini(image_bytes: bytes, model_used: str) -> str:
    """Use Gemini Vision to describe the uploaded frame briefly."""

    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        raise AppError("GEMINI_API_KEY is not set.", status_code=500)

    client = genai.Client(api_key=api_key)
    response = client.models.generate_content(
        model=model_used,
        contents=[
            FRAME_ANALYSIS_PROMPT,
            types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
        ],
    )

    text = getattr(response, "text", "") or ""
    cleaned = " ".join(text.split())
    if not cleaned:
        raise AppError("Vision model returned an empty response.", status_code=502)
    return cleaned


def get_vision_cooldown_response() -> FrameAnalysisResponse | None:
    """Return an immediate cooldown response if Gemini is temporarily paused."""

    remaining = get_vision_cooldown_remaining()
    if remaining <= 0:
        return None

    logger.debug("Vision cooldown active, skipping Gemini call for %ds", remaining)
    return FrameAnalysisResponse(
        success=False,
        scene="",
        suggestion="",
        error="vision_cooldown",
        message="Vision temporarily paused due to quota limits.",
        retry_after_seconds=remaining,
    )


def get_vision_cooldown_remaining() -> int:
    """Return the remaining cooldown in whole seconds."""

    return int(max(0, VISION_COOLDOWN_UNTIL - time.time()))


def clear_vision_cooldown() -> None:
    """Clear the in-memory Gemini Vision cooldown."""

    global VISION_COOLDOWN_UNTIL
    VISION_COOLDOWN_UNTIL = 0.0


def apply_vision_cooldown(exc: genai_errors.ClientError) -> int:
    """Apply a cooldown after a Gemini quota failure."""

    global VISION_COOLDOWN_UNTIL

    retry_after = extract_retry_after_seconds(exc) or DEFAULT_VISION_COOLDOWN_SECONDS
    VISION_COOLDOWN_UNTIL = time.time() + retry_after
    return retry_after


def extract_retry_after_seconds(exc: genai_errors.ClientError) -> int | None:
    """Try to parse retry delay information from a Gemini quota error."""

    response_json = getattr(exc, "response_json", None)
    if not isinstance(response_json, dict):
        return None

    details = response_json.get("error", {}).get("details", [])
    if not isinstance(details, list):
        return None

    for detail in details:
        if not isinstance(detail, dict):
            continue
        retry_delay = detail.get("retryDelay")
        if isinstance(retry_delay, str) and retry_delay.endswith("s"):
            try:
                return max(1, int(float(retry_delay[:-1])))
            except ValueError:
                continue
    return None


def save_image_bytes(filename: str | None, file_bytes: bytes) -> str:
    """Persist uploaded bytes under the configured uploads directory."""

    settings = get_settings()
    today = datetime.now(timezone.utc)
    suffix = Path(filename or "upload.jpg").suffix or ".jpg"
    relative_path = Path("vision") / today.strftime("%Y") / today.strftime("%m") / today.strftime("%d")
    destination_dir = settings.uploads_path / relative_path
    destination_dir.mkdir(parents=True, exist_ok=True)

    generated_name = f"{uuid4().hex}{suffix.lower()}"
    destination = destination_dir / generated_name
    destination.write_bytes(file_bytes)
    return str(Path("uploads") / relative_path / generated_name)


def build_placeholder_analysis(saved_path: str, image: Image.Image) -> VisionAnalysisResponse:
    """Build the legacy placeholder image analysis response."""

    width, height = image.size
    summary = f"Placeholder analysis for an uploaded image sized {width}x{height}."
    return VisionAnalysisResponse(
        image_path=saved_path,
        summary=summary,
        detected_objects=[],
        extracted_text="",
        scene_description="Uploaded image received successfully and ready for future vision processing.",
    )


def is_quota_error(exc: genai_errors.ClientError) -> bool:
    """Return True when a Gemini client error appears quota related."""

    status = getattr(exc, "code", None)
    if status == 429:
        return True

    response_json = getattr(exc, "response_json", None)
    message = ""
    if isinstance(response_json, dict):
        message = str(response_json.get("error", {}).get("message", ""))
    return "quota" in message.lower() or "rate" in message.lower()


def log_quota_failure(retry_after_seconds: int) -> None:
    """Log a structured quota warning for operations visibility."""

    logger.warning(
        "Gemini vision quota exceeded; retry after %ss",
        retry_after_seconds,
    )
