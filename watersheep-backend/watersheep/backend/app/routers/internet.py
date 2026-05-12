"""Internet research endpoints for text and image-assisted search."""

from __future__ import annotations

import logging

from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile

from ..models.schemas import (
    InternetSearchRequest,
    InternetSearchResponse,
    InternetSearchResultItem,
)
from ..services.internet_service import infer_search_mode, research_web
from ..services.vision_service import analyze_image_with_provider_fallback, decode_base64_image

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/internet", tags=["internet"])


@router.post("/search", response_model=InternetSearchResponse)
async def search_internet(payload: InternetSearchRequest) -> InternetSearchResponse:
    """Search the internet and return a filtered summary with sources."""

    try:
        image_keywords = None
        mode = normalize_mode(payload.mode, fallback=infer_search_mode(payload.query))
        if payload.image_base64:
            image_bytes = decode_base64_image(payload.image_base64)
            image_keywords = extract_image_search_keywords(image_bytes, scene_context=payload.scene_context)
            if mode == "web":
                mode = "image"

        report = research_web(
            payload.query,
            mode=mode,
            scene_context=payload.scene_context,
            image_keywords=image_keywords,
            max_results=payload.max_results,
            provider=payload.provider,
        )
    except Exception as exc:
        logger.exception("Internet search failed: %s", exc)
        raise HTTPException(status_code=502, detail="Internet search failed. Try again in a moment.") from exc

    return response_from_report(report)


@router.post("/image-search", response_model=InternetSearchResponse)
async def search_image_online(
    request: Request,
    file: UploadFile | None = File(default=None),
    query: str | None = Form(default=None),
    scene_summary: str | None = Form(default=None),
    mode: str | None = Form(default="image"),
    provider: str | None = Form(default=None),
    max_results: int = Form(default=5),
) -> InternetSearchResponse:
    """Analyze an uploaded frame, build search keywords, then search online."""

    try:
        if file is not None:
            image_bytes = await file.read()
            resolved_query = query or "search this online"
            resolved_scene = scene_summary
        else:
            body = await request.json()
            payload = InternetSearchRequest.model_validate(body)
            if not payload.image_base64:
                raise HTTPException(status_code=400, detail="Provide an image file or image_base64.")
            image_bytes = decode_base64_image(payload.image_base64)
            resolved_query = payload.query
            resolved_scene = payload.scene_context
            mode = payload.mode
            provider = payload.provider
            max_results = payload.max_results

        image_keywords = extract_image_search_keywords(image_bytes, scene_context=resolved_scene)
        resolved_mode = normalize_mode(mode, fallback="image")
        if resolved_mode == "web":
            resolved_mode = "image"

        report = research_web(
            resolved_query,
            mode=resolved_mode,
            scene_context=resolved_scene,
            image_keywords=image_keywords,
            max_results=max(1, min(max_results, 8)),
            provider=provider,
        )
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("Image internet search failed: %s", exc)
        raise HTTPException(status_code=502, detail="Image internet search failed. Try again in a moment.") from exc

    return response_from_report(report)


def extract_image_search_keywords(image_bytes: bytes, *, scene_context: str | None = None) -> str:
    """Ask the vision pipeline for search-focused keywords from an image."""

    if scene_context and scene_context.strip():
        return scene_context.strip()[:500]

    prompt = """
Identify this image for internet/product search.
Return concise search keywords, not a paragraph.
Include visible brand, logo, text, colour, material, shape, style, model number,
object type, category, and any distinctive details.
If the exact product is uncertain, describe it as searchable attributes.
"""
    response = analyze_image_with_provider_fallback(
        image_bytes=image_bytes,
        prompt=prompt,
        scene_summary=scene_context,
    )
    candidates = [
        response.vision_summary,
        response.assistant_message,
        response.local_summary,
        scene_context,
    ]
    for candidate in candidates:
        cleaned = " ".join((candidate or "").split())
        if cleaned:
            return cleaned[:500]
    return "unknown object"


def normalize_mode(mode: str | None, *, fallback: str) -> str:
    value = (mode or fallback).strip().lower()
    if value in {"web", "product", "image"}:
        return value
    return fallback


def response_from_report(report) -> InternetSearchResponse:
    return InternetSearchResponse(
        query=report.query,
        mode=report.mode,
        summary=report.summary,
        results=[
            InternetSearchResultItem(
                title=result.title,
                summary=result.snippet,
                url=result.url,
                source=result.source,
                confidence=result.confidence,
            )
            for result in report.results
        ],
        provider=report.provider,
        confidence=report.confidence,
        exact_match=report.exact_match,
        image_keywords=report.image_keywords,
    )
